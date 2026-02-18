import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart'; // Add this
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:torch_light/torch_light.dart';
import 'package:vibration/vibration.dart';
import 'audio_engine.dart';
import 'metronome_engine.dart';

// ─── トラック状態 ────────────────────────────────────────────
class _TrackState {
  final MetronomeTrack engine;
  int bpm;
  int beatsPerMeasure;
  int currentBeat = 0;
  final List<DateTime> tapTimes = [];

  // フィードバック設定（トラック個別）
  bool soundEnabled     = true;
  bool hapticEnabled    = true;
  bool vibrationEnabled = false;
  bool flashEnabled     = false;
  bool muted            = false; // 全フィードバック一時ミュート

  _TrackState({
    required this.engine,
    required this.bpm,
    required this.beatsPerMeasure,
  });

  void dispose() => engine.dispose();
}

// ─── Screen ──────────────────────────────────────────────────
class MetronomeScreen extends StatefulWidget {
  const MetronomeScreen({super.key});
  @override
  State<MetronomeScreen> createState() => _MetronomeScreenState();
}

class _MetronomeScreenState extends State<MetronomeScreen> {
  late final _TrackState _a;
  late final _TrackState _b;
  bool _isPlaying = false;
  bool _hasTorch   = false;
  bool _hasVibrator = false;

  static const _minBpm = 1;
  static const _maxBpm = 500;

  @override
  void initState() {
    super.initState();
    _a = _TrackState(engine: MetronomeTrack(bpm: 120, beatsPerMeasure: 4), bpm: 120, beatsPerMeasure: 4);
    _b = _TrackState(engine: MetronomeTrack(bpm: 120, beatsPerMeasure: 3), bpm: 120, beatsPerMeasure: 3);
    _b.muted = true; // 初期状態では B をミュート
    _a.engine.onPreTick = (beat) => _onPreTick(beat, _a);
    _a.engine.onTick    = (beat) => _onTick(beat, _a, 0);
    _b.engine.onPreTick = (beat) => _onPreTick(beat, _b);
    _b.engine.onTick    = (beat) => _onTick(beat, _b, 1);
    AudioEngine().init();
    _checkCapabilities();
  }

  Future<void> _checkCapabilities() async {
    if (kIsWeb) return; // Web では懐中電灯とバイブレーションを無効化
    try {
      final hasTorch = await TorchLight.isTorchAvailable();
      final hasVib   = await Vibration.hasVibrator();
      if (mounted) setState(() { _hasTorch = hasTorch; _hasVibrator = (hasVib == true); });
    } catch (_) {}
  }

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  // ─── コールバック ─────────────────────────────────────────
  void _onPreTick(int beat, _TrackState t) {
    if (t.muted) return;
    final isDown = beat == 1;
    if (t.hapticEnabled) {
      isDown ? HapticFeedback.heavyImpact() : HapticFeedback.lightImpact();
    }
    if (t.vibrationEnabled && _hasVibrator && !kIsWeb) {
      Vibration.vibrate(duration: isDown ? 60 : 25, amplitude: isDown ? 200 : 80);
    }
  }

  void _onTick(int beat, _TrackState t, int trackIndex) {
    if (!mounted) return;
    final isDown = beat == 1;
    if (!t.muted) {
      if (t.soundEnabled)  AudioEngine().playClick(isDown, trackIndex: trackIndex);
      if (t.flashEnabled && _hasTorch && !kIsWeb) _torchFlash(isDown);
      setState(() => t.currentBeat = beat);
    }
  }

  Future<void> _torchFlash(bool strong) async {
    if (kIsWeb) return;
    try {
      await TorchLight.enableTorch();
      await Future.delayed(Duration(milliseconds: strong ? 50 : 25));
      await TorchLight.disableTorch();
    } catch (_) {}
  }

  // ─── 再生制御 ─────────────────────────────────────────────
  Future<void> _startStop() async {
    if (_isPlaying) {
      _a.engine.stop();
      _b.engine.stop();
      setState(() { _isPlaying = false; _a.currentBeat = 0; _b.currentBeat = 0; });
    } else {
      // Web 対策: ユーザー操作時に AudioEngine を初期化/再開
      await AudioEngine().init();
      
      _a.engine..bpm = _a.bpm..beatsPerMeasure = _a.beatsPerMeasure;
      _b.engine..bpm = _b.bpm..beatsPerMeasure = _b.beatsPerMeasure;
      await _a.engine.start();
      await _b.engine.start();
      if (mounted) setState(() => _isPlaying = true);
    }
  }

  void _tapTempo(_TrackState t) {
    final now = DateTime.now();
    t.tapTimes.add(now);
    if (t.tapTimes.length > 8) t.tapTimes.removeAt(0);
    if (t.tapTimes.length >= 2) {
      int sum = 0;
      for (int i = 1; i < t.tapTimes.length; i++) {
        sum += t.tapTimes[i].difference(t.tapTimes[i - 1]).inMilliseconds;
      }
      final avg = sum / (t.tapTimes.length - 1);
      final v = (60000 / avg).round().clamp(_minBpm, _maxBpm);
      setState(() => t.bpm = v);
      t.engine.updateBpm(v);
    }
  }

  void _setBpm(_TrackState t, int v) {
    setState(() => t.bpm = v.clamp(_minBpm, _maxBpm));
    t.engine.updateBpm(t.bpm);
  }

  void _setBeats(_TrackState t, int v) {
    final n = v.clamp(1, 32);
    setState(() { t.beatsPerMeasure = n; t.currentBeat = 0; });
    t.engine.updateBeatsPerMeasure(n);
  }

  Future<void> _showDialog(String label, int current, int min, int max, void Function(int) onChanged) async {
    final ctrl = TextEditingController(text: current.toString());
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(signed: false),
          autofocus: true,
          decoration: InputDecoration(hintText: '$min ~ $max'),
          onSubmitted: (s) {
            final v = int.tryParse(s);
            if (v != null) onChanged(v.clamp(min, max));
            Navigator.of(ctx).pop();
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final v = int.tryParse(ctrl.text);
              if (v != null) onChanged(v.clamp(min, max));
              Navigator.of(ctx).pop();
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ─── Build ───────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return OrientationBuilder(builder: (ctx, orientation) {
      final isLandscape = orientation == Orientation.landscape;
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
          child: isLandscape ? _buildLandscape() : _buildPortrait(),
        ),
      );
    });
  }

  Widget _buildPortrait() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildTrackPanel(_a, trackIndex: 0, indicatorSize: 160),
        const SizedBox(height: 16),
        _buildDivider(horizontal: true),
        const SizedBox(height: 16),
        _buildTrackPanel(_b, trackIndex: 1, indicatorSize: 160),
        const SizedBox(height: 28),
        _buildStartStop(),
      ],
    );
  }

  Widget _buildLandscape() {
    return IntrinsicHeight(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTrackPanel(_a, trackIndex: 0, indicatorSize: 160),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: _buildDivider(horizontal: false),
          ),
          _buildTrackPanel(_b, trackIndex: 1, indicatorSize: 160),
          const SizedBox(width: 20),
          // Start/Stop: 右端に縦配置
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [_buildStartStop()],
          ),
        ],
      ),
    );
  }

  Widget _buildDivider({required bool horizontal}) {
    const color = Color(0xFF43474e);
    return horizontal
        ? Container(height: 1, width: 240, color: color)
        : Container(width: 1, height: 180, color: color);
  }

  // ─── スタート/ストップ ────────────────────────────────────
  Widget _buildStartStop() {
    return SizedBox(
      width: 140,
      height: 44,
      child: FilledButton.icon(
        onPressed: _startStop,
        icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow, size: 22),
        label: Text(_isPlaying ? 'Stop' : 'Start'),
        style: FilledButton.styleFrom(
          backgroundColor: _isPlaying ? const Color(0xFF5a3f47) : const Color(0xFF3a4e6e),
          foregroundColor: Colors.white,
        ),
      ),
    );
  }

  // ─── トラックパネル ───────────────────────────────────────
  Widget _buildTrackPanel(_TrackState t, {required int trackIndex, required double indicatorSize}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ビートインジケーター
        _buildBeatIndicator(t, trackIndex: trackIndex, size: indicatorSize),
        const SizedBox(height: 10),
        // BPM + BEAT ピル
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildPill(
              label: 'BPM', value: t.bpm,
              onDecrement: () => _setBpm(t, t.bpm - 1),
              onIncrement: () => _setBpm(t, t.bpm + 1),
              onTapValue: () => _showDialog('BPM', t.bpm, _minBpm, _maxBpm, (v) => _setBpm(t, v)),
              valueWidth: 40,
            ),
            const SizedBox(width: 8),
            _buildPill(
              label: 'BEAT', value: t.beatsPerMeasure,
              onDecrement: () => _setBeats(t, t.beatsPerMeasure - 1),
              onIncrement: () => _setBeats(t, t.beatsPerMeasure + 1),
              onTapValue: () => _showDialog('BEAT', t.beatsPerMeasure, 1, 32, (v) => _setBeats(t, v)),
              valueWidth: 26,
            ),
          ],
        ),
        const SizedBox(height: 10),
        // フィードバックトグル + Tap + Mute を横一列
        _buildControlRow(t),
      ],
    );
  }

  // ─── フィードバック + Tap + Mute 横一列 ──────────────────
  Widget _buildControlRow(_TrackState t) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children: [
        _toggle(Icons.volume_up,  'Sound',  t.soundEnabled,
            (v) => setState(() => t.soundEnabled = v)),
        _toggle(Icons.vibration,  'Haptic', t.hapticEnabled,
            (v) => setState(() => t.hapticEnabled = v)),
        if (_hasVibrator)
          _toggle(Icons.sensors, 'Vibrate', t.vibrationEnabled,
              (v) => setState(() => t.vibrationEnabled = v)),
        _toggle(Icons.flash_on,  'Flash',  t.flashEnabled,
            (v) => setState(() => t.flashEnabled = v)),
        // 仕切り代わりの細い線
        Container(width: 1, height: 36, color: const Color(0xFF43474e),
            margin: const EdgeInsets.symmetric(horizontal: 2)),
        // Tap ボタン
        _buildTapBtn(t),
        // Mute ボタン
        _buildMuteBtn(t),
      ],
    );
  }

  // ─── タップボタン（アイコンのみ） ────────────────────────
  Widget _buildTapBtn(_TrackState t) {
    return GestureDetector(
      onTap: () => _tapTempo(t),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF43474e),
          border: Border.all(color: const Color(0xFF5a5e66)),
        ),
        child: const Icon(Icons.touch_app, size: 22, color: Color(0xFFd0e4ff)),
      ),
    );
  }

  // ─── ミュートボタン ──────────────────────────────────────
  Widget _buildMuteBtn(_TrackState t) {
    return GestureDetector(
      onTap: () => setState(() {
          t.muted = !t.muted;
          if (t.muted) t.currentBeat = 0;
        }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: t.muted ? const Color(0xFF5a3f47) : const Color(0xFF43474e),
          border: Border.all(
            color: t.muted ? const Color(0xFFffb2be) : const Color(0xFF5a5e66),
          ),
        ),
        child: Icon(
          t.muted ? Icons.volume_off : Icons.volume_mute,
          size: 22,
          color: t.muted ? const Color(0xFFffb2be) : Colors.white54,
        ),
      ),
    );
  }

  // ─── ビートインジケーター ────────────────────────────────
  Widget _buildBeatIndicator(_TrackState t, {required int trackIndex, required double size}) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _BeatIndicatorPainter(
          total: t.beatsPerMeasure,
          current: _isPlaying ? t.currentBeat : 0,
          trackIndex: trackIndex,
        ),
        child: Center(
          child: _BeatText(
            beat: _isPlaying ? t.currentBeat : 0,
            total: t.beatsPerMeasure,
            size: size,
            trackIndex: trackIndex,
          ),
        ),
      ),
    );
  }

  // ─── コントロールピル（キーボード画面スタイル） ──────────
  Widget _buildPill({
    required String label,
    required int value,
    required VoidCallback onDecrement,
    required VoidCallback onIncrement,
    required VoidCallback onTapValue,
    required double valueWidth,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF43474e),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(
            color: Colors.white70, fontSize: 9, fontWeight: FontWeight.bold,
          )),
          const SizedBox(width: 6),
          _buildIconBtn(Icons.remove, onDecrement),
          GestureDetector(
            onTap: onTapValue,
            child: SizedBox(
              width: valueWidth,
              child: Text(
                '$value',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12,
                  decoration: TextDecoration.underline, decorationColor: Colors.white38,
                ),
              ),
            ),
          ),
          _buildIconBtn(Icons.add, onIncrement),
        ],
      ),
    );
  }

  // ─── アイコンボタン（長押し対応・キーボード画面スタイル） ─
  Widget _buildIconBtn(IconData icon, VoidCallback onTap) {
    return _LongPressIconBtn(icon: icon, onTap: onTap);
  }

  // ─── フィードバックトグル
  Widget _toggle(IconData icon, String label, bool value, ValueChanged<bool> onChanged) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: value ? const Color(0xFF3a4e6e) : const Color(0xFF252830),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: value ? const Color(0xFFd0e4ff) : const Color(0xFF43474e)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: value ? const Color(0xFFd0e4ff) : Colors.white30),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(
              fontSize: 8, color: value ? const Color(0xFFd0e4ff) : Colors.white30,
            )),
          ],
        ),
      ),
    );
  }
}

// ─── 長押し対応アイコンボタン ────────────────────────────────
// 最初の 600ms は 150ms 間隔、その後 80ms 間隔に加速
class _LongPressIconBtn extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _LongPressIconBtn({required this.icon, required this.onTap});

  @override
  State<_LongPressIconBtn> createState() => _LongPressIconBtnState();
}

class _LongPressIconBtnState extends State<_LongPressIconBtn> {
  Timer? _timer;

  void _startLongPress() {
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      widget.onTap();
    });
  }

  void _stopLongPress() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPressStart: (_) => _startLongPress(),
      onLongPressEnd: (_) => _stopLongPress(),
      onLongPressCancel: _stopLongPress,
      child: Container(
        width: 32,
        height: 32,
        decoration: const BoxDecoration(
          color: Color(0xFFd0e4ff),
          shape: BoxShape.circle,
        ),
        child: Icon(widget.icon, size: 16, color: const Color(0xFF003258)),
      ),
    );
  }
}

// ─── 円周ドット + 中心円 CustomPainter ───────────────────────
class _BeatIndicatorPainter extends CustomPainter {
  final int total;
  final int current;
  final int trackIndex;

  const _BeatIndicatorPainter({
    required this.total,
    required this.current,
    required this.trackIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final dotRadius = radius * 0.82; // ドット軌道
    final dotR = total > 20 ? 3.5 : (total > 12 ? 4.5 : 6.0);

    // 中心円の枠
    final bool isDown = current == 1;
    final downbeatColor =
        trackIndex == 0 ? const Color(0xFFffb2be) : const Color(0xFFb2ffcc);
    final borderColor = (current > 0 && isDown)
        ? downbeatColor
        : const Color(0xFF43474e);
    canvas.drawCircle(
      center,
      radius * 0.72,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // 外周ドット
    final Color activeColor = trackIndex == 0
        ? const Color(0xFFd0e4ff)
        : const Color(0xFFc8f2d0);
    final downColor = trackIndex == 0
        ? const Color(0xFFffb2be)
        : const Color(0xFFb2ffcc);
    const inactiveColor = Color(0xFF3a3e44);

    for (int i = 0; i < total; i++) {
      final angle = -pi / 2 + (2 * pi / total) * i;
      final pos = Offset(
        center.dx + dotRadius * cos(angle),
        center.dy + dotRadius * sin(angle),
      );
      final isActive = current == i + 1;
      final color = isActive
          ? (i == 0 ? downColor : activeColor)
          : inactiveColor;
      canvas.drawCircle(pos, isActive ? dotR * 1.25 : dotR,
          Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_BeatIndicatorPainter old) =>
      old.current != current || old.total != total || old.trackIndex != trackIndex;
}

// ─── ビート数テキスト（StatelessWidget で setState 分離） ────
class _BeatText extends StatelessWidget {
  final int beat;
  final int total;
  final double size;
  final int trackIndex;
  const _BeatText(
      {required this.beat,
      required this.total,
      required this.size,
      required this.trackIndex});

  @override
  Widget build(BuildContext context) {
    final bool isDown = beat == 1;
    final accentColor = trackIndex == 0
        ? (isDown ? const Color(0xFFffb2be) : const Color(0xFFd0e4ff))
        : (isDown ? const Color(0xFFb2ffcc) : const Color(0xFFc8f2d0));
    if (beat == 0) {
      return Text(
        '$total',
        style: TextStyle(
          fontSize: size * 0.28,
          color: Colors.white30,
          fontWeight: FontWeight.bold,
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$beat',
          style: TextStyle(
            fontSize: size * 0.34,
            fontWeight: FontWeight.bold,
            color: accentColor,
            height: 1.0,
            letterSpacing: -1,
          ),
        ),
        Text(
          '/ $total',
          style: TextStyle(
            fontSize: size * 0.13,
            color: accentColor.withAlpha(140),
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
