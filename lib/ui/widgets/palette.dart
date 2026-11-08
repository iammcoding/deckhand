import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

class Command {
  final String title;
  final String group;
  final String? keys;
  final VoidCallback run;
  const Command(this.title, this.group, this.run, {this.keys});
}

/// ⌘K: every action, found by typing. Arrows to move, Enter to run, Esc out.
Future<void> showPalette(BuildContext context, List<Command> commands) => showDialog(
  context: context,
  barrierColor: Colors.black.withValues(alpha: 0.35),
  builder: (_) => _Palette(commands: commands),
);

class _Palette extends StatefulWidget {
  final List<Command> commands;
  const _Palette({required this.commands});

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  final _q = TextEditingController();
  int _sel = 0;

  /// Every word typed must appear somewhere in the title or group.
  List<Command> get _hits {
    final words = _q.text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return widget.commands;
    return widget.commands.where((c) {
      final hay = '${c.title} ${c.group}'.toLowerCase();
      return words.every(hay.contains);
    }).toList();
  }

  void _run(Command c) {
    Navigator.of(context).pop();
    c.run();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final hits = _hits;
    if (_sel >= hits.length) _sel = hits.isEmpty ? 0 : hits.length - 1;
    return Align(
      alignment: const Alignment(0, -0.45),
      child: Material(
        color: c.panel,
        elevation: 20,
        shadowColor: Colors.black54,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: c.line),
        ),
        child: SizedBox(
          width: 560,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                  setState(() => _sel = (_sel + 1).clamp(0, hits.length - 1)),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                  setState(() => _sel = (_sel - 1).clamp(0, hits.length - 1)),
              const SingleActivator(LogicalKeyboardKey.enter): () {
                if (hits.isNotEmpty) _run(hits[_sel]);
              },
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _q,
                  autofocus: true,
                  onChanged: (_) => setState(() => _sel = 0),
                  style: TextStyle(fontSize: 15, color: c.text),
                  decoration: InputDecoration(
                    hintText: 'Type a command',
                    hintStyle: TextStyle(fontSize: 15, color: c.muted),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                  ),
                ),
                Divider(height: 1, color: c.line),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: hits.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(18),
                          child: Text('No command matches', style: TextStyle(color: c.muted, fontSize: 13)),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          itemCount: hits.length,
                          itemBuilder: (_, i) {
                            final h = hits[i];
                            final on = i == _sel;
                            return InkWell(
                              onTap: () => _run(h),
                              onHover: (v) {
                                if (v) setState(() => _sel = i);
                              },
                              child: Container(
                                color: on ? c.raised : null,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(h.title, style: TextStyle(fontSize: 13.5, color: c.text)),
                                    ),
                                    Text(h.group, style: TextStyle(fontSize: 12, color: c.muted)),
                                    if (h.keys != null) ...[
                                      const SizedBox(width: 10),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                        decoration: BoxDecoration(
                                          border: Border.all(color: c.line),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(h.keys!, style: TextStyle(fontSize: 11, color: c.muted)),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
