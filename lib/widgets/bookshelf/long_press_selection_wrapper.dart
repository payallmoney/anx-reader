import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Adds a long-press callback to a shelf cell WITHOUT competing with the
/// child's own tap gestures: it listens to raw pointer events at the very
/// front of the gesture arena era (Listener level, not GestureDetector),
/// so it never claims taps. Replaces the drag-to-reorder long-press which
/// used to shadow multi-select.
class LongPressSelectionWrapper extends StatefulWidget {
  const LongPressSelectionWrapper({
    super.key,
    required this.onLongPress,
    required this.child,
    this.duration = const Duration(milliseconds: 450),
  });

  final VoidCallback onLongPress;
  final Widget child;
  final Duration duration;

  @override
  State<LongPressSelectionWrapper> createState() =>
      _LongPressSelectionWrapperState();
}

class _LongPressSelectionWrapperState extends State<LongPressSelectionWrapper> {
  Timer? _timer;

  void _start(TapDownDetails details) {
    _timer?.cancel();
    _timer = Timer(widget.duration, widget.onLongPress);
  }

  void _cancel() {
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
    return Listener(
      onPointerDown: (event) => _start(TapDownDetails(
          globalPosition: event.position, localPosition: event.localPosition)),
      onPointerUp: (_) => _cancel(),
      onPointerCancel: (_) => _cancel(),
      onPointerMove: (event) {
        // moved too far: it's a scroll, not a long press
        if (event.delta.distanceSquared > 400) _cancel();
      },
      child: widget.child,
    );
  }
}
