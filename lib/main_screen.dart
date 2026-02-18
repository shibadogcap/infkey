import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'audio_engine.dart';
import 'keyboard_layout.dart';
import 'metronome_screen.dart';
import 'tuner_screen.dart';

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

  // Settings
  int _transpose = 0;
  int _tuning = 0;

  // Navigation
  int _selectedIndex = 0;

  // MetronomeScreen を一度だけ生成して縦横で使い回す（State 保持のため）
  late final Widget _metronomeScreen;

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
    _audioEngine.init();
    _metronomeScreen = const MetronomeScreen();
  }

  @override
  void dispose() {
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
    final double gain = type == 'melody' ? 0.48 : 0.28;

    List<ShepardVoice> voices = [];
    for (final interval in intervals) {
      final voice = await _audioEngine.startVoice(
        note + interval,
        gain,
        transpose: _transpose.toDouble(),
        tuning: _tuning.toDouble(),
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
            transpose: _transpose.toDouble(),
            tuning: _tuning.toDouble(),
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
             transpose: _transpose.toDouble(),
             tuning: _tuning.toDouble(),
           );
         }
       }
    }
  }

  @override
  Widget build(BuildContext context) {
    return OrientationBuilder(
      builder: (context, orientation) {
        if (orientation == Orientation.landscape) {
          return _buildLandscape();
        } else {
          return _buildPortrait();
        }
      },
    );
  }

  Widget _buildPortrait() {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1c1e),
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
        TunerScreen(isActive: _selectedIndex == 2),
      ],
    );
  }

  Widget _buildLandscape() {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1c1e),
      body: SafeArea(
        child: Row(
          children: [
            // Nav - fixed width
            SizedBox(
              width: 58,
              child: _buildLandscapeNav(),
            ),
            // Page content
            Expanded(
              child: _selectedIndex == 0
                  ? _buildLandscapePlay()
                  : _buildLandscapeSubPage(),
            ),
          ],
        ),
      ),
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

  Widget _buildLandscapeSubPage() {
    return IndexedStack(
      index: _selectedIndex,
      children: <Widget>[
        const SizedBox.shrink(),
        _metronomeScreen,
        TunerScreen(isActive: _selectedIndex == 2),
      ],
    );
  }

  Widget _buildKeyboardStack() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF43474e),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 12,
            offset: const Offset(0, 4),
          )
        ],
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
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF43474e),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _buildLandscapeNav() {
    const items = [
      (Icons.piano_outlined, Icons.piano, 'Play'),
      (Icons.av_timer_outlined, Icons.av_timer, 'Metro'),
      (Icons.graphic_eq_outlined, Icons.graphic_eq, 'Tuner'),
    ];
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(items.length, (i) {
        final selected = _selectedIndex == i;
        return GestureDetector(
          onTap: () {
            if (_selectedIndex != i) HapticFeedback.selectionClick();
            setState(() => _selectedIndex = i);
          },
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 5),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFF3a4e6e) : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? items[i].$2 : items[i].$1,
                  color: selected ? const Color(0xFFd0e4ff) : Colors.white54,
                  size: 22,
                ),
                const SizedBox(height: 2),
                Text(
                  items[i].$3,
                  style: TextStyle(
                    fontSize: 9,
                    color: selected ? const Color(0xFFd0e4ff) : Colors.white38,
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  NavigationBar _buildBottomNav() {
    return NavigationBar(
      backgroundColor: const Color(0xFF1a1c1e),
      selectedIndex: _selectedIndex,
      onDestinationSelected: (i) {
        if (_selectedIndex != i) HapticFeedback.selectionClick();
        setState(() => _selectedIndex = i);
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.piano_outlined),
          selectedIcon: Icon(Icons.piano),
          label: 'Play',
        ),
        NavigationDestination(
          icon: Icon(Icons.av_timer_outlined),
          selectedIcon: Icon(Icons.av_timer),
          label: 'Metronome',
        ),
        NavigationDestination(
          icon: Icon(Icons.graphic_eq_outlined),
          selectedIcon: Icon(Icons.graphic_eq),
          label: 'Tuner',
        ),
      ],
    );
  }

  Widget _buildLandscapeControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildControlPillVertical("KEY", _transpose, -12, 12, (v) {
            setState(() => _transpose = v);
            _updateAllVoices();
          }),
          const SizedBox(height: 8),
          _buildControlPillVertical("TUNE", _tuning, -100, 100, (v) {
            setState(() => _tuning = v);
            _updateAllVoices();
          }),
        ],
      ),
    );
  }

  Widget _buildControlPillVertical(
      String label, int value, int min, int max, Function(int) onChanged) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF43474e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.white70,
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
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  decoration: TextDecoration.underline,
                  decorationColor: Colors.white38,
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
          _buildControlPill("KEY", _transpose, -12, 12, (v) {
             setState(() => _transpose = v);
             _updateAllVoices();
          }),
          const SizedBox(width: 12),
          _buildControlPill("TUNE", _tuning, -100, 100, (v) {
             setState(() => _tuning = v);
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
            child: const Text('Cancel'),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF43474e),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(
            color: Colors.white70, 
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
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  decoration: TextDecoration.underline,
                  decorationColor: Colors.white38,
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: const BoxDecoration(
          color: Color(0xFFd0e4ff),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 16, color: const Color(0xFF003258)),
      ),
    );
  }

  Widget _buildKeyWidget(String type, String label) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.black12)),
      ),
      child: KeyboardLayout(
        label: label,
        type: type,
        activeNotes: _activeNotes[type]!,
        onNoteStart: (ptr, note, t) => _onNoteStart(ptr, note, t),
        onNoteMove: (ptr, note, t) => _onNoteMove(ptr, note, t),
        onNoteEnd: (ptr, t) => _onNoteEnd(ptr),
      ),
    );
  }

  Widget _buildRow(String type, String label, {int flex = 1}) {
    return Expanded(
      flex: flex,
      child: _buildKeyWidget(type, label),
    );
  }
}
