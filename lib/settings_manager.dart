import 'package:shared_preferences/shared_preferences.dart';

class SettingsManager {
  static final SettingsManager _instance = SettingsManager._internal();
  factory SettingsManager() => _instance;
  SettingsManager._internal();

  late SharedPreferences _prefs;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  // A4 Reference Frequency
  int get a4Ref => _prefs.getInt('a4Ref') ?? 440;
  set a4Ref(int value) => _prefs.setInt('a4Ref', value);

  // Mic Gain
  double get micGain => _prefs.getDouble('micGain') ?? 1.0;
  set micGain(double value) => _prefs.setDouble('micGain', value);

  // Reference Tone Volume
  double get refVolume => _prefs.getDouble('refVolume') ?? 0.3;
  set refVolume(double value) => _prefs.setDouble('refVolume', value);

  // Global Volume
  double get globalVolume => _prefs.getDouble('globalVolume') ?? 1.0;
  set globalVolume(double value) => _prefs.setDouble('globalVolume', value);

  // Transpose
  int get transpose => _prefs.getInt('transpose') ?? 0;
  set transpose(int value) => _prefs.setInt('transpose', value);

  // Tuning (cents)
  int get tuning => _prefs.getInt('tuning') ?? 0;
  set tuning(int value) => _prefs.setInt('tuning', value);

  // Metronome BPM
  int get bpm => _prefs.getInt('bpm') ?? 120;
  set bpm(int value) => _prefs.setInt('bpm', value);

  // Metronome Beats
  int get beatsPerMeasure => _prefs.getInt('beatsPerMeasure') ?? 4;
  set beatsPerMeasure(int value) => _prefs.setInt('beatsPerMeasure', value);

  // Theme Mode: 0=system, 1=light, 2=dark
  int get themeMode => _prefs.getInt('themeMode') ?? 0;
  set themeMode(int value) => _prefs.setInt('themeMode', value);

  // Language: 'auto', 'ja', 'en'
  String get language => _prefs.getString('language') ?? 'auto';
  set language(String value) => _prefs.setString('language', value);

  // OLED Black
  bool get isOled => _prefs.getBool('isOled') ?? false;
  set isOled(bool value) => _prefs.setBool('isOled', value);

  // Color Seed Index: 0=Dynamic, 1=Blue, 2=Green, 3=Red, 4=Purple, 5=Orange
  int get colorSeed => _prefs.getInt('colorSeed') ?? 0;
  set colorSeed(int value) => _prefs.setInt('colorSeed', value);

  // Metronome feedback timing offsets (ms, range -20 to +50)
  int get hapticOffsetMs => _prefs.getInt('hapticOffsetMs') ?? 0;
  set hapticOffsetMs(int value) => _prefs.setInt('hapticOffsetMs', value);

  int get vibrationOffsetMs => _prefs.getInt('vibrationOffsetMs') ?? 0;
  set vibrationOffsetMs(int value) => _prefs.setInt('vibrationOffsetMs', value);

  int get soundOffsetMs => _prefs.getInt('soundOffsetMs') ?? 0;
  set soundOffsetMs(int value) => _prefs.setInt('soundOffsetMs', value);

  int get flashOffsetMs => _prefs.getInt('flashOffsetMs') ?? 0;
  set flashOffsetMs(int value) => _prefs.setInt('flashOffsetMs', value);
}
