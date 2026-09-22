// ignore_for_file: experimental_member_use
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
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

  // 自前生成した波形ソースのキャッシュ: key = 周波数(Hz)
  // 設定(オクターブEQ等)変更時に発音中のボイスへ再適用するためのフック。
  // MainScreen._updateAllVoices を登録する。
  void Function()? onOctaveEqChanged;

  // octave ごとの固定周波数で1ソース生成し、全ボイスで共有する（メモリ節約）。
  // 自前PCMソースは setWaveformFreq が使えないため、トランスポーズ等の
  // 調整は setRelativePlaySpeed で行う（速度は約0.5〜2倍に収まる）。
  // 値は Future にすることで、和音の並列リクエストでも1回のロードに集約する。
  final Map<double, Future<AudioSource>> _waveSourceCache = {};

  /// octave 番号に対応する固定周波数（トランスポーズ前）。
  static double _octaveFreq(int octave) =>
      baseC0 * pow(2.0, octave.toDouble()).toDouble();

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
    // 同時発音数を増やし、和音(3声×10octave=30ボイス)を複数同時に鳴らせるようにする。
    // 波形ソースのみでメモリは軽い。
    _soloud.setMaxActiveVoiceCount(192);

    final settings = SettingsManager();
    await settings.init();

    // ── グローバルフィルタ: Limiter + Compressor ──
    // 音割れ(クリッピング)を防ぎつつ、sin波でも十分な音圧を出すための底上げ。
    // 和音のピーク跳ね（やけにうるさい）も Limiter が抑える。
    try {
      // チェーン順: Compressor → Limiter。Limiter を最後にして出力の最終
      // 防衛線にし、makeupGain 後も確実に 0dB 未満へ収める。
      _soloud.filters.compressorFilter.activate();
      // 閾値を通常演奏より下げすぎると圧縮が常時効き、出力が縮んでしまう
      // （前回 -20dB は常時圧縮で音圧低下の主因だった）。通常レベルは通し、
      // ピークのみ穏やかに効く設定。
      _soloud.filters.compressorFilter.threshold.value = -6;
      _soloud.filters.compressorFilter.ratio.value = 3;
      _soloud.filters.compressorFilter.makeupGain.value = 4;
      _soloud.filters.compressorFilter.attackTime.value = 3;
      _soloud.filters.compressorFilter.releaseTime.value = 120;

      _soloud.filters.limiterFilter.activate();
      // 保険。急なアタックのピークのみを最終的に切り、出力を 0dB 未満に保つ。
      _soloud.filters.limiterFilter.threshold.value = -2;
      _soloud.filters.limiterFilter.outputCeiling.value = -0.5;
      _soloud.filters.limiterFilter.kneeWidth.value = 4;
      _soloud.filters.limiterFilter.attackTime.value = 0.5;
      _soloud.filters.limiterFilter.releaseTime.value = 100;
    } catch (e) {
      _log.warning('Global filters setup failed (may be unsupported): $e');
    }

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
        // 波形キャッシュも破棄（共有ソースなのでエンジン終了時のみ）
        for (final f in _waveSourceCache.values) {
          f.then((s) => _soloud.disposeSource(s), onError: (_) {});
        }
        _waveSourceCache.clear();
      } catch (_) {}
      try {
        _soloud.filters.limiterFilter.deactivate();
        _soloud.filters.compressorFilter.deactivate();
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
    // キーボードの音圧に合わせて引き上げ（ピークは Limiter が防衛）。
    // サブ(Track B)は波形特性(矩形波)で聞き取りやすさが落ちるため高く設定。
    final double vol = trackIndex == 0
        ? (isDownbeat ? 0.25 : 0.16)
        : (isDownbeat ? 0.38 : 0.24);
    _soloud.play(source, volume: vol);
  }

  // ノートを開始。各オクターブに独立したAudioSourceを生成してsetWaveformFreqで周波数を設定。
  // [voiceCount] はこの和音の声数（単音=1, maj/min/dim/aug=3）。和音の重なりも
  // 考慮して全体の RMS レベルが gain に収まるようボリュームを決める。
  Future<ShepardVoice> startVoice(
    int noteIndex,
    double gain, {
    double transpose = 0,
    double tuning = 0,
    int voiceCount = 1,
  }) async {
    await init();

    final totalSemitones = noteIndex + transpose + (tuning / 100);
    final pow2Semitones = pow(2.0, totalSemitones / 12.0).toDouble();

    // 全体の声数 = オクターブ数 ×和音声数。確率論的加算(√N 倍の RMS 増大)を
    // 1/√N で相殺し、重ねてもクリップしないようバランスを取る。
    final totalVoices = numOctaves * max(1, voiceCount);

    // 等ラウドネス補正済みの重みを全 octave で先に算出し、√(Σw²/N) で
    // 正規化する。これで補正を掛けても「総エネルギーは gain に一定」が保たれ、
    // 低音が聞こえるようになっても音圧・クリップ耐性は変わらない。
    final octaveEq = SettingsManager().octaveEq;
    final weights = <double>[
      for (int octave = 0; octave < numOctaves; octave++)
        _shepardWeight(_octaveFreq(octave) * pow2Semitones) *
            octaveEq[octave],
    ];
    final weightNorm =
        sqrt(weights.fold<double>(0, (s, w) => s + w * w) / numOctaves);
    final perVoice = (gain / (sqrt(totalVoices.toDouble()) * weightNorm))
        .clamp(0.0, 1.0)
        .toDouble();

    // 全オクターブの音源生成と再生を並列実行
    final futures = <Future<(AudioSource, SoundHandle)>>[];

    for (int octave = 0; octave < numOctaves; octave++) {
      final octaveFreq = _octaveFreq(octave);
      final vol = (weights[octave] * perVoice).clamp(0.0, 1.0).toDouble();

      futures.add(
        _createVoiceOctave(octaveFreq, pow2Semitones, vol)
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
      voiceCount: voiceCount,
      sources: sources,
      handles: handles,
    );
  }

  /// octave の固定周波数 [octaveFreq] のソースを取得し、[speed] 倍速で再生して
  /// 実際の周波数 octaveFreq*speed にする。ソースは全ボイスで共有キャッシュ。
  Future<(AudioSource, SoundHandle)> _createVoiceOctave(
    double octaveFreq,
    double speed,
    double vol,
  ) async {
    final source = await _getWaveSource(octaveFreq);
    final handle = await _soloud.play(source, volume: vol, looping: true);
    _soloud.setRelativePlaySpeed(handle, speed);
    return (source, handle);
  }

  /// 周波数ごとに1周期分のPCMを自前生成し、ゼロクロッシング（振幅0）から
  /// 始まるよう位相を合わせた AudioSource を返す。キャッシュ付き。
  ///
  /// SoLoud の loadWaveform は位相オフセットの公開APIが無く、triangle は
  /// 位相0で最小値(-0.5)から始まるため無フェードでポップの原因になる。
  /// 自前生成で i=0 のサンプルを必ず 0.0 にすることで、どの波形でも
  /// フェードインなしでポップのないアタックを実現する。
  ///
  /// 同じ周波数への同時リクエストは1回のロードに集約する。
  Future<AudioSource> _getWaveSource(double freq) async {
    final existing = _waveSourceCache[freq];
    if (existing != null) return existing;

    final completer = Completer<AudioSource>();
    _waveSourceCache[freq] = completer.future;
    try {
      final source = await _loadWaveSource(freq);
      completer.complete(source);
      return source;
    } catch (e) {
      // 失敗したらキャッシュから外し、次回リトライ可能にする。
      _waveSourceCache.remove(freq);
      completer.completeError(e);
      rethrow;
    }
  }

  Future<AudioSource> _loadWaveSource(double freq) async {
    final settings = SettingsManager();
    final waveformType = settings.waveformType; // 0=sin, 1=triangle

    // サンプルレートはエンジン初期化(44100)に合わせ、1周期を整数サンプルに。
    const sampleRate = 44100;
    final cycles = (sampleRate / freq).round();
    final n = cycles.clamp(4, sampleRate); // 1周期分（最低4サンプル）

    final Float32List pcm = Float32List(n);
    for (int i = 0; i < n; i++) {
      final phase = i / n; // 0..1（1周期）
      double s;
      if (waveformType == 1) {
        // 三角波: 本来 p=0 で -0.5。開始位相を +0.25 周期ずらし、
        // p=0 で 0 から上昇するようオフセットする。
        final p = phase + 0.25;
        final pp = p - p.floorToDouble();
        s = (pp > 0.5 ? (1.0 - (pp - 0.5) * 2) : pp * 2.0) - 0.5;
        // pp=0.25 のとき s = 0.5*2 - 0.5 = 0 → i=0 で 0 から始まる
      } else {
        // 正弦波: p=0 で sin(0)=0 → そのままゼロクロッシング。
        s = sin(2 * pi * phase);
      }
      pcm[i] = s;
    }

    final bytes = _encodeWavFloat32(pcm, sampleRate);
    return _soloud.loadMem('shepard_${freq.toStringAsFixed(3)}', bytes);
  }

  /// モノラル f32le の PCM を 44バイトの WAV ヘッダ付きの Uint8List に変換。
  static Uint8List _encodeWavFloat32(Float32List pcm, int sampleRate) {
    final byteData = ByteData(44 + pcm.lengthInBytes);
    final bytes = byteData.buffer.asUint8List();

    void writeStr(int offset, String s) {
      for (int i = 0; i < s.length; i++) {
        bytes[offset + i] = s.codeUnitAt(i);
      }
    }

    const channels = 1;
    const bitsPerSample = 32;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final dataSize = pcm.lengthInBytes;

    writeStr(0, 'RIFF');
    byteData.setUint32(4, 36 + dataSize, Endian.little);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    byteData.setUint32(16, 16, Endian.little); // fmt chunk size
    byteData.setUint16(20, 3, Endian.little); // format = 3 (IEEE float)
    byteData.setUint16(22, channels, Endian.little);
    byteData.setUint32(24, sampleRate, Endian.little);
    byteData.setUint32(28, byteRate, Endian.little);
    byteData.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
    byteData.setUint16(34, bitsPerSample, Endian.little);
    writeStr(36, 'data');
    byteData.setUint32(40, dataSize, Endian.little);

    // PCM 本体をコピー
    bytes.setRange(44, 44 + dataSize, pcm.buffer.asUint8List(pcm.offsetInBytes, dataSize));

    return bytes;
  }

  /// Shepard トーンの「全部同じ音量」は振幅ではなく聴覚上の音量で成立させる。
  /// 人間の聴覚(等ラウドネス曲線)では等振幅でも低音・高音は小さく聞こえ、
  /// その結果「聞こえているのは中高音だけ」になりシェパードの錯覚が弱まる。
  /// そのため等振幅に逆補正（低音を強調・超高音を軽減）を掛けて
  /// 「等ラウドネス」にし、全帯域が同じ音量で流れることで
  /// 無限上昇/下降の錯覚を強くする。総エネルギーは呼び出し側で正規化する。
  static double _shepardWeight(double freq) {
    if (freq <= 0) return 0;
    double db;
    if (freq < 400) {
      // 400Hz 以下: 50Hz 以下で最大 +9dB まで強調（低音の聴感を補正）
      final x = (log(400 / freq) / ln2).clamp(0.0, 3.0) / 3.0;
      db = 9 * x;
    } else if (freq > 4000) {
      // 4kHz 以上: 16kHz で最大 -4dB まで軽減（超高音の突出を抑える）
      final x = (log(freq / 4000) / ln2).clamp(0.0, 2.0) / 2.0;
      db = -4 * x;
    } else {
      db = 0;
    }
    return pow(10.0, db / 20.0).toDouble();
  }
}

class ShepardVoice {
  int noteIndex;
  double gain;
  double transpose;
  double tuning;
  final int voiceCount;
  final Map<int, AudioSource> sources;
  final Map<int, SoundHandle> handles;
  final SoLoud _soloud = SoLoud.instance;

  ShepardVoice({
    required this.noteIndex,
    required this.gain,
    required this.transpose,
    required this.tuning,
    required this.voiceCount,
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
    final totalVoices = AudioEngine.numOctaves * max(1, voiceCount);

    // startVoice と同じ重み計算・正規化でボリュームを算出し直す。
    final octaveEq = SettingsManager().octaveEq;
    final weights = <double>[
      for (int octave = 0; octave < AudioEngine.numOctaves; octave++)
        AudioEngine._shepardWeight(
                AudioEngine._octaveFreq(octave) * pow2Semitones) *
            octaveEq[octave],
    ];
    final weightNorm = sqrt(
        weights.fold<double>(0, (s, w) => s + w * w) /
        AudioEngine.numOctaves);
    final perVoice = (gain / (sqrt(totalVoices.toDouble()) * weightNorm))
        .clamp(0.0, 1.0)
        .toDouble();

    for (int octave = 0; octave < AudioEngine.numOctaves; octave++) {
      final source = sources[octave];
      final handle = handles[octave];
      if (source == null || handle == null) continue;

      final vol = (weights[octave] * perVoice).clamp(0.0, 1.0).toDouble();

      try {
        // ソースは octave 固定周波数のまま、相対再生速度でトランスポーズ。
        _soloud.setRelativePlaySpeed(handle, pow2Semitones);
        _soloud.setVolume(handle, vol);
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    // ハンドルを止めるだけ。ソースは AudioEngine の共有キャッシュが所有するため
    // ここで dispose してはいけない（他の声も同じソースを参照しており、
    // use-after-free / 二重解放でクラッシュする原因だった）。
    for (final handle in handles.values) {
      try {
        _soloud.fadeVolume(handle, 0, const Duration(milliseconds: 100));
        _soloud.scheduleStop(handle, const Duration(milliseconds: 100));
      } catch (_) {}
    }
    await Future.delayed(const Duration(milliseconds: 150));
  }
}
