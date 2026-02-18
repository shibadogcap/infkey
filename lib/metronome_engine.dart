import 'dart:async';
import 'dart:isolate';

// ─── コマンド群 ───────────────────────────────────────────────

class _CmdStart {
  final int bpm;
  final int beatsPerMeasure;
  const _CmdStart(this.bpm, this.beatsPerMeasure);
}

class _CmdStop { const _CmdStop(); }

class _CmdBpm {
  final int bpm;
  const _CmdBpm(this.bpm);
}

class _CmdBeats {
  final int beats;
  const _CmdBeats(this.beats);
}

// ─── Isolate→main イベント ─────────────────────────────────

class MetronomeEvent {
  final bool isPre;
  final int beat;
  const MetronomeEvent({required this.isPre, required this.beat});
}

// ─── Isolateエントリ ──────────────────────────────────────────
// 精度向上策:
//   大部分の待機は Timer で行い、目標時刻の 1.5ms 前に起床して
//   Stopwatch によるビジーウェイトで残りを消費する。
//   これにより Android/iOS の Timer ジッター（~1-4ms）を大幅低減する。

void _isolateEntry(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  int bpm = 120;
  int beatsPerMeasure = 4;
  bool running = false;
  int? startMicros;   // Stopwatch 基準マイクロ秒
  final sw = Stopwatch()..start();
  int totalBeats = 0;
  Timer? timer;
  Timer? preTimer;
  const int preLeadUs = 15000; // 15ms
  const int busyWaitUs = 1500; // 1.5ms 手前でビジーウェイトに切替

  void scheduleTick(int beatIndex) {
    if (!running) return;
    startMicros ??= sw.elapsedMicroseconds;

    final intervalUs = (60000000 / bpm).round();
    final targetUs = startMicros! + beatIndex * intervalUs;

    // --- preTick ---
    final preTargetUs = targetUs - preLeadUs;
    final preDelayUs = preTargetUs - sw.elapsedMicroseconds;
    if (preDelayUs > 0) {
      final preCoarseUs = preDelayUs > busyWaitUs ? preDelayUs - busyWaitUs : 0;
      preTimer?.cancel();
      preTimer = Timer(Duration(microseconds: preCoarseUs), () {
        if (!running) return;
        // ビジーウェイトで残り調整
        while (sw.elapsedMicroseconds < preTargetUs) {}
        mainSendPort.send(
            MetronomeEvent(isPre: true, beat: (beatIndex % beatsPerMeasure) + 1));
      });
    }

    // --- mainTick ---
    final delayUs = targetUs - sw.elapsedMicroseconds;
    final coarseUs = delayUs > busyWaitUs ? delayUs - busyWaitUs : 0;

    timer?.cancel();
    timer = Timer(Duration(microseconds: coarseUs < 0 ? 0 : coarseUs), () {
      if (!running) return;
      // ビジーウェイトで目標時刻まで精密待機
      while (sw.elapsedMicroseconds < targetUs) {}
      totalBeats = beatIndex + 1;
      mainSendPort.send(
          MetronomeEvent(isPre: false, beat: (beatIndex % beatsPerMeasure) + 1));
      scheduleTick(beatIndex + 1);
    });
  }

  receivePort.listen((msg) {
    if (msg is _CmdStart) {
      timer?.cancel();
      preTimer?.cancel();
      bpm = msg.bpm;
      beatsPerMeasure = msg.beatsPerMeasure;
      totalBeats = 0;
      startMicros = null; // scheduleTick 内で初期化
      running = true;
      scheduleTick(0);
    } else if (msg is _CmdStop) {
      running = false;
      timer?.cancel();
      preTimer?.cancel();
      totalBeats = 0;
    } else if (msg is _CmdBpm) {
      if (!running) { bpm = msg.bpm; return; }
      timer?.cancel();
      preTimer?.cancel();
      final newIntervalUs = (60000000 / msg.bpm).round();
      // 現在位置を新 BPM で再アンカー
      startMicros = sw.elapsedMicroseconds
          - totalBeats * newIntervalUs
          + newIntervalUs;
      totalBeats = 0;
      bpm = msg.bpm;
      scheduleTick(0);
    } else if (msg is _CmdBeats) {
      beatsPerMeasure = msg.beats;
    }
  });
}

// ─── 公開クラス ───────────────────────────────────────────────

class MetronomeTrack {
  int bpm;
  int beatsPerMeasure;
  int preTickLeadMs;

  void Function(int beat)? onTick;
  void Function(int beat)? onPreTick;

  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _receivePort;
  bool _running = false;

  bool get isRunning => _running;

  MetronomeTrack({
    required this.bpm,
    required this.beatsPerMeasure,
    this.preTickLeadMs = 15,
  });

  Future<void> _ensureIsolate() async {
    if (_isolate != null) return;
    _receivePort = ReceivePort();
    _isolate = await Isolate.spawn(_isolateEntry, _receivePort!.sendPort);

    final completer = Completer<SendPort>();
    _receivePort!.listen((msg) {
      if (!completer.isCompleted && msg is SendPort) {
        completer.complete(msg);
      } else if (msg is MetronomeEvent) {
        if (msg.isPre) { onPreTick?.call(msg.beat); }
        else { onTick?.call(msg.beat); }
      }
    });
    _sendPort = await completer.future;
  }

  Future<void> start() async {
    if (_running) stop();
    await _ensureIsolate();
    _sendPort!.send(_CmdStart(bpm, beatsPerMeasure));
    _running = true;
  }

  void stop() {
    _sendPort?.send(const _CmdStop());
    _running = false;
  }

  void updateBpm(int newBpm) {
    bpm = newBpm;
    _sendPort?.send(_CmdBpm(newBpm));
  }

  void updateBeatsPerMeasure(int n) {
    beatsPerMeasure = n;
    _sendPort?.send(_CmdBeats(n));
  }

  void dispose() {
    stop();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    _sendPort = null;
  }
}
