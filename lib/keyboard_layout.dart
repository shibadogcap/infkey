import 'package:flutter/material.dart';

class KeyboardLayout extends StatefulWidget {
  final String label;
  final String type; // 'aug', 'dim', 'min', 'maj', 'melody'
  final Function(int pointerId, int noteIndex, String type) onNoteStart;
  final Function(int pointerId, int noteIndex, String type) onNoteMove;
  final Function(int pointerId, String type) onNoteEnd;
  final Set<int> activeNotes;

  const KeyboardLayout({
    super.key,
    required this.label,
    required this.type,
    required this.onNoteStart,
    required this.onNoteMove,
    required this.onNoteEnd,
    required this.activeNotes,
  });

  @override
  State<KeyboardLayout> createState() => _KeyboardLayoutState();
}

class _KeyboardLayoutState extends State<KeyboardLayout> {
  // Key indices mapping to standard 12-tone
  static const List<int> whiteKeyIndices = [0, 2, 4, 5, 7, 9, 11];
  
  // Black key positions relative to white keys (0-6)
  // CSS: 1: 0.6, 3: 1.75, 6: 3.65, 8: 4.8, 10: 5.9
  static const Map<int, double> blackKeyPositions = {
    1: 0.6,
    3: 1.75,
    6: 3.65,
    8: 4.8,
    10: 5.9,
  };

  void _handlePointer(PointerEvent event, BoxConstraints constraints) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      widget.onNoteEnd(event.pointer, widget.type);
      return;
    }

    final note = _getNoteAt(event.localPosition, constraints);
    
    if (note != -1) {
      if (event is PointerDownEvent) {
        widget.onNoteStart(event.pointer, note, widget.type);
      } else if (event is PointerMoveEvent) {
        widget.onNoteMove(event.pointer, note, widget.type);
      }
    } else {
      // If we drag outside of known keys, maybe stop?
      // For now, keep previous note playing or do nothing?
      // HTML version: getKeyFromPoint -> if (!key) return;
      // So if outside, it does nothing (keeps playing previous note of that pointer).
    }
  }

  int _getNoteAt(Offset localPosition, BoxConstraints constraints) {
    double width = constraints.maxWidth;
    double height = constraints.maxHeight;
    double whiteKeyWidth = width / 7.0;
    
    // Check black keys first (z-index higher)
    // Black keys height is 60%
    if (localPosition.dy <= height * 0.6) {
      for (final entry in blackKeyPositions.entries) {
        double left = entry.value * whiteKeyWidth;
        // Width is 100% / 12 = width / 12?
        // CSS: width: calc(100% / 12);
        double blackKeyWidth = width / 12.0; // Wait, CSS says 100%/12.
        
        if (localPosition.dx >= left && localPosition.dx <= left + blackKeyWidth) {
          return entry.key;
        }
      }
    }

    // Check white keys
    int whiteIndex = (localPosition.dx / whiteKeyWidth).floor();
    if (whiteIndex >= 0 && whiteIndex < whiteKeyIndices.length) {
      return whiteKeyIndices[whiteIndex];
    }

    return -1;
  }

  Color _getLabelColor(ColorScheme colorScheme) {
    if (widget.type == 'melody') {
      return colorScheme.onSurface.withValues(alpha: 0.4);
    }
    final isDark = colorScheme.brightness == Brightness.dark;
    // ダークモードでは白鍵=白なので、ラベルは暗い色で表示する
    return isDark
        ? Colors.black.withValues(alpha: 0.55)
        : colorScheme.onSurface.withValues(alpha: 0.55);
  }

  Color _getWhiteKeyColor(bool active, ColorScheme colorScheme) {
    if (active) return _getActiveColor(colorScheme);
    final isDark = colorScheme.brightness == Brightness.dark;
    if (isDark) {
      switch (widget.type) {
        case 'aug': return const Color(0xFF7A5950);  // 彩度と明るさをさらに向上（茶）
        case 'dim': return const Color(0xFF59507A);  // 彩度と明るさをさらに向上（紫）
        case 'min': return const Color(0xFF50597A);  // 彩度と明るさをさらに向上（青）
        case 'maj': return const Color(0xFF7A5059);  // 彩度と明るさをさらに向上（桃）
        case 'melody': return Colors.white;
        default: return Colors.white;
      }
    }
    switch (widget.type) {
      case 'aug': return const Color(0xFFefebe9);
      case 'dim': return const Color(0xFFf3e5f5);
      case 'min': return const Color(0xFFe3f2fd);
      case 'maj': return const Color(0xFFfce4ec);
      case 'melody': return Colors.white;
      default: return Colors.white;
    }
  }

  Color _getBlackKeyColor(bool active, ColorScheme colorScheme) {
    if (active) return _getActiveColor(colorScheme);
    final isDark = colorScheme.brightness == Brightness.dark;
    if (isDark) {
      switch (widget.type) {
        case 'aug': return const Color(0xFF4D3833); 
        case 'dim': return const Color(0xFF38334D);
        case 'min': return const Color(0xFF333B4D);
        case 'maj': return const Color(0xFF4D3338);
        case 'melody': return Colors.black;
        default: return Colors.black;
      }
    }
    switch (widget.type) {
      case 'aug': return const Color(0xFFd7ccc8);
      case 'dim': return const Color(0xFFe1bee7);
      case 'min': return const Color(0xFFbbdefb);
      case 'maj': return const Color(0xFFf8bbd0);
      case 'melody': return colorScheme.onSurface;
      default: return colorScheme.onSurface;
    }
  }

  Color _getActiveColor(ColorScheme colorScheme) {
    final isDark = colorScheme.brightness == Brightness.dark;
    if (isDark) {
      // ダークモード: 押したときはもう少し鮮やかに
      switch (widget.type) {
        case 'aug': return const Color(0xFF6D4C41); 
        case 'dim': return const Color(0xFF512DA8);
        case 'min': return const Color(0xFF1976D2);
        case 'maj': return const Color(0xFFC2185B);
        case 'melody': return colorScheme.primary;
        default: return colorScheme.primary;
      }
    }
    // ライトモード
    switch (widget.type) {
      case 'aug': return const Color(0xFFd84315);
      case 'dim': return const Color(0xFF673ab7);
      case 'min': return const Color(0xFF1976d2);
      case 'maj': return const Color(0xFFe91e63);
      case 'melody': return colorScheme.primary;
      default: return colorScheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      double width = constraints.maxWidth;
      double height = constraints.maxHeight; // Use provided height constraints
      double whiteKeyWidth = width / 7.0;
      double blackKeyWidth = width / 12.0;

      return Listener(
        onPointerDown: (e) => _handlePointer(e, constraints),
        onPointerMove: (e) => _handlePointer(e, constraints),
        onPointerUp: (e) => widget.onNoteEnd(e.pointer, widget.type),
        onPointerCancel: (e) => widget.onNoteEnd(e.pointer, widget.type),
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            // White keys
            Row(
              children: List.generate(7, (i) {
                int note = whiteKeyIndices[i];
                bool active = widget.activeNotes.contains(note);
                return Container(
                  width: whiteKeyWidth,
                  height: height,
                  decoration: BoxDecoration(
                    color: _getWhiteKeyColor(active, colorScheme),
                  ),
                );
              }),
            ),
            // Black keys without border
            ...blackKeyPositions.entries.map((entry) {
              int note = entry.key;
              double left = entry.value * whiteKeyWidth;
              bool active = widget.activeNotes.contains(note);
              return Positioned(
                left: left,
                top: 0,
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(6),
                    bottomRight: Radius.circular(6),
                  ),
                  child: Container(
                    width: blackKeyWidth,
                    height: height * 0.6,
                    decoration: BoxDecoration(
                      color: _getBlackKeyColor(active, colorScheme),
                    ),
                  ),
                ),
              );
            }),
            // Label
            Positioned(
              left: 12,
              top: height / 2 - 10,
              child: IgnorePointer(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    color: _getLabelColor(colorScheme),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}