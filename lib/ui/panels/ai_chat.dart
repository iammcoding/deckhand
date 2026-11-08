import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/ai.dart';
import '../../core/bench.dart';
import '../../core/jobs.dart';
import '../../core/problems.dart';
import '../../core/projects.dart';
import '../../core/sessions.dart';
import '../theme.dart';

class _Msg {
  final bool user;
  String text;
  String? error;
  _Msg(this.user, this.text);
}

/// A chat with the connected model, beside the code. It sees what you choose
/// to share: the file in front, the latest log, the analyzer's problems.
class AiChat extends StatefulWidget {
  const AiChat({super.key});

  @override
  State<AiChat> createState() => _AiChatState();
}

class _AiChatState extends State<AiChat> {
  // Kept while the app is open, so hiding the panel doesn't lose the chat.
  static final List<_Msg> _msgs = [];
  static bool _withFile = true, _withLog = true, _withProblems = true;

  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  StreamSubscription<String>? _sub;

  bool get _busy => _sub != null;

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  String? get _openFile {
    final t = Bench.instance.current;
    return t?.kind == TabKind.file ? t!.path : null;
  }

  /// The log most worth sharing: the one in front in the bottom panel, or
  /// whichever has errors.
  ({String name, List<LogLine> lines})? get _log {
    final run = currentRun.value, build = currentBuild.value, task = currentTask.value;
    final all = [
      if (run != null) (name: 'Run log', lines: run.log, tab: BottomTab.run),
      if (build != null) (name: 'Build log', lines: build.log, tab: BottomTab.build),
      if (task != null) (name: '${task.title} log', lines: task.log, tab: BottomTab.tasks),
    ];
    if (all.isEmpty) return null;
    final front = all.where((x) => x.tab == Bench.instance.bottom).firstOrNull;
    final failing = all.where((x) => x.lines.any((l) => l.level == LogLevel.error)).firstOrNull;
    final pick = front ?? failing ?? all.first;
    return (name: pick.name, lines: pick.lines);
  }

  Future<String> _system() async {
    final pr = Projects.instance.current;
    final b = StringBuffer('''
You are the assistant inside Deckhand, a desktop app for Flutter development. The developer is working on the project below.
Answer briefly and specifically, for a developer. Use fenced code blocks with a language tag for code and shell commands.
You can't run commands or edit files yourself: say exactly what to change and where (file and line), or which command to run.
OS: ${Platform.operatingSystem}.
''');
    if (pr != null) {
      b.writeln('\nProject: ${pr.name} ${pr.version} at ${pr.path}');
      try {
        b.writeln('\npubspec.yaml:\n${await File(p.join(pr.path, 'pubspec.yaml')).readAsString()}');
      } catch (_) {}
    }
    final f = _openFile;
    if (_withFile && f != null) {
      try {
        var text = await File(f).readAsString();
        if (text.length > 60000) text = '${text.substring(0, 60000)}\n… (cut)';
        final rel = pr != null && p.isWithin(pr.path, f) ? p.relative(f, from: pr.path) : f;
        b.writeln('\nThe file open in the editor, $rel:\n```\n$text\n```');
      } catch (_) {}
    }
    final log = _log;
    if (_withLog && log != null && log.lines.isNotEmpty) {
      final tail = log.lines.length > 120 ? log.lines.sublist(log.lines.length - 120) : log.lines;
      b.writeln('\n${log.name} (last ${tail.length} lines):\n```\n${tail.map((l) => l.text).join('\n')}\n```');
    }
    final pb = Problems.instance;
    if (_withProblems && pb.list.isNotEmpty) {
      final top = pb.list.where((x) => x.severity != 'INFO').take(40).toList();
      if (top.isNotEmpty) {
        b.writeln('\nAnalyzer problems:');
        for (final x in top) {
          final rel = pr != null && p.isWithin(pr.path, x.file) ? p.relative(x.file, from: pr.path) : x.file;
          b.writeln('${x.severity} $rel:${x.line}:${x.column} ${x.message} (${x.code})');
        }
      }
    }
    return b.toString();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    if (!Ai.instance.connected) {
      Bench.instance.open(const EditorTab(TabKind.settings));
      return;
    }
    _input.clear();
    final reply = _Msg(false, '');
    setState(() {
      _msgs.add(_Msg(true, text));
      _msgs.add(reply);
    });
    _toEnd();
    final system = await _system();
    final history = [
      for (final m in _msgs)
        if (m != reply && m.error == null && m.text.isNotEmpty) (user: m.user, text: m.text),
    ];
    final sub = Ai.instance
        .chat(system: system, messages: history)
        .listen(
          (t) {
            if (!mounted) return;
            setState(() => reply.text += t);
            _toEnd();
          },
          onError: (Object e) {
            if (mounted) setState(() => reply.error = '$e');
          },
          onDone: () {
            if (mounted) setState(() => _sub = null);
          },
        );
    setState(() => _sub = sub);
  }

  void _stop() {
    _sub?.cancel();
    setState(() => _sub = null);
  }

  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final ai = Ai.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([Bench.instance, currentRun, currentBuild, currentTask, Problems.instance]),
      builder: (context, _) {
        final file = _openFile;
        final log = _log;
        final pb = Problems.instance;
        final issues = pb.errors + pb.warnings;
        return Container(
          color: c.panel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 34,
                padding: const EdgeInsets.only(left: 12, right: 4),
                child: Row(
                  children: [
                    Text(
                      'CHAT',
                      style: TextStyle(fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: c.muted),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        ai.connected ? ai.model : 'not connected',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: c.muted),
                      ),
                    ),
                    IconButton(
                      tooltip: 'New chat',
                      iconSize: 15,
                      visualDensity: VisualDensity.compact,
                      onPressed: _busy || _msgs.isEmpty ? null : () => setState(_msgs.clear),
                      icon: const Icon(Icons.add_comment_outlined),
                    ),
                    IconButton(
                      tooltip: 'Hide chat  ⌘L',
                      iconSize: 15,
                      visualDensity: VisualDensity.compact,
                      onPressed: Bench.instance.toggleAi,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: !ai.connected
                    ? _connect(c)
                    : _msgs.isEmpty
                    ? _hello(c)
                    : SelectionArea(
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                          itemCount: _msgs.length,
                          itemBuilder: (_, i) => _message(c, _msgs[i], last: i == _msgs.length - 1),
                        ),
                      ),
              ),
              // What the model will see with the next message.
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (file != null)
                      _chip(c, p.basename(file), Icons.description_outlined, _withFile, (v) => setState(() => _withFile = v)),
                    if (log != null) _chip(c, log.name, Icons.notes_rounded, _withLog, (v) => setState(() => _withLog = v)),
                    if (issues > 0)
                      _chip(c, '$issues problems', Icons.rule_rounded, _withProblems, (v) => setState(() => _withProblems = v)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Container(
                  decoration: BoxDecoration(
                    color: c.bg,
                    border: Border.all(color: c.line),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: CallbackShortcuts(
                          bindings: {const SingleActivator(LogicalKeyboardKey.enter): _send},
                          child: TextField(
                            controller: _input,
                            focusNode: _focus,
                            minLines: 1,
                            maxLines: 8,
                            enabled: ai.connected,
                            style: TextStyle(fontSize: 13, color: c.text),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: 'Ask about this project  (⇧↩ new line)',
                              hintStyle: TextStyle(fontSize: 13, color: c.muted),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: _busy ? 'Stop' : 'Send',
                        iconSize: 17,
                        onPressed: !ai.connected ? null : (_busy ? _stop : _send),
                        icon: Icon(_busy ? Icons.stop_rounded : Icons.arrow_upward_rounded, color: _busy ? c.bad : c.accent),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _connect(C c) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Connect a model to chat about your code: Claude, OpenAI, Gemini, OpenRouter, or a local one with Ollama.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, height: 1.45, color: c.muted),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => Bench.instance.open(const EditorTab(TabKind.settings)),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    ),
  );

  Widget _hello(C c) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Ask about the open file, a failing build, or how to do something in Flutter.',
          style: TextStyle(fontSize: 12.5, height: 1.45, color: c.muted),
        ),
        const SizedBox(height: 12),
        for (final q in const [
          'Why is this build failing?',
          'Explain the file I have open',
          'How do I fix the analyzer problems?',
        ])
          InkWell(
            onTap: () {
              _input.text = q;
              _send();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Text(q, style: TextStyle(fontSize: 12.5, color: c.accent)),
            ),
          ),
      ],
    ),
  );

  Widget _chip(C c, String label, IconData icon, bool on, ValueChanged<bool> set) => InkWell(
    borderRadius: BorderRadius.circular(4),
    onTap: () => set(!on),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: on ? c.accent.withValues(alpha: 0.6) : c.line),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: on ? c.accent : c.muted),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(fontSize: 11.5, color: on ? c.text : c.muted, decoration: on ? null : TextDecoration.lineThrough),
          ),
        ],
      ),
    ),
  );

  Widget _message(C c, _Msg m, {required bool last}) {
    if (m.user) {
      return Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(6)),
        child: Text(m.text, style: TextStyle(fontSize: 13, height: 1.45, color: c.text)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.text.isEmpty && m.error == null && last && _busy)
            Text('Thinking…', style: TextStyle(fontSize: 12.5, color: c.muted)),
          ..._render(c, m.text),
          if (m.error != null) Text(m.error!, style: TextStyle(fontSize: 12.5, color: c.bad)),
        ],
      ),
    );
  }

  /// Just enough Markdown: code fences, inline code, bold, bullets.
  List<Widget> _render(C c, String text) {
    final out = <Widget>[];
    final parts = text.split('```');
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (i.isOdd) {
        // A code block; the first line is the language.
        final nl = part.indexOf('\n');
        final lang = nl < 0 ? '' : part.substring(0, nl).trim();
        final code = (nl < 0 ? part : part.substring(nl + 1)).replaceAll(RegExp(r'\n$'), '');
        out.add(_CodeBlock(lang: lang, code: code));
      } else {
        for (final para in part.trim().split(RegExp(r'\n{2,}'))) {
          if (para.trim().isEmpty) continue;
          out.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text.rich(
                TextSpan(children: _inline(c, para)),
                style: TextStyle(fontSize: 13, height: 1.5, color: c.text),
              ),
            ),
          );
        }
      }
    }
    return out;
  }

  List<InlineSpan> _inline(C c, String s) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'`([^`]+)`|\*\*([^*]+)\*\*');
    var at = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > at) spans.add(TextSpan(text: _bullets(s.substring(at, m.start))));
      if (m.group(1) != null) {
        spans.add(
          TextSpan(
            text: m.group(1),
            style: mono.copyWith(fontSize: 12, color: c.text, backgroundColor: c.raised),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: m.group(2),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      }
      at = m.end;
    }
    if (at < s.length) spans.add(TextSpan(text: _bullets(s.substring(at))));
    return spans;
  }

  String _bullets(String s) => s.replaceAllMapped(RegExp(r'(^|\n)\s*[-*] '), (m) => '${m.group(1)}•  ');
}

class _CodeBlock extends StatelessWidget {
  final String lang;
  final String code;
  const _CodeBlock({required this.lang, required this.code});

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 26,
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(lang, style: TextStyle(fontSize: 11, color: c.muted)),
                ),
                SelectionContainer.disabled(
                  child: TextButton(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: c.muted),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: code));
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)));
                    },
                    child: const Text('Copy', style: TextStyle(fontSize: 11.5)),
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(10),
            child: Text(code, style: mono.copyWith(fontSize: 12, color: c.text)),
          ),
        ],
      ),
    );
  }
}
