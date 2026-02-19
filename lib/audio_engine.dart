import 'dart:math';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:logging/logging.dart';
import 'settings_manager.dart';

final _log = Logger('AudioEngine');

class AudioEngine {
  static final AudioEngine _instance = AudioEngine._internal();
  factory AudioEngine() => _instance;
  AudioEngine._internal();

  final SoLoud _soloud = SoLoud.instance;
  bool _isInitialized = false;
  Future<void>? _initFuture;

  // メトロノーム用クリック音源（プリロード）
  // Track A: 三角波 (click_a_hi/lo), Track B: 矩形波 (click_b_hi/lo)
  AudioSource? _clickAHi;
  AudioSource? _clickALo;
  AudioSource? _clickBHi;
  AudioSource? _clickBLo;

  static const double baseC0 = 16.3516;
  static const int numOctaves = 10;

  Future<void> init() async {
    if (_isInitialized) return;
    if (_initFuture != null) {
      await _initFuture;
      return;
    }
    _initFuture = _doInit();
    try {
      await _initFuture;
    } catch (e) {
      _log.severe('AudioEngine init failed: $e');
    } finally {
      _initFuture = null;
    }
  }

  Future<void> _doInit() async {
    await _soloud.init(bufferSize: 512);
    _soloud.setMaxActiveVoiceCount(32);
    
    final settings = SettingsManager();
    await settings.init();
    // SoLoudのデフォルトのボリュームをそのまま使用（* 8.0 は大きすぎて音割れの原因）
    _soloud.setGlobalVolume(settings.globalVolume);

    _clickAHi = await _soloud.loadAsset('assets/audio/click_a_hi.wav');
    _clickALo = await _soloud.loadAsset('assets/audio/click_a_lo.wav');
    _clickBHi = await _soloud.loadAsset('assets/audio/click_b_hi.wav');
    _clickBLo = await _soloud.loadAsset('assets/audio/click_b_lo.wav');
    _log.info('Click assets loaded');

    _isInitialized = true;
    _log.info('Audio engine initialized');
  }

  bool get isInitialized => _isInitialized;

  void setGlobalVolume(double volume) {
    if (_isInitialized) {
      _soloud.setGlobalVolume(volume);
    }
  }

  // iOS Webなどのための再開処理
  Future<void> resume() async {
    if (!_isInitialized) await init();
    // Web Audio contextを再開させるためにサイン波を瞬時にならす
    try {
      final source = await _soloud.loadWaveform(WaveForm.sin, false, 0.001, 0);
      _soloud.setWaveformFreq(source, 100);
      final handle = await _soloud.play(source, volume: 0.001);
      Future.delayed(const Duration(milliseconds: 50), () {
        _soloud.stop(handle);
        _soloud.disposeSource(source);
      });
    } catch (_) {}
  }

  void dispose() {
    if (_isInitialized) {
      try {
        for (final s in [_clickAHi, _clickALo, _clickBHi, _clickBLo]) {
          if (s != null) _soloud.disposeSource(s);
        }
      } catch (_) {}
      _soloud.deinit();
      _isInitialized = false;
    }
  }

  // チューナーお手本用
  AudioSource? _refToneSource;
  SoundHandle? _refToneHandle;

  // テスト用: 440Hz ビープ音を1秒鳴らす
  Future<void> playTestTone() async {
    await init();
    final source = await _soloud.loadWaveform(WaveForm.sin, false, 0.25, 0);
    _soloud.setWaveformFreq(source, 440);
    final handle = await _soloud.play(source, volume: 0.5);
    await Future.delayed(const Duration(seconds: 1));
    try {
      await _soloud.stop(handle);
      await _soloud.disposeSource(source);
    } catch (_) {}
  }

  // お手本の音を鳴らす
  Future<void> startReferenceTone(double frequency, {double volume = 0.3}) async {
    await init();
    if (_refToneHandle != null) await stopReferenceTone();

    _refToneSource = await _soloud.loadWaveform(WaveForm.sin, false, 0.25, 0);
    if (_refToneSource != null) {
      _soloud.setWaveformFreq(_refToneSource!, frequency);
      _refToneHandle = await _soloud.play(_refToneSource!, volume: volume);
    }
  }

  Future<void> stopReferenceTone() async {
    if (_refToneHandle != null) {
      try {
        await _soloud.stop(_refToneHandle!);
      } catch (_) {}
      _refToneHandle = null;
    }
    if (_refToneSource != null) {
      try {
        await _soloud.disposeSource(_refToneSource!);
      } catch (_) {}
      _refToneSource = null;
    }
  }

  // メトロノームクリック音を鳴らす（同期 fire-and-forget）
  // trackIndex: 0 = Track A（三角波）, 1 = Track B（矩形波）
  void playClick(bool isDownbeat, {int trackIndex = 0}) {
    if (!_isInitialized) return;
    final AudioSource? source;
    if (trackIndex == 0) {
      source = isDownbeat ? _clickAHi : _clickALo;
    } else {
      source = isDownbeat ? _clickBHi : _clickBLo;
    }
    if (source == null) return;
    _soloud.play(source, volume: isDownbeat ? 0.09 : 0.06);
  }

  // ノートを開始。各オクターブに独立したAudioSourceを生成してsetWaveformFreqで周波数を設定。
  Future<ShepardVoice> startVoice(
    int noteIndex,
    double gain, {
    double transpose = 0,
    double tuning = 0,
  }) async {
    await init();

    final totalSemitones = noteIndex + transpose + (tuning / 100);
    final pow2Semitones = pow(2.0, totalSemitones / 12.0).toDouble();

    // 全オクターブの音源生成と再生を並列実行
    final futures = <Future<(AudioSource, SoundHandle)>>[];

    for (int octave = 0; octave < numOctaves; octave++) {
      final freq = baseC0 * pow(2.0, octave.toDouble()) * pow2Semitones;
      final weight = _shepardWeight(freq);
      final vol = (weight * gain / 3.5).clamp(0.0, 0.6).toDouble();

      futures.add(
        _createVoiceOctave(freq, vol)
      );
    }

    final results = await Future.wait(futures);
    final sources = <int, AudioSource>{};
    final handles = <int, SoundHandle>{};

    for (int octave = 0; octave < results.length; octave++) {
      final (source, handle) = results[octave];
      sources[octave] = source;
      handles[octave] = handle;
    }

    return ShepardVoice(
      noteIndex: noteIndex,
      gain: gain,
      transpose: transpose,
      tuning: tuning,
      sources: sources,
      handles: handles,
    );
  }

  Future<(AudioSource, SoundHandle)> _createVoiceOctave(double freq, double vol) async {
    final source = await _soloud.loadWaveform(WaveForm.triangle, false, 1.0, 0);
    _soloud.setWaveformFreq(source, freq);
    final handle = await _soloud.play(source, volume: vol, looping: true);
    return (source, handle);
  }

  static double _shepardWeight(double freq) {
    const center = 400.0;
    const spread = 4.2;
    const ln2Val = 0.693147180559945; // log(2)
    if (freq <= 0) return 0;
    final x = log(freq / center) / ln2Val;
    return exp(-pow(x / spread, 4).toDouble());
  }
}

class ShepardVoice {
  int noteIndex;
  double gain;
  double transpose;
  double tuning;
  final Map<int, AudioSource> sources;
  final Map<int, SoundHandle> handles;
  final SoLoud _soloud = SoLoud.instance;

  ShepardVoice({
    required this.noteIndex,
    required this.gain,
    required this.transpose,
    required this.tuning,
    required this.sources,
    required this.handles,
  });

  void updateFrequencies(
    int newNote, {
    double transpose = 0,
    double tuning = 0,
  }) {
    noteIndex = newNote;
    this.transpose = transpose;
    this.tuning = tuning;
    _applyAll();
  }

  void _applyAll() {
    final totalSemitones = noteIndex + transpose + (tuning / 100);
    final pow2Semitones = pow(2.0, totalSemitones / 12.0).toDouble();
    for (int octave = 0; octave < AudioEngine.numOctaves; octave++) {
      final source = sources[octave];
      final handle = handles[octave];
      if (source == null || handle == null) continue;

      final freq = AudioEngine.baseC0 * pow(2.0, octave.toDouble()) * pow2Semitones;
      final weight = AudioEngine._shepardWeight(freq);
      final vol = (weight * gain / 6.0).clamp(0.0, 0.6).toDouble();

      try {
        _soloud.setWaveformFreq(source, freq);
        _soloud.setVolume(handle, vol);
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    for (final handle in handles.values) {
      try {
        _soloud.fadeVolume(handle, 0, const Duration(milliseconds: 100));
        _soloud.scheduleStop(handle, const Duration(milliseconds: 100));
      } catch (_) {}
    }
    await Future.delayed(const Duration(milliseconds: 150));
    for (final source in sources.values) {
      try {
        await _soloud.disposeSource(source);
      } catch (_) {}
    }
  }
}
