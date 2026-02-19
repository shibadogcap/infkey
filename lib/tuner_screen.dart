import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:pitch_detector_dart/pitch_detector.dart';
import 'audio_engine.dart';
import 'settings_manager.dart';
import 'l10n.dart';
import 'main.dart';

class TunerScreen extends StatefulWidget {
  final ValueListenable<bool> isActive;
  const TunerScreen({super.key, required this.isActive});

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
  late final PitchDetector _pitchDetector = PitchDetector(
    audioSampleRate: _sampleRate.toDouble(),
    bufferSize: _bufferSize,
  );
  final _settings = SettingsManager();
  final _l10n = L10n();

  bool _hasPermission = false;
  bool _isRunning = false;
  bool _isLoading = false;

  String _noteName = '--';
  int _octave = 4;
  int _cents = 0;
  double? _freq;

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
    widget.isActive.addListener(_onActiveChanged);
    if (widget.isActive.value) _checkAndStart();
  }

  void _onActiveChanged() {
    if (widget.isActive.value) {
      if (_hasPermission) {
        _startListening();
      } else {
        _checkAndStart();
      }
    } else {
      _stopListening();
      if (_isPlayingRef) _toggleRefTone();
    }
  }

  @override
  void didUpdateWidget(TunerScreen old) {
    super.didUpdateWidget(old);
    if (widget.isActive != old.isActive) {
      old.isActive.removeListener(_onActiveChanged);
      widget.isActive.addListener(_onActiveChanged);
      _onActiveChanged();
    }
  }

  @override
  void dispose() {
    widget.isActive.removeListener(_onActiveChanged);
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
      await AudioEngine().startReferenceTone(_settings.a4Ref.toDouble(), volume: _settings.refVolume);
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

  Future<void> _onData(Uint8List data) async {
    if (!_isRunning) return;

    for (int i = 0; i + 1 < data.length; i += 2) {
      int s = data[i] | (data[i + 1] << 8);
      if (s >= 32768) s -= 65536;
      // Gain を適用して感度を調整可能にする
      _buf.add((s / 32768.0) * _settings.micGain);
    }

    // ラグ対策：バッファがたまりすぎていたら古いデータを捨てる
    if (_buf.length > _bufferSize * 2) {
      _buf.removeRange(0, _buf.length - _bufferSize);
    }

    if (_buf.length >= _bufferSize && !_computing) {
      final chunk = List<double>.from(_buf.take(_bufferSize));
      // 50%オーバーラップで更新頻度を確保
      _buf.removeRange(0, _bufferSize ~/ 2);
      
      _computing = true;
      
      // RMSを計算（マイクレベル表示用）
      double sum = 0;
      for (final s in chunk) {
        sum += s * s;
      }
      final rms = sqrt(sum / chunk.length);

      final result = await _pitchDetector.getPitchFromFloatBuffer(chunk);
      _computing = false;
      
      // 期待される確度以上の場合のみ周波数を採用
      final freq = (result.probability > 0.4) ? result.pitch : -1.0;
      _updateDisplay(freq < 0 ? null : freq, rms);
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
    final semitones = 12 * log(freq / _settings.a4Ref) / ln2;
    final rounded = semitones.round();
    final cents = ((semitones - rounded) * 100).round().clamp(-50, 50);
    final midi = 69 + rounded;
    final idx = ((midi % 12) + 12) % 12;
    final octave = (midi ~/ 12) - 1;
    return (_noteNames[idx], octave, cents);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
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
              Icon(Icons.mic_off, size: 64, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
              const SizedBox(height: 20),
              Text(
                _l10n.tr('tuner_mic_required'),
                style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _checkAndStart,
                icon: const Icon(Icons.mic),
                label: Text(_l10n.tr('tuner_mic_allow')),
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
                        style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
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
                  style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
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
    final colorScheme = Theme.of(context).colorScheme;
    // _rmsLevel: 0.0 (無音) 〜 1.0 (最大)
    const barH = 6.0;
    // 3ゾーンで色を変える: 低→緑、中→黄、高→赤
    Color barColor;
    if (_rmsLevel < 0.6) {
      barColor = Colors.green;
    } else if (_rmsLevel < 0.85) {
      barColor = Colors.orange;
    } else {
      barColor = Colors.red;
    }
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _isRunning ? Icons.mic : Icons.mic_none,
              size: 13,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: barW,
              height: barH,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(barH / 2),
                child: Stack(
                  children: [
                    Container(color: colorScheme.surfaceContainerHighest),
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
          style: TextStyle(fontSize: 9, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
        ),
      ],
    );
  }

  // ─── A4基準周波数ピル ─────────────────────────────────
  Widget _buildA4Pill() {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('A4',
              style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 9,
                  fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          _buildA4Btn(Icons.remove, () {
            setState(() => _settings.a4Ref = (_settings.a4Ref - 1).clamp(410, 480));
            if (_isPlayingRef) AudioEngine().startReferenceTone(_settings.a4Ref.toDouble(), volume: _settings.refVolume);
            InfKeyApp.of(context).rebuild();
          }),
          GestureDetector(
            onTap: _showA4Dialog,
            child: SizedBox(
              width: 36,
              child: Text(
                '${_settings.a4Ref}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  decoration: TextDecoration.underline,
                  decorationColor: colorScheme.primary.withValues(alpha: 0.3),
                ),
              ),
            ),
          ),
          _buildA4Btn(Icons.add, () {
            setState(() => _settings.a4Ref = (_settings.a4Ref + 1).clamp(410, 480));
            if (_isPlayingRef) AudioEngine().startReferenceTone(_settings.a4Ref.toDouble(), volume: _settings.refVolume);
            InfKeyApp.of(context).rebuild();
          }),
          const SizedBox(width: 6),
          Text('Hz',
              style: TextStyle(color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5), fontSize: 9)),
          const SizedBox(width: 8),
          // お手本音ボタン
          GestureDetector(
            onTap: _toggleRefTone,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: _isPlayingRef ? colorScheme.primaryContainer : Colors.transparent,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isPlayingRef ? Icons.volume_up : Icons.volume_mute,
                size: 18,
                color: _isPlayingRef ? colorScheme.onPrimaryContainer : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildA4Btn(IconData icon, VoidCallback onTap) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: colorScheme.secondaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 14, color: colorScheme.onSecondaryContainer),
      ),
    );
  }

  Future<void> _showA4Dialog() async {
    final ctrl = TextEditingController(text: '${_settings.a4Ref}');
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
              setState(() => _settings.a4Ref = v.clamp(410, 480));
              if (_isPlayingRef) AudioEngine().startReferenceTone(_settings.a4Ref.toDouble(), volume: _settings.refVolume);
              InfKeyApp.of(context).rebuild();
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
                setState(() => _settings.a4Ref = v.clamp(410, 480));
                if (_isPlayingRef) AudioEngine().startReferenceTone(_settings.a4Ref.toDouble(), volume: _settings.refVolume);
                InfKeyApp.of(context).rebuild();
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
    final colorScheme = Theme.of(context).colorScheme;
    final inTune = _noteName != '--' && _cents.abs() <= 5;
    final color = inTune ? Colors.green : colorScheme.primary;
    final borderColor = inTune ? Colors.green : colorScheme.outline;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: borderColor, width: 3),
        color: inTune ? Colors.green.withValues(alpha: 0.1) : Colors.transparent,
      ),
      child: _noteName == '--'
          ? Icon(
              _isRunning ? Icons.mic : Icons.mic_none,
              size: size * 0.3,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
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
                    color: color.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildCentsMeter(double width) {
    final colorScheme = Theme.of(context).colorScheme;
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
            painter: _CentsMeterPainter(normalized, inTune, colorScheme),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('♭', style: TextStyle(color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4), fontSize: 18)),
            SizedBox(width: width * 0.4),
            Text('♯', style: TextStyle(color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4), fontSize: 18)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _noteName == '--'
              ? ''
              : '${_cents >= 0 ? '+' : ''}$_cents cent',
          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
        ),
      ],
    );
  }
}

class _CentsMeterPainter extends CustomPainter {
  final double normalized;
  final bool inTune;
  final ColorScheme colorScheme;
  const _CentsMeterPainter(this.normalized, this.inTune, this.colorScheme);

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
        ..color = colorScheme.outlineVariant
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );

    // Ticks at 0%, 25%, 50%, 75%, 100%
    final tickPaint = Paint()
      ..color = colorScheme.onSurfaceVariant.withValues(alpha: 0.2)
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
    final needleColor = inTune ? Colors.green : colorScheme.primary;
    canvas.drawCircle(Offset(nx, midY), 10, Paint()..color = needleColor);
    canvas.drawCircle(
      Offset(nx, midY),
      10,
      Paint()
        ..color = colorScheme.onPrimary.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_CentsMeterPainter old) =>
      old.normalized != normalized || old.inTune != inTune || old.colorScheme != colorScheme;
}
