import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

// Top-level pitch detection (YIN algorithm) + RMS level
// Returns [pitch_hz_or_nan, rms_level]
List<double> detectPitch(List<double> samples) {
  const sampleRate = 22050;
  final n = samples.length;
  final halfN = n ~/ 2;

  // RMS レベル計算
  double rms = 0;
  for (final s in samples) {
    rms += s * s;
  }
  rms = sqrt(rms / n);

  if (rms < 0.008) return [double.nan, rms];

  // YIN: difference function d[tau]
  final d = List<double>.filled(halfN, 0.0);
  for (int tau = 1; tau < halfN; tau++) {
    for (int i = 0; i < halfN; i++) {
      final diff = samples[i] - samples[i + tau];
      d[tau] += diff * diff;
    }
  }

  // Cumulative mean normalized difference function
  final cmnd = List<double>.filled(halfN, 1.0);
  double runningSum = 0;
  for (int tau = 1; tau < halfN; tau++) {
    runningSum += d[tau];
    cmnd[tau] = runningSum == 0 ? 0 : d[tau] * tau / runningSum;
  }

  const minLag = 15;  // ~1470 Hz max @ 22050
  final maxLag = (sampleRate / 60).clamp(0, halfN - 2).toInt();
  const threshold = 0.12;

  // 閾値を下回る最初の谷を探す
  int bestTau = -1;
  for (int tau = minLag; tau <= maxLag; tau++) {
    if (cmnd[tau] < threshold) {
      // ローカル最小まで進む
      while (tau + 1 <= maxLag && cmnd[tau + 1] < cmnd[tau]) {
        tau++;
      }
      bestTau = tau;
      break;
    }
  }

  // 閾値を超えない場合はグローバル最小
  if (bestTau == -1) {
    double minVal = double.infinity;
    for (int tau = minLag; tau <= maxLag; tau++) {
      if (cmnd[tau] < minVal) {
        minVal = cmnd[tau];
        bestTau = tau;
      }
    }
    if (minVal > 0.35) return [double.nan, rms];
  }

  // 放物線補間でサブサンプル精度を上げる
  double refinedTau = bestTau.toDouble();
  if (bestTau > 0 && bestTau < halfN - 1) {
    final s0 = cmnd[bestTau - 1];
    final s1 = cmnd[bestTau];
    final s2 = cmnd[bestTau + 1];
    final denom = 2 * (2 * s1 - s2 - s0);
    if (denom.abs() > 1e-10) {
      refinedTau = bestTau + (s2 - s0) / denom;
    }
  }

  if (refinedTau <= 0) return [double.nan, rms];
  return [sampleRate / refinedTau, rms];
}

class TunerScreen extends StatefulWidget {
  final bool isActive;
  const TunerScreen({super.key, this.isActive = true});

  @override
  State<TunerScreen> createState() => _TunerScreenState();
}

class _TunerScreenState extends State<TunerScreen> {
  static const _sampleRate = 22050;
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
  static const _historySize = 2;
  int _silenceCounter = 0;
  static const _silenceThreshold = 3;

  bool _computing = false;  // prevent overlapping isolate calls
  bool _wasInTune = false;

  double _rmsLevel = 0.0; // マイクレベル (0.0〜1.0)

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _checkAndStart();
  }

  @override
  void didUpdateWidget(TunerScreen old) {
    super.didUpdateWidget(old);
    if (widget.isActive && !old.isActive) {
      // 画面が表示された
      if (_hasPermission) {
        _startListening();
      } else {
        _checkAndStart();
      }
    } else if (!widget.isActive && old.isActive) {
      // 画面が非表示になった
      _stopListening();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _recorder.stop().then((_) => _recorder.dispose());
    super.dispose();
  }

  Future<void> _stopListening() async {
    if (!_isRunning) return;
    await _sub?.cancel();
    _sub = null;
    await _recorder.stop();
    _buf.clear();
    _freqHistory.clear();
    _computing = false;
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
        ),
      );
      _sub = stream.listen(_onData);
      if (mounted) setState(() => _isRunning = true);
    } catch (e) {
      debugPrint('TunerScreen: startStream failed: $e');
    }
  }

  void _onData(Uint8List data) {
    for (int i = 0; i + 1 < data.length; i += 2) {
      int s = data[i] | (data[i + 1] << 8);
      if (s >= 32768) s -= 65536;
      _buf.add(s / 32768.0);
    }
    if (_buf.length >= _bufferSize && !_computing) {
      final chunk = List<double>.from(_buf.take(_bufferSize));
      _buf.removeRange(0, _bufferSize ~/ 4); // 1/4スライド → 更新頻度2倍
      _computing = true;
      compute(detectPitch, chunk).then((result) {
        _computing = false;
        final freq = result[0].isNaN ? null : result[0];
        final rms  = result[1];
        _updateDisplay(freq, rms);
      });
    }
  }

  void _updateDisplay(double? freq, double rms) {
    if (!mounted) return;
    // RMSレベルは常に更新（対数スケール、-40dB〜0dB を 0〜1 にマップ）
    final dbLevel = rms > 0 ? (20 * log(rms) / ln10).clamp(-40.0, 0.0) : -40.0;
    final level = ((dbLevel + 40) / 40).clamp(0.0, 1.0);
    if (freq == null) {
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
    final sorted = List<double>.from(_freqHistory)..sort();
    final smoothed = sorted[sorted.length ~/ 2];
    final info = _freqToNote(smoothed);
    setState(() {
      _freq = smoothed;
      _noteName = info.$1;
      _octave = info.$2;
      _cents = info.$3;
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildNoteCircle(),
            const SizedBox(height: 40),
            _buildCentsMeter(),
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
            _buildMicLevel(),
            const SizedBox(height: 16),
            _buildA4Pill(),
          ],
        ),
      ),
    );
  }

  // ─── マイクレベルメーター ──────────────────────────────
  Widget _buildMicLevel() {
    // _rmsLevel: 0.0 (無音) 〜 1.0 (最大)
    const barW = 200.0;
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
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
          _buildA4Btn(Icons.remove,
              () => setState(() => _a4Ref = (_a4Ref - 1).clamp(410, 480))),
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
          _buildA4Btn(Icons.add,
              () => setState(() => _a4Ref = (_a4Ref + 1).clamp(410, 480))),
          const SizedBox(width: 6),
          const Text('Hz',
              style: TextStyle(color: Colors.white38, fontSize: 9)),
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
            if (v != null) setState(() => _a4Ref = v.clamp(410, 480));
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
              if (v != null) setState(() => _a4Ref = v.clamp(410, 480));
              Navigator.of(ctx).pop();
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _buildNoteCircle() {
    final inTune = _noteName != '--' && _cents.abs() <= 5;
    final color = inTune ? Colors.greenAccent : const Color(0xFFd0e4ff);
    final borderColor = inTune ? Colors.greenAccent : const Color(0xFF43474e);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 180,
      height: 180,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: borderColor, width: 3),
        color: inTune ? Colors.greenAccent.withAlpha(20) : Colors.transparent,
      ),
      child: _noteName == '--'
          ? Icon(
              _isRunning ? Icons.mic : Icons.mic_none,
              size: 56,
              color: const Color(0xFF43474e),
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _noteName,
                  style: TextStyle(
                    fontSize: 60,
                    fontWeight: FontWeight.bold,
                    color: color,
                    height: 1.0,
                    letterSpacing: -2,
                  ),
                ),
                Text(
                  '$_octave',
                  style: TextStyle(
                    fontSize: 22,
                    color: color.withAlpha(180),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildCentsMeter() {
    final normalized = _noteName == '--'
        ? 0.5
        : (_cents.clamp(-50, 50) + 50) / 100.0;
    final inTune = _noteName != '--' && _cents.abs() <= 5;
    return Column(
      children: [
        SizedBox(
          width: 260,
          height: 48,
          child: CustomPaint(
            painter: _CentsMeterPainter(normalized, inTune),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Text('♭', style: TextStyle(color: Colors.white38, fontSize: 18)),
            SizedBox(width: 100),
            Text('♯', style: TextStyle(color: Colors.white38, fontSize: 18)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _noteName == '--'
              ? '音を鳴らしてください'
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
