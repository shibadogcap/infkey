import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'main_screen.dart';

void main() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    debugPrint('${record.level.name}: ${record.time}: ${record.message}');
  });

  runApp(const InfKeyApp());
}

class InfKeyApp extends StatelessWidget {
  const InfKeyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Infinite Keyboard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFd0e4ff),
          brightness: Brightness.dark,
          surface: const Color(0xFF1a1c1e),
        ),
      ),
      home: const MainScreen(),
    );
  }
}
