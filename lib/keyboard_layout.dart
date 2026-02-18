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

  Color _getWhiteKeyColor(bool active) {
    if (active) return _getActiveColor();
    switch (widget.type) {
      case 'aug': return const Color(0xFF5d4037);
      case 'dim': return const Color(0xFF4a4458);
      case 'min': return const Color(0xFF3f4759);
      case 'maj': return const Color(0xFF5a3f47);
      case 'melody': return const Color(0xFFe2e2e6);
      default: return Colors.white;
    }
  }

  Color _getBlackKeyColor(bool active) {
    if (active) return _getActiveColor();
    switch (widget.type) {
      case 'aug': return const Color(0xFF3e2723);
      case 'dim': return const Color(0xFF332d41);
      case 'min': return const Color(0xFF2e3546);
      case 'maj': return const Color(0xFF442a32);
      case 'melody': return const Color(0xFF1a1c1e);
      default: return Colors.black;
    }
  }

  Color _getActiveColor() {
    switch (widget.type) {
      case 'aug': return const Color(0xFFffb5a0);
      case 'dim': return const Color(0xFFd0bcff);
      case 'min': return const Color(0xFFa8c7ff);
      case 'maj': return const Color(0xFFffb2be);
      case 'melody': return const Color(0xFFd0e4ff);
      default: return Colors.blue;
    }
  }

  @override
  Widget build(BuildContext context) {
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
                    color: _getWhiteKeyColor(active),
                    border: Border(right: BorderSide(color: Colors.black.withValues(alpha: 0.05))),
                  ),
                );
              }),
            ),
            // Black keys
            ...blackKeyPositions.entries.map((entry) {
              int note = entry.key;
              double left = entry.value * whiteKeyWidth;
              bool active = widget.activeNotes.contains(note);
              return Positioned(
                left: left,
                top: 0,
                child: Container(
                  width: blackKeyWidth,
                  height: height * 0.6,
                  decoration: BoxDecoration(
                    color: _getBlackKeyColor(active),
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(6),
                      bottomRight: Radius.circular(6),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      )
                    ],
                  ),
                ),
              );
            }),
            // Label
            Positioned(
              left: 12,
              top: height / 2 - 10, // Approximate centering logic 
              child: IgnorePointer(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    color: widget.type == 'melody' ? const Color(0xFF1a1c1e) : Colors.white.withValues(alpha: 0.6),
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
