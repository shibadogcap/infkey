import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'audio_engine.dart';

// FFT & Pitch Detection
// YIN よりも高速で Web/モバイル双方で安定した反応を目指す
class PitchResult {
  final double freq;
  final double rms;
  PitchResult(this.freq, this.rms);
}

// シンプルな FFT 実装 (Cooley-Tukey)
// 2048 サンプル程度なら Dart でも十分に実用的
class _FFT {
  static void transform(List<double> re, List<double> im) {
    final n = re.length;
    if (n <= 1) return;

    // Bit-reversal permutation
    for (int i = 1, j = 0; i < n; i++) {
      int bit = n >> 1;
      for (; (j & bit) != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        final tempRe = re[i]; re[i] = re[j]; re[j] = tempRe;
        final tempIm = im[i]; im[i] = im[j]; im[j] = tempIm;
      }
    }

    // Iterative FFT
    for (int len = 2; len <= n; len <<= 1) {
      double ang = 2 * pi / len;
      double wlenRe = cos(ang);
      double wlenIm = sin(ang);
      for (int i = 0; i < n; i += len) {
        double wRe = 1;
        double wIm = 0;
        for (int j = 0; j < len / 2; j++) {
          final uRe = re[i + j];
          final uIm = im[i + j];
          final vRe = re[i + j + len ~/ 2] * wRe - im[i + j + len ~/ 2] * wIm;
          final vIm = re[i + j + len ~/ 2] * wIm + im[i + j + len ~/ 2] * wRe;
          re[i + j] = uRe + vRe;
          im[i + j] = uIm + vIm;
          re[i + j + len ~/ 2] = uRe - vRe;
          im[i + j + len ~/ 2] = uIm - vIm;
          final nextWRe = wRe * wlenRe - wIm * wlenIm;
          wIm = wRe * wlenIm + wIm * wlenRe;
          wRe = nextWRe;
        }
      }
    }
  }
}

// HPS (Harmonic Product Spectrum) によるピッチ検出
// 倍音成分を考慮するため、単純なピーク検出より楽器に向いている
List<double> detectPitch(List<double> samples) {
  const sampleRate = 44100; // 録音側の設定とあわせる
  final n = samples.length;

  double rms = 0;
  for (final s in samples) {
    rms += s * s;
  }
  rms = sqrt(rms / n);
  // より小さい音でも反応するようにしきい値を下げる（0.005 -> 0.001 = -60dB）
  if (rms < 0.001) return [double.nan, rms];

  final re = List<double>.from(samples);
  final im = List<double>.filled(n, 0.0);

  // 窓関数 (Hamming)
  for (int i = 0; i < n; i++) {
    re[i] *= 0.54 - 0.46 * cos(2 * pi * i / (n - 1));
  }

  _FFT.transform(re, im);

  final mag = List<double>.filled(n ~/ 2, 0.0);
  for (int i = 0; i < n ~/ 2; i++) {
    mag[i] = sqrt(re[i] * re[i] + im[i] * im[i]);
  }

  // HPS: ダウンサンプリングしたスペクトルを乗算
  final hps = List<double>.from(mag);
  const harmonics = 3;
  for (int h = 2; h <= harmonics; h++) {
    for (int i = 0; i < n ~/ (2 * h); i++) {
      hps[i] *= mag[i * h];
    }
  }

  // 低周波ノイズ（80Hz以下）を無視
  final minBin = (80 * n / sampleRate).floor();
  int maxIdx = minBin;
  for (int i = minBin; i < n ~/ 4; i++) {
    if (hps[i] > hps[maxIdx]) maxIdx = i;
  }

  // 二次補間でより正確な周波数を推定
  double freq = maxIdx * sampleRate / n;
  if (maxIdx > 0 && maxIdx < n ~/ 2 - 1) {
    final y1 = hps[maxIdx - 1];
    final y2 = hps[maxIdx];
    final y3 = hps[maxIdx + 1];
    final p = (y3 - y1) / (2 * (2 * y2 - y1 - y3));
    freq = (maxIdx + p) * sampleRate / n;
  }

  return [freq, rms];
}

class TunerScreen extends StatefulWidget {
  final bool isActive;
  const TunerScreen({super.key, this.isActive = true});

  @override
  State<TunerScreen> createState() => _TunerScreenState();
}

class _TunerScreenState extends State<TunerScreen> {
  static const _sampleRate = 44100; // サンプリングレートを上げる（精度向上）
  static const _bufferSize = 2048;
  static const _noteNames = [
    'C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B',
  ];

  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  final List<double> _buf = [];

  bool _hasPermission = false;
  bool _isRunning = false;
  bool _isLoading = false;

  String _noteName = '--';
  int _octave = 4;
  int _cents = 0;
  double? _freq;

  // A4 reference frequency (Hz)
  int _a4Ref = 440;

  final List<double> _freqHistory = [];
  static const _historySize = 5; // ヒストリーを少し増やして安定化
  int _silenceCounter = 0;
  static const _silenceThreshold = 2; // 沈黙判定を早める

  bool _computing = false;
  bool _wasInTune = false;

  double _rmsLevel = 0.0;
  bool _isPlayingRef = false; // お手本音を再生中か
  double _lastCents = 0.0; // 針の振れを抑えるための移動平均用

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _checkAndStart();
  }

  @override
  void didUpdateWidget(TunerScreen old) {
    super.didUpdateWidget(old);
    if (widget.isActive && !old.isActive) {
      if (_hasPermission) {
        _startListening();
      } else {
        _checkAndStart();
      }
    } else if (!widget.isActive && old.isActive) {
      _stopListening();
      if (_isPlayingRef) _toggleRefTone();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _recorder.stop().then((_) => _recorder.dispose());
    AudioEngine().stopReferenceTone(); // お手本音を止める
    super.dispose();
  }

  Future<void> _toggleRefTone() async {
    if (_isPlayingRef) {
      await AudioEngine().stopReferenceTone();
      if (mounted) setState(() => _isPlayingRef = false);
    } else {
      // お手本音を鳴らす際も、チューナー（マイク）を止めないように変更
      await AudioEngine().startReferenceTone(_a4Ref.toDouble());
      if (mounted) setState(() => _isPlayingRef = true);
    }
  }

  Future<void> _stopListening() async {
    if (!_isRunning) return;
    await _sub?.cancel();
    _sub = null;
    await _recorder.stop();
    _buf.clear();
    _freqHistory.clear();
    _computing = false;
    _lastCents = 0.0;
    if (mounted) {
      setState(() {
        _isRunning = false;
        _noteName = '--';
        _freq = null;
        _cents = 0;
        _rmsLevel = 0.0;
        _wasInTune = false;
      });
    }
  }

  Future<void> _checkAndStart() async {
    if (mounted) setState(() => _isLoading = true);
    final ok = await _recorder.hasPermission();
    if (!mounted) return;
    setState(() {
      _hasPermission = ok;
      _isLoading = false;
    });
    if (ok) await _startListening();
  }

  Future<void> _startListening() async {
    if (_isRunning) return;
    try {
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRate,
          numChannels: 1,
          autoGain: false,      // 生音のため無効化
          echoCancel: false,    // エコーキャンセル無効化
          noiseSuppress: false, // ノイズ抑制無効化
        ),
      );
      _sub = stream.listen(_onData);
      if (mounted) setState(() => _isRunning = true);
    } catch (e) {
      debugPrint('TunerScreen: startStream failed: $e');
    }
  }

  void _onData(Uint8List data) {
    if (!_isRunning) return;

    for (int i = 0; i + 1 < data.length; i += 2) {
      int s = data[i] | (data[i + 1] << 8);
      if (s >= 32768) s -= 65536;
      _buf.add(s / 32768.0);
    }

    // ラグ対策：バッファがたまりすぎていたら古いデータを捨てる
    // 2回分以上たまっている場合は、最新の1回分だけ残す
    if (_buf.length > _bufferSize * 2) {
      _buf.removeRange(0, _buf.length - _bufferSize);
    }

    if (_buf.length >= _bufferSize && !_computing) {
      final chunk = List<double>.from(_buf.take(_bufferSize));
      // 50%オーバーラップで更新頻度を確保
      _buf.removeRange(0, _bufferSize ~/ 2);
      
      _computing = true;
      // Isolateのオーバーヘッドによるラグを避けるため、メインスレッドで計算
      // FFT 2048 は十分に高速（数ミリ秒）なので UI をブロックしません
      final result = detectPitch(chunk);
      _computing = false;
      _updateDisplay(result[0].isNaN ? null : result[0], result[1]);
    }
  }

  void _updateDisplay(double? freq, double rms) {
    if (!mounted) return;
    
    // マイクレベルの感度を大幅に上げる
    // -60dB (0.001) 〜 0dB (1.0) の範囲にする
    final dbLevel = rms > 0 ? (20 * log(rms) / ln10).clamp(-60.0, 0.0) : -60.0;
    // 表示上のレベル (0.0 〜 1.0)
    final level = ((dbLevel + 60) / 60).clamp(0.0, 1.0);
    
    if (freq == null || rms < 0.001) { // しきい値を下げて小さな音も拾う
      _silenceCounter++;
      if (_silenceCounter >= _silenceThreshold) {
        _freqHistory.clear();
        setState(() {
          _noteName = '--';
          _freq = null;
          _cents = 0;
          _rmsLevel = level;
        });
      } else {
        setState(() => _rmsLevel = level);
      }
      return;
    }
    _silenceCounter = 0;
    _freqHistory.add(freq);
    if (_freqHistory.length > _historySize) _freqHistory.removeAt(0);
    
    // 中央値で外れ値を除去
    final sorted = List<double>.from(_freqHistory)..sort();
    final smoothedFreq = sorted[sorted.length ~/ 2];
    
    final info = _freqToNote(smoothedFreq);
    
    // セント値の動きを滑らかにする（指数移動平均）
    // 前回のノートと同じであれば、急激な変化（ノイズ）を抑制する
    double currentCents = info.$3.toDouble();
    if (_noteName == info.$1) {
      // アルファ値: 0.3 (重み付け。値を小さくすると滑らかになるが反応が鈍る)
      _lastCents = _lastCents * 0.7 + currentCents * 0.3;
    } else {
      _lastCents = currentCents;
    }

    setState(() {
      _freq = smoothedFreq;
      _noteName = info.$1;
      _octave = info.$2;
      _cents = _lastCents.round();
      _rmsLevel = level;
    });
    // Haptic when transitioning to in-tune
    final nowInTune = info.$3.abs() <= 5;
    if (nowInTune && !_wasInTune) HapticFeedback.mediumImpact();
    _wasInTune = nowInTune;
  }

  (String, int, int) _freqToNote(double freq) {
    final semitones = 12 * log(freq / _a4Ref) / ln2;
    final rounded = semitones.round();
    final cents = ((semitones - rounded) * 100).round().clamp(-50, 50);
    final midi = 69 + rounded;
    final idx = ((midi % 12) + 12) % 12;
    final octave = (midi ~/ 12) - 1;
    return (_noteNames[idx], octave, cents);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_hasPermission) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.mic_off, size: 64, color: Colors.white38),
              const SizedBox(height: 20),
              const Text(
                'マイクへのアクセスが必要です',
                style: TextStyle(color: Colors.white70, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _checkAndStart,
                icon: const Icon(Icons.mic),
                label: const Text('許可する'),
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      final isLandscape = constraints.maxWidth > constraints.maxHeight;

      if (isLandscape) {
        final factor = (constraints.maxHeight / 380).clamp(0.6, 1.0);
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildNoteCircle(160 * factor),
                const SizedBox(width: 32),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildCentsMeter(240 * factor),
                    const SizedBox(height: 12),
                    AnimatedOpacity(
                      opacity: _freq != null ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 300),
                      child: Text(
                        _freq != null ? '${_freq!.toStringAsFixed(1)} Hz' : '',
                        style: const TextStyle(fontSize: 13, color: Colors.white38),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildMicLevel(180 * factor),
                    const SizedBox(height: 12),
                    _buildA4Pill(),
                  ],
                ),
              ],
            ),
          ),
        );
      }

      // 縦画面
      final factor = (constraints.maxWidth / 400).clamp(0.7, 1.0);
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildNoteCircle(180 * factor),
              SizedBox(height: 32 * factor),
              _buildCentsMeter(260 * factor),
              const SizedBox(height: 12),
              AnimatedOpacity(
                opacity: _freq != null ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: Text(
                  _freq != null ? '${_freq!.toStringAsFixed(1)} Hz' : '',
                  style: const TextStyle(fontSize: 13, color: Colors.white38),
                ),
              ),
              const SizedBox(height: 16),
              _buildMicLevel(200 * factor),
              const SizedBox(height: 16),
              _buildA4Pill(),
            ],
          ),
        ),
      );
    });
  }

  // ─── マイクレベルメーター ──────────────────────────────
  Widget _buildMicLevel(double barW) {
    // _rmsLevel: 0.0 (無音) 〜 1.0 (最大)
    const barH = 6.0;
    // 3ゾーンで色を変える: 低→緑、中→黄、高→赤
    Color barColor;
    if (_rmsLevel < 0.6) {
      barColor = const Color(0xFF4caf50);
    } else if (_rmsLevel < 0.85) {
      barColor = const Color(0xFFffb300);
    } else {
      barColor = const Color(0xFFef5350);
    }
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _isRunning ? Icons.mic : Icons.mic_none,
              size: 13,
              color: Colors.white38,
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: barW,
              height: barH,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(barH / 2),
                child: Stack(
                  children: [
                    Container(color: const Color(0xFF2a2e33)),
                    FractionallySizedBox(
                      widthFactor: _rmsLevel,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 60),
                        decoration: BoxDecoration(
                          color: barColor,
                          borderRadius: BorderRadius.circular(barH / 2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          _isRunning ? 'MIC' : '',
          style: const TextStyle(fontSize: 9, color: Colors.white24),
        ),
      ],
    );
  }

  // ─── A4基準周波数ピル ─────────────────────────────────
  Widget _buildA4Pill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF2a2e33),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFF43474e)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('A4',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: 9,
                  fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          _buildA4Btn(Icons.remove, () {
            setState(() => _a4Ref = (_a4Ref - 1).clamp(410, 480));
            if (_isPlayingRef) AudioEngine().startReferenceTone(_a4Ref.toDouble());
          }),
          GestureDetector(
            onTap: _showA4Dialog,
            child: SizedBox(
              width: 36,
              child: Text(
                '$_a4Ref',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  decoration: TextDecoration.underline,
                  decorationColor: Colors.white38,
                ),
              ),
            ),
          ),
          _buildA4Btn(Icons.add, () {
            setState(() => _a4Ref = (_a4Ref + 1).clamp(410, 480));
            if (_isPlayingRef) AudioEngine().startReferenceTone(_a4Ref.toDouble());
          }),
          const SizedBox(width: 6),
          const Text('Hz',
              style: TextStyle(color: Colors.white38, fontSize: 9)),
          const SizedBox(width: 8),
          // お手本音ボタン
          GestureDetector(
            onTap: _toggleRefTone,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: _isPlayingRef ? const Color(0xFF3a4e6e) : Colors.transparent,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isPlayingRef ? Icons.volume_up : Icons.volume_mute,
                size: 18,
                color: _isPlayingRef ? const Color(0xFFd0e4ff) : Colors.white30,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildA4Btn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: const BoxDecoration(
          color: Color(0xFFd0e4ff),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 14, color: const Color(0xFF003258)),
      ),
    );
  }

  Future<void> _showA4Dialog() async {
    final ctrl = TextEditingController(text: '$_a4Ref');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('A4 基準周波数'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(hintText: '410 ~ 480 Hz'),
          onSubmitted: (s) {
            final v = int.tryParse(s);
            if (v != null) {
              setState(() => _a4Ref = v.clamp(410, 480));
              if (_isPlayingRef) AudioEngine().startReferenceTone(_a4Ref.toDouble());
            }
            Navigator.of(ctx).pop();
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final v = int.tryParse(ctrl.text);
              if (v != null) {
                setState(() => _a4Ref = v.clamp(410, 480));
                if (_isPlayingRef) AudioEngine().startReferenceTone(_a4Ref.toDouble());
              }
              Navigator.of(ctx).pop();
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _buildNoteCircle(double size) {
    final inTune = _noteName != '--' && _cents.abs() <= 5;
    final color = inTune ? Colors.greenAccent : const Color(0xFFd0e4ff);
    final borderColor = inTune ? Colors.greenAccent : const Color(0xFF43474e);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: borderColor, width: 3),
        color: inTune ? Colors.greenAccent.withAlpha(20) : Colors.transparent,
      ),
      child: _noteName == '--'
          ? Icon(
              _isRunning ? Icons.mic : Icons.mic_none,
              size: size * 0.3,
              color: const Color(0xFF43474e),
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _noteName,
                  style: TextStyle(
                    fontSize: size * 0.33,
                    fontWeight: FontWeight.bold,
                    color: color,
                    height: 1.0,
                    letterSpacing: -2,
                  ),
                ),
                Text(
                  '$_octave',
                  style: TextStyle(
                    fontSize: size * 0.12,
                    color: color.withAlpha(180),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildCentsMeter(double width) {
    final normalized = _noteName == '--'
        ? 0.5
        : (_cents.clamp(-50, 50) + 50) / 100.0;
    final inTune = _noteName != '--' && _cents.abs() <= 5;
    return Column(
      children: [
        SizedBox(
          width: width,
          height: 48,
          child: CustomPaint(
            painter: _CentsMeterPainter(normalized, inTune),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('♭', style: TextStyle(color: Colors.white38, fontSize: 18)),
            SizedBox(width: width * 0.4),
            const Text('♯', style: TextStyle(color: Colors.white38, fontSize: 18)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _noteName == '--'
              ? ''
              : '${_cents >= 0 ? '+' : ''}$_cents cent',
          style: const TextStyle(fontSize: 12, color: Colors.white38),
        ),
      ],
    );
  }
}

class _CentsMeterPainter extends CustomPainter {
  final double normalized;
  final bool inTune;
  const _CentsMeterPainter(this.normalized, this.inTune);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final midY = size.height / 2;
    const pad = 16.0;

    // Track
    canvas.drawLine(
      Offset(pad, midY),
      Offset(w - pad, midY),
      Paint()
        ..color = const Color(0xFF43474e)
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );

    // Ticks at 0%, 25%, 50%, 75%, 100%
    final tickPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1.5;
    for (final frac in [0.0, 0.25, 0.5, 0.75, 1.0]) {
      final x = pad + (w - pad * 2) * frac;
      final tall = frac == 0.5;
      canvas.drawLine(
        Offset(x, midY - (tall ? 10 : 6)),
        Offset(x, midY + (tall ? 10 : 6)),
        tickPaint,
      );
    }

    // Needle
    final nx = pad + (w - pad * 2) * normalized;
    final needleColor = inTune ? Colors.greenAccent : const Color(0xFFd0e4ff);
    canvas.drawCircle(Offset(nx, midY), 10, Paint()..color = needleColor);
    canvas.drawCircle(
      Offset(nx, midY),
      10,
      Paint()
        ..color = Colors.black26
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_CentsMeterPainter old) =>
      old.normalized != normalized || old.inTune != inTune;
}
