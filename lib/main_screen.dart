import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'audio_engine.dart';
import 'keyboard_layout.dart';
import 'metronome_screen.dart';
import 'tuner_screen.dart';
import 'settings_screen.dart';
import 'settings_manager.dart';
import 'l10n.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class VoiceGroup {
  final int pointerId;
  int rootNote;
  final String type;
  final List<ShepardVoice> voices;

  VoiceGroup(this.pointerId, this.rootNote, this.type, this.voices);
}

class _MainScreenState extends State<MainScreen> {
  final AudioEngine _audioEngine = AudioEngine();
  final Map<int, VoiceGroup> _activeGroups = {};
  final _settings = SettingsManager();
  final _l10n = L10n();
  
  // State for UI updates
  // We need to know which keys are active for each row type to highlight them.
  // Map<Type, Set<Note>> is inefficient if we just want to rebuild fast.
  // Actually, we can just rebuild the whole tree or use ValueNotifiers.
  // Given 60fps requirement, setState on parent might be okay if the tree is light.
  final Map<String, Set<int>> _activeNotes = {
    'maj': {},
    'min': {},
    'dim': {},
    'aug': {},
    'melody': {},
  };

  // Navigation
  int _selectedIndex = 0;
  bool _audioNeedsResume = kIsWeb;
  final ValueNotifier<bool> _tunerActive = ValueNotifier(false);

  // 各画面を一度だけ生成して縦横で使い回す（State 保持のため）
  late final Widget _metronomeScreen;
  late final Widget _tunerScreen;

  // Chord Map
  static const Map<String, List<int>> _chordMap = {
    'maj': [0, 4, 7],
    'min': [0, 3, 7],
    'dim': [0, 3, 6],
    'aug': [0, 4, 8],
    'melody': [0],
  };

  @override
  void initState() {
    super.initState();
    _initAsync();
    _metronomeScreen = const MetronomeScreen();
    _tunerScreen = TunerScreen(isActive: _tunerActive);
  }

  Future<void> _initAsync() async {
    await _settings.init();
    await _audioEngine.init();
    if (mounted) setState(() {});
  }

  void _onDestinationSelected(int idx) {
    if (_selectedIndex == idx) return;
    HapticFeedback.selectionClick();
    setState(() {
      _selectedIndex = idx;
      _tunerActive.value = (idx == 2);
    });
  }

  @override
  void dispose() {
    _tunerActive.dispose();
    _audioEngine.dispose();
    super.dispose();
  }

  void _updateActiveNotes() {
    // Reset
    _activeNotes.forEach((key, value) => value.clear());

    // Populate from active groups
    for (final group in _activeGroups.values) {
        // Highlight root note? Only root note is highlighted in original JS?
        // JS: keyUsage[type][note]++. updateVisuals checks if > 0.
        // And JS only increments root note usage.
        _activeNotes[group.type]!.add(group.rootNote);
    }
    setState(() {});
  }

  Future<void> _onNoteStart(int pointerId, int note, String type) async {
    if (_activeGroups.containsKey(pointerId)) return;

    // Start voices
    final intervals = _chordMap[type] ?? [0];
    final double gain = type == 'melody' ? 0.65 : 0.45;

    List<ShepardVoice> voices = [];
    for (final interval in intervals) {
      final voice = await _audioEngine.startVoice(
        note + interval,
        gain,
        transpose: _settings.transpose.toDouble(),
        tuning: _settings.tuning.toDouble(),
      );
      voices.add(voice);
    }

    _activeGroups[pointerId] = VoiceGroup(pointerId, note, type, voices);
    _updateActiveNotes();
  }

  void _onNoteMove(int pointerId, int note, String type) {
    final group = _activeGroups[pointerId];
    if (group == null || group.type != type) return;

    if (group.rootNote != note) {
      group.rootNote = note;
      final intervals = _chordMap[type] ?? [0];
      
      for (int i = 0; i < group.voices.length; i++) {
        if (i < intervals.length) {
          group.voices[i].updateFrequencies(
            note + intervals[i],
            transpose: _settings.transpose.toDouble(),
            tuning: _settings.tuning.toDouble(),
          );
        }
      }
      _updateActiveNotes();
    }
  }

  void _onNoteEnd(int pointerId) {
    final group = _activeGroups.remove(pointerId);
    if (group != null) {
      for (final voice in group.voices) {
        voice.stop(); // async but fire-and-forget is OK
      }
      _updateActiveNotes();
    }
  }

  void _updateAllVoices() {
    for (final group in _activeGroups.values) {
       final intervals = _chordMap[group.type] ?? [0];
       for (int i = 0; i < group.voices.length; i++) {
         if (i < intervals.length) {
           group.voices[i].updateFrequencies(
             group.rootNote + intervals[i],
             transpose: _settings.transpose.toDouble(),
             tuning: _settings.tuning.toDouble(),
           );
         }
       }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        OrientationBuilder(
          builder: (context, orientation) {
            if (orientation == Orientation.landscape) {
              return _buildLandscape();
            } else {
              return _buildPortrait();
            }
          },
        ),
        if (_audioNeedsResume)
          _buildWebAudioOverlay(),
      ],
    );
  }

  Widget _buildWebAudioOverlay() {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.black.withValues(alpha: 0.8),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.volume_up, size: 80, color: colorScheme.onSurface),
            const SizedBox(height: 24),
            Text(
              _l10n.tr('web_audio_resume'),
              style: TextStyle(color: colorScheme.onSurface, fontSize: 18),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: () {
                _audioEngine.resume();
                setState(() => _audioNeedsResume = false);
              },
              child: Text(_l10n.tr('start_audio')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPortrait() {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (_selectedIndex == 0) _buildHeader(),
            Expanded(
              child: _buildPage(),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildPage() {
    return IndexedStack(
      index: _selectedIndex,
      children: [
        _buildKeyboardStack(),
        _metronomeScreen,
        _tunerScreen,
        const SettingsScreen(),
      ],
    );
  }

  Widget _buildBottomNav() {
    final colorScheme = Theme.of(context).colorScheme;
    return NavigationBar(
      selectedIndex: _selectedIndex,
      onDestinationSelected: _onDestinationSelected,
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      destinations: [
        NavigationDestination(icon: const Icon(Icons.piano), label: _l10n.tr('play')),
        NavigationDestination(icon: const Icon(Icons.av_timer), label: _l10n.tr('click')),
        NavigationDestination(icon: const Icon(Icons.graphic_eq), label: _l10n.tr('tune')),
        NavigationDestination(icon: const Icon(Icons.settings), label: _l10n.tr('settings')),
      ],
    );
  }

  Widget _buildLandscape() {
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            // Nav - fixed width
            _buildLandscapeNav(),
            // Page content
            Expanded(
              child: _selectedIndex == 0
                  ? _buildLandscapePlay()
                  : _buildPage(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLandscapeNav() {
    return NavigationRail(
      selectedIndex: _selectedIndex,
      onDestinationSelected: _onDestinationSelected,
      labelType: NavigationRailLabelType.all,
      destinations: [
        NavigationRailDestination(icon: const Icon(Icons.piano), label: Text(_l10n.tr('play'), style: const TextStyle(fontFamily: 'NotoSansJP'))),
        NavigationRailDestination(icon: const Icon(Icons.av_timer), label: Text(_l10n.tr('click'), style: const TextStyle(fontFamily: 'NotoSansJP'))),
        NavigationRailDestination(icon: const Icon(Icons.graphic_eq), label: Text(_l10n.tr('tune'), style: const TextStyle(fontFamily: 'NotoSansJP'))),
        NavigationRailDestination(icon: const Icon(Icons.settings), label: Text(_l10n.tr('settings'), style: const TextStyle(fontFamily: 'NotoSansJP'))),
      ],
    );
  }

  Widget _buildLandscapePlay() {
    return Row(
      children: [
        // Melody (flex 3)
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 4, 8),
            child: _buildKeyboardCard(
              child: _buildKeyWidget('melody', ''),
            ),
          ),
        ),
        // Chord rows (flex 2)
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: _buildKeyboardCard(
              child: Column(
                children: [
                  Expanded(child: _buildKeyWidget('aug', 'Aug')),
                  Expanded(child: _buildKeyWidget('dim', 'Dim')),
                  Expanded(child: _buildKeyWidget('min', 'Min')),
                  Expanded(child: _buildKeyWidget('maj', 'Maj')),
                ],
              ),
            ),
          ),
        ),
        // Controls - fixed width
        SizedBox(
          width: 82,
          child: _buildLandscapeControls(),
        ),
      ],
    );
  }

  Widget _buildKeyboardStack() {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildRow('aug', 'Aug'),
          _buildRow('dim', 'Dim'),
          _buildRow('min', 'Min'),
          _buildRow('maj', 'Maj'),
          _buildRow('melody', '', flex: 5),
        ],
      ),
    );
  }

  Widget _buildKeyboardCard({required Widget child}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _buildLandscapeControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildControlPillVertical("KEY", _settings.transpose, -12, 12, (v) {
            setState(() => _settings.transpose = v);
            _updateAllVoices();
          }),
          const SizedBox(height: 8),
          _buildControlPillVertical("TUNE", _settings.tuning, -100, 100, (v) {
            setState(() => _settings.tuning = v);
            _updateAllVoices();
          }),
        ],
      ),
    );
  }

  Widget _buildControlPillVertical(
      String label, int value, int min, int max, Function(int) onChanged) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 9,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          _buildIconBtn(Icons.add, () => onChanged((value + 1).clamp(min, max))),
          const SizedBox(height: 2),
          GestureDetector(
            onTap: () => _showInputDialog(label, value, min, max, onChanged),
            child: SizedBox(
              width: 36,
              child: Text(
                value.toString(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  decoration: TextDecoration.underline,
                  decorationColor: colorScheme.primary.withValues(alpha: 0.3),
                ),
              ),
            ),
          ),
          const SizedBox(height: 2),
          _buildIconBtn(
              Icons.remove, () => onChanged((value - 1).clamp(min, max))),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          _buildControlPill("KEY", _settings.transpose, -12, 12, (v) {
             setState(() => _settings.transpose = v);
             _updateAllVoices();
          }),
          const SizedBox(width: 12),
          _buildControlPill("TUNE", _settings.tuning, -100, 100, (v) {
             setState(() => _settings.tuning = v);
             _updateAllVoices();
          }),
        ],
      ),
    );
  }

  Future<void> _showInputDialog(
    String label, int current, int min, int max, Function(int) onChanged) async {
    final controller = TextEditingController(text: current.toString());
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          autofocus: true,
          decoration: InputDecoration(hintText: '$min ~ $max'),
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
              final v = int.tryParse(controller.text);
              if (v != null) onChanged(v.clamp(min, max));
              Navigator.of(ctx).pop();
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _buildControlPill(String label, int value, int min, int max, Function(int) onChanged) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(
            color: colorScheme.onSurfaceVariant, 
            fontSize: 9, 
            fontWeight: FontWeight.bold
          )),
          const SizedBox(width: 8),
          _buildIconBtn(Icons.remove, () => onChanged((value - 1).clamp(min, max))),
          GestureDetector(
            onTap: () => _showInputDialog(label, value, min, max, onChanged),
            child: SizedBox(
              width: 28,
              child: Text(
                value.toString(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  decoration: TextDecoration.underline,
                  decorationColor: colorScheme.primary.withValues(alpha: 0.3),
                ),
              ),
            ),
          ),
          _buildIconBtn(Icons.add, () => onChanged((value + 1).clamp(min, max))),
        ],
      ),
    );
  }

  Widget _buildIconBtn(IconData icon, VoidCallback onTap) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: colorScheme.secondaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 16, color: colorScheme.onSecondaryContainer),
      ),
    );
  }

  Widget _buildKeyWidget(String type, String label) {
    return KeyboardLayout(
      label: label,
      type: type,
      activeNotes: _activeNotes[type]!,
      onNoteStart: (ptr, note, t) => _onNoteStart(ptr, note, t),
      onNoteMove: (ptr, note, t) => _onNoteMove(ptr, note, t),
      onNoteEnd: (ptr, t) => _onNoteEnd(ptr),
    );
  }

  Widget _buildRow(String type, String label, {int flex = 1}) {
    return Expanded(
      flex: flex,
      child: _buildKeyWidget(type, label),
    );
  }
}
