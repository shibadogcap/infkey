import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:torch_light/torch_light.dart';
import 'audio_engine.dart';
import 'metronome_engine.dart';
import 'settings_manager.dart';
import 'l10n.dart';

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
  final _l10n = L10n();
  bool _isPlaying = false;
  bool _hasTorch   = false;

  static const _minBpm = 1;
  static const _maxBpm = 500;

  @override
  void initState() {
    super.initState();
    final settings = SettingsManager();
    final bpm = settings.bpm;
    final beats = settings.beatsPerMeasure;
    _a = _TrackState(engine: MetronomeTrack(bpm: bpm, beatsPerMeasure: beats), bpm: bpm, beatsPerMeasure: beats);
    _b = _TrackState(engine: MetronomeTrack(bpm: 120, beatsPerMeasure: 3), bpm: 120, beatsPerMeasure: 3);
    _b.muted = true; // 初期状態では B をミュート
    _a.engine.onTick    = (beat) => _onTick(beat, _a, 0);
    _b.engine.onTick    = (beat) => _onTick(beat, _b, 1);
    AudioEngine().init();
    _checkCapabilities();
  }

  Future<void> _checkCapabilities() async {
    try {
      bool hasTorch = false;
      if (!kIsWeb) {
        hasTorch = await TorchLight.isTorchAvailable();
      }
      if (mounted) {
        setState(() {
          _hasTorch = hasTorch;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  // ─── コールバック ─────────────────────────────────────────
  void _onTick(int beat, _TrackState t, int trackIndex) {
    if (!mounted) return;
    final isDown = beat == 1;
    final settings = SettingsManager();
    if (!t.muted) {
      // サウンド（オフセット適用）
      if (t.soundEnabled) {
        final delay = settings.soundOffsetMs;
        void doSound() => AudioEngine().playClick(isDown, trackIndex: trackIndex);
        if (delay <= 0) {
          doSound();
        } else {
          Future.delayed(Duration(milliseconds: delay), doSound);
        }
      }
      // ハプティクス（独立した設定）
      if (t.hapticEnabled && !kIsWeb) {
        final delay = settings.hapticOffsetMs;
        void doHaptic() => isDown ? HapticFeedback.heavyImpact() : HapticFeedback.lightImpact();
        if (delay <= 0) {
          doHaptic();
        } else {
          Future.delayed(Duration(milliseconds: delay), doHaptic);
        }
      }
      // フラッシュ（オフセット適用）
      if (t.flashEnabled && _hasTorch && !kIsWeb) {
        final delay = settings.flashOffsetMs;
        if (delay <= 0) {
          _torchFlash(isDown);
        } else {
          Future.delayed(Duration(milliseconds: delay), () => _torchFlash(isDown));
        }
      }
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
      if (t == _a) SettingsManager().bpm = v;
    }
  }

  void _setBpm(_TrackState t, int v) {
    setState(() => t.bpm = v.clamp(_minBpm, _maxBpm));
    t.engine.updateBpm(t.bpm);
    if (t == _a) SettingsManager().bpm = t.bpm;
  }

  void _setBeats(_TrackState t, int v) {
    final n = v.clamp(1, 32);
    setState(() { t.beatsPerMeasure = n; t.currentBeat = 0; });
    t.engine.updateBeatsPerMeasure(n);
    if (t == _a) SettingsManager().beatsPerMeasure = n;
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
          decoration: InputDecoration(
            hintText: '$min ~ $max',
            suffixText: label == 'BPM' ? 'BPM' : '',
          ),
          onSubmitted: (s) {
            final v = int.tryParse(s);
            if (v != null) onChanged(v.clamp(min, max));
            Navigator.of(ctx).pop();
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(_l10n.tr('cancel')),
          ),
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
    return LayoutBuilder(builder: (ctx, constraints) {
      final isLandscape = constraints.maxWidth > constraints.maxHeight;
      
      double indicatorSize;
      if (isLandscape) {
        // 横画面: 幅に合わせてインジケーターサイズを調整
        indicatorSize = (constraints.maxWidth - 240) / 2.2;
        indicatorSize = indicatorSize.clamp(100.0, 160.0);
      } else {
        // 縦画面: 高さに合わせて調整
        indicatorSize = (constraints.maxHeight - 320) / 2.2;
        indicatorSize = indicatorSize.clamp(120.0, 160.0);
      }

      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: isLandscape ? _buildLandscape(indicatorSize) : _buildPortrait(indicatorSize),
        ),
      );
    });
  }

  Widget _buildPortrait(double indicatorSize) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildTrackPanel(_a, trackIndex: 0, indicatorSize: indicatorSize),
        const SizedBox(height: 16),
        _buildDivider(horizontal: true),
        const SizedBox(height: 16),
        _buildTrackPanel(_b, trackIndex: 1, indicatorSize: indicatorSize),
        const SizedBox(height: 28),
        _buildStartStop(),
      ],
    );
  }

  Widget _buildLandscape(double indicatorSize) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildTrackPanel(_a, trackIndex: 0, indicatorSize: indicatorSize),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _buildDivider(horizontal: false, length: indicatorSize * 1.2),
        ),
        _buildTrackPanel(_b, trackIndex: 1, indicatorSize: indicatorSize),
        const SizedBox(width: 32),
        _buildStartStop(),
      ],
    );
  }

  Widget _buildDivider({required bool horizontal, double length = 180}) {
    final colorScheme = Theme.of(context).colorScheme;
    return horizontal
        ? Container(height: 1, width: length * 1.5, color: colorScheme.outlineVariant)
        : Container(width: 1, height: length, color: colorScheme.outlineVariant);
  }

  // ─── スタート/ストップ ────────────────────────────────────
  Widget _buildStartStop() {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 140,
      height: 48,
      child: FilledButton.icon(
        onPressed: _startStop,
        icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow, size: 24),
        label: Text(_isPlaying ? _l10n.tr('stop') : _l10n.tr('start')),
        style: FilledButton.styleFrom(
          backgroundColor: _isPlaying ? colorScheme.errorContainer : colorScheme.primary,
          foregroundColor: _isPlaying ? colorScheme.onErrorContainer : colorScheme.onPrimary,
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
        const SizedBox(height: 12),
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
        const SizedBox(height: 12),
        // フィードバックトグル + Tap + Mute を横一列
        _buildControlRow(t),
      ],
    );
  }

// ─── フィードバック + Tap + Mute ─────────────────────────
  Widget _buildControlRow(_TrackState t) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          _toggle(Icons.volume_up, _l10n.tr('metro_sound'), t.soundEnabled,
              (v) => setState(() => t.soundEnabled = v)),
          const SizedBox(width: 4),
          if (!kIsWeb) ...[    
            _toggle(Icons.vibration, _l10n.tr('metro_haptic'), t.hapticEnabled,
                (v) => setState(() => t.hapticEnabled = v)),
            const SizedBox(width: 4),
            if (_hasTorch) ...[  
              _toggle(Icons.flash_on, _l10n.tr('metro_flash'), t.flashEnabled,
                  (v) => setState(() => t.flashEnabled = v)),
              const SizedBox(width: 4),
            ],
          ],
          _buildVerticalDivider(),
          const SizedBox(width: 4),
          _buildTapBtn(t),
          const SizedBox(width: 4),
          _buildMuteBtn(t),
        ],
      ),
    );
  }

  Widget _buildVerticalDivider() {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 1, height: 36,
      color: colorScheme.outlineVariant,
      margin: const EdgeInsets.symmetric(horizontal: 2),
    );
  }

  // ─── タップボタン（アイコンのみ） ────────────────────────
  Widget _buildTapBtn(_TrackState t) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: () => _tapTempo(t),
      iconSize: 22,
      icon: Icon(Icons.touch_app, color: colorScheme.primary),
      style: IconButton.styleFrom(
        side: BorderSide(color: colorScheme.outlineVariant),
        backgroundColor: colorScheme.surfaceContainerHighest,
      ),
    );
  }

  // ─── ミュートボタン ──────────────────────────────────────
  Widget _buildMuteBtn(_TrackState t) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: () => setState(() {
        t.muted = !t.muted;
        if (t.muted) t.currentBeat = 0;
      }),
      iconSize: 22,
      icon: Icon(t.muted ? Icons.volume_off : Icons.volume_mute),
      style: t.muted
          ? IconButton.styleFrom(
              backgroundColor: colorScheme.errorContainer,
              foregroundColor: colorScheme.onErrorContainer,
              side: BorderSide(color: colorScheme.error),
            )
          : IconButton.styleFrom(
              side: BorderSide(color: colorScheme.outlineVariant),
              backgroundColor: colorScheme.surfaceContainerHighest,
              foregroundColor: colorScheme.onSurfaceVariant,
            ),
    );
  }

  // ─── ビートインジケーター ────────────────────────────────
  Widget _buildBeatIndicator(_TrackState t, {required int trackIndex, required double size}) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _BeatIndicatorPainter(
          total: t.beatsPerMeasure,
          current: _isPlaying ? t.currentBeat : 0,
          trackIndex: trackIndex,
          colorScheme: colorScheme,
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
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(
            color: colorScheme.onSurfaceVariant, fontSize: 9, fontWeight: FontWeight.bold,
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
                style: TextStyle(
                  color: colorScheme.primary, fontWeight: FontWeight.bold, fontSize: 12,
                  decoration: TextDecoration.underline, decorationColor: colorScheme.primary.withValues(alpha: 0.3),
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
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        width: 58,
        decoration: BoxDecoration(
          color: value ? colorScheme.primaryContainer.withValues(alpha: 0.7) : colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: value ? colorScheme.primary : colorScheme.outlineVariant),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: value ? colorScheme.primary : colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
            const SizedBox(height: 2),
            FittedBox(
              child: Text(label, style: TextStyle(
                fontSize: 8, color: value ? colorScheme.primary : colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
              )),
            ),
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
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: widget.onTap,
      onLongPressStart: (_) => _startLongPress(),
      onLongPressEnd: (_) => _stopLongPress(),
      onLongPressCancel: _stopLongPress,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: colorScheme.secondaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(widget.icon, size: 16, color: colorScheme.onSecondaryContainer),
      ),
    );
  }
}

// ─── 円周ドット + 中心円 CustomPainter ───────────────────────
class _BeatIndicatorPainter extends CustomPainter {
  final int total;
  final int current;
  final int trackIndex;
  final ColorScheme colorScheme;

  const _BeatIndicatorPainter({
    required this.total,
    required this.current,
    required this.trackIndex,
    required this.colorScheme,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final dotRadius = radius * 0.82; // ドット軌道
    final dotR = total > 20 ? 3.5 : (total > 12 ? 4.5 : 6.0);

    // 中心円の枠
    final borderColor = current > 0
        ? (trackIndex == 0 ? colorScheme.primary : colorScheme.tertiary)
        : colorScheme.outlineVariant;
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
        ? colorScheme.primary
        : colorScheme.tertiary;
    final Color inactiveColor = colorScheme.onSurfaceVariant.withValues(alpha: 0.15);

    for (int i = 0; i < total; i++) {
      final angle = -pi / 2 + (2 * pi / total) * i;
      final pos = Offset(
        center.dx + dotRadius * cos(angle),
        center.dy + dotRadius * sin(angle),
      );
      final isActive = current == i + 1;
      final color = isActive
          ? activeColor
          : inactiveColor;
      canvas.drawCircle(pos, isActive ? dotR * 1.25 : dotR,
          Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_BeatIndicatorPainter old) =>
      old.current != current || old.total != total || old.trackIndex != trackIndex || old.colorScheme != colorScheme;
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
    final colorScheme = Theme.of(context).colorScheme;
    final Color activeColor = trackIndex == 0
        ? colorScheme.primary
        : colorScheme.tertiary;

    if (beat == 0) {
      return Text(
        '$total',
        style: TextStyle(
          fontSize: size * 0.28,
          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.2),
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
            color: activeColor,
            height: 1.0,
            letterSpacing: -1,
          ),
        ),
        Text(
          '/ $total',
          style: TextStyle(
            fontSize: size * 0.13,
            color: activeColor.withValues(alpha: 0.5),
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
