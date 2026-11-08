import 'package:flutter/material.dart';

import '../theme.dart';

/// The gap between two panels; drag it to resize them. A line shows on hover.
class Splitter extends StatefulWidget {
  final Axis axis; // vertical: a left/right divider; horizontal: top/bottom
  final ValueChanged<double> onDrag;
  final VoidCallback? onEnd;
  const Splitter({super.key, required this.axis, required this.onDrag, this.onEnd});

  @override
  State<Splitter> createState() => _SplitterState();
}

class _SplitterState extends State<Splitter> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final v = widget.axis == Axis.vertical;
    return MouseRegion(
      cursor: v ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: v ? (d) => widget.onDrag(d.delta.dx) : null,
        onVerticalDragUpdate: v ? null : (d) => widget.onDrag(d.delta.dy),
        onHorizontalDragEnd: v ? (_) => widget.onEnd?.call() : null,
        onVerticalDragEnd: v ? null : (_) => widget.onEnd?.call(),
        child: SizedBox(
          width: v ? 8 : double.infinity,
          height: v ? double.infinity : 8,
          child: Center(
            child: Container(
              width: v ? (_hover ? 2 : 1) : double.infinity,
              height: v ? double.infinity : (_hover ? 2 : 1),
              color: _hover ? c.accent : Colors.transparent,
            ),
          ),
        ),
      ),
    );
  }
}
