import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:audio_session/audio_session.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'main_screen.dart';
import 'settings_manager.dart';
import 'l10n.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final settings = SettingsManager();
  await settings.init();

  // 言語の初期設定
  if (settings.language != 'auto') {
    L10n().locale = settings.language;
  } else {
    // 実際にはWidgetsBinding.instance.platformDispatcher.localeなどで判定可能
    // 簡易的にjaをデフォルトにする
    L10n().locale = 'ja';
  }

  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    debugPrint('${record.level.name}: ${record.time}: ${record.message}');
  });

  // オーディオセッションの設定
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration(
    avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
    avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.mixWithOthers,
    avAudioSessionMode: AVAudioSessionMode.defaultMode,
    avAudioSessionRouteSharingPolicy: AVAudioSessionRouteSharingPolicy.defaultPolicy,
    avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
    androidAudioAttributes: AndroidAudioAttributes(
      contentType: AndroidAudioContentType.music,
      flags: AndroidAudioFlags.none,
      usage: AndroidAudioUsage.game,
    ),
    androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
    androidWillPauseWhenDucked: false,
  ));

  runApp(const InfKeyApp());
}

class InfKeyApp extends StatefulWidget {
  const InfKeyApp({super.key});

  @override
  State<InfKeyApp> createState() => InfKeyAppState();

  static InfKeyAppState of(BuildContext context) =>
      context.findAncestorStateOfType<InfKeyAppState>()!;
}

class InfKeyAppState extends State<InfKeyApp> {
  final _settings = SettingsManager();

  void rebuild() {
    setState(() {});
  }

  ThemeMode _getThemeMode() {
    switch (_settings.themeMode) {
      case 1:
        return ThemeMode.light;
      case 2:
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Color _getSeedColor() {
    switch (_settings.colorSeed) {
      case 1: return Colors.blue;
      case 2: return Colors.green;
      case 3: return Colors.red;
      case 4: return Colors.purple;
      case 5: return Colors.orange;
      default: return const Color(0xFF4285F4);
    }
  }

  @override
  Widget build(BuildContext context) {
    final useDynamic = _settings.colorSeed == 0;
    final seedColor = _getSeedColor();

    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final lightScheme = (useDynamic && lightDynamic != null)
            ? lightDynamic
            : ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.light);
        
        var darkScheme = (useDynamic && darkDynamic != null)
            ? darkDynamic
            : ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.dark);
        
        if (_settings.isOled) {
          darkScheme = darkScheme.copyWith(
            surface: Colors.black,
            surfaceContainer: Colors.black,
            surfaceContainerHigh: Colors.black,
            surfaceContainerHighest: const Color(0xFF121212),
          );
        }

        return MaterialApp(
          title: 'Infinite Keyboard',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: lightScheme,
            scaffoldBackgroundColor: lightScheme.surface,
            fontFamily: 'NotoSansJP',
            fontFamilyFallback: const ['sans-serif'],
            navigationBarTheme: NavigationBarThemeData(
              backgroundColor: lightScheme.surface,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              indicatorColor: lightScheme.primaryContainer,
              labelTextStyle: WidgetStateProperty.all(const TextStyle(
                fontFamily: 'NotoSansJP',
                fontSize: 12,
              )),
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: darkScheme,
            scaffoldBackgroundColor: darkScheme.surface,
            fontFamily: 'NotoSansJP',
            fontFamilyFallback: const ['sans-serif'],
            navigationBarTheme: NavigationBarThemeData(
              backgroundColor: darkScheme.surface,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              indicatorColor: darkScheme.primaryContainer,
              labelTextStyle: WidgetStateProperty.all(const TextStyle(
                fontFamily: 'NotoSansJP',
                fontSize: 12,
              )),
            ),
          ),
          themeMode: _getThemeMode(),
          home: const MainScreen(),
        );
      },
    );
  }
}
