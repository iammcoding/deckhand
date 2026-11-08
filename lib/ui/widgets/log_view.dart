import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/sessions.dart';
import '../theme.dart';

/// A log: monospaced, coloured by level, filter and search, follows the end
/// unless you scroll up, copy all.
class LogView extends StatefulWidget {
  final List<LogLine> lines;
  const LogView({super.key, required this.lines});

  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  bool _follow = true;
  bool _errorsOnly = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final atEnd = _scroll.position.pixels >= _scroll.position.maxScrollExtent - 40;
      if (atEnd != _follow) setState(() => _follow = atEnd);
    });
  }

  @override
  void didUpdateWidget(LogView old) {
    super.didUpdateWidget(old);
    if (_follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  Color _color(C c, LogLevel l) => switch (l) {
    LogLevel.error => c.bad,
    LogLevel.warn => c.warn,
    LogLevel.progress => c.muted,
    LogLevel.system => c.accent,
    LogLevel.info => c.text,
  };

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final q = _search.text.trim().toLowerCase();
    final shown = widget.lines
        .where((l) => !_errorsOnly || l.level == LogLevel.error || l.level == LogLevel.warn)
        .where((l) => q.isEmpty || l.text.toLowerCase().contains(q))
        .toList();
    final errors = widget.lines.where((l) => l.level == LogLevel.error).length;
    return Container(
      decoration: BoxDecoration(
        color: c.panel,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        children: [
          Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    style: TextStyle(fontSize: 12.5, color: c.text),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 16, color: c.muted),
                      prefixIconConstraints: const BoxConstraints(minWidth: 28),
                      hintText: 'Search the log',
                      hintStyle: TextStyle(fontSize: 12.5, color: c.muted),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                FilterChip(
                  label: Text('Errors & warnings${errors > 0 ? ' · $errors' : ''}', style: const TextStyle(fontSize: 12)),
                  selected: _errorsOnly,
                  onSelected: (v) => setState(() => _errorsOnly = v),
                  visualDensity: VisualDensity.compact,
                  showCheckmark: false,
                ),
                const Spacer(),
                Text('${shown.length} lines', style: TextStyle(fontSize: 12, color: c.muted)),
                IconButton(
                  tooltip: 'Copy log',
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: shown.map((l) => l.text).join('\n')));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Log copied'), duration: Duration(seconds: 1)));
                  },
                ),
                if (!_follow)
                  TextButton.icon(
                    onPressed: () {
                      setState(() => _follow = true);
                      _scroll.jumpTo(_scroll.position.maxScrollExtent);
                    },
                    icon: const Icon(Icons.arrow_downward_rounded, size: 15),
                    label: const Text('Latest', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Text('Nothing yet', style: TextStyle(color: c.muted, fontSize: 13)),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final l = shown[i];
                        final t = l.at;
                        final hh = t.hour.toString().padLeft(2, '0');
                        final mm = t.minute.toString().padLeft(2, '0');
                        final ss = t.second.toString().padLeft(2, '0');
                        final mark = l.level == LogLevel.error || l.level == LogLevel.warn;
                        return Container(
                          // Errors and warnings get a tinted row and a bar, so
                          // they stand out in a long log.
                          color: l.level == LogLevel.error
                              ? c.bad.withValues(alpha: 0.07)
                              : l.level == LogLevel.warn
                              ? c.warn.withValues(alpha: 0.06)
                              : null,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(width: 2, height: 18, color: mark ? _color(c, l.level) : Colors.transparent),
                              const SizedBox(width: 8),
                              Text('$hh:$mm:$ss', style: mono.copyWith(fontSize: 11.5, color: c.muted.withValues(alpha: 0.55))),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(l.text, style: mono.copyWith(color: _color(c, l.level))),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
