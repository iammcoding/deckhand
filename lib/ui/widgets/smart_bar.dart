import 'package:flutter/material.dart';

import '../../core/agents.dart';
import '../../core/ai.dart';
import '../../core/fixes.dart';
import '../../core/safe_fix.dart';
import '../../core/sdk.dart';
import '../../core/sessions.dart';
import '../../core/shell.dart';
import '../theme.dart';

/// Above a log: a problem Deckhand recognises, with a Fix button, or Ask AI
/// for anything else. What either runs is shown first and runs only on a
/// click, and its output goes to the log below.
/// Asks, naming the files, then puts them back. Asked because you may have
/// kept working in those files since.
Future<void> confirmUndo(BuildContext context, SafeFix f) async {
  final c = C.of(context);
  final lost = f.changes.cannotRestore;
  final ok =
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: c.panel,
          title: Text(
            'Undo "${f.title}"?',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 16, color: c.text),
          ),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'These go back to how they were before it ran, including anything you changed in them since:',
                  style: TextStyle(fontSize: 13, height: 1.4, color: c.muted),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: SingleChildScrollView(
                    child: SelectableText(f.changes.all.join('\n'), style: mono.copyWith(fontSize: 12, color: c.text)),
                  ),
                ),
                if (lost.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    "Too big to have been saved, so these stay as they are: ${lost.join(', ')}",
                    style: TextStyle(fontSize: 12.5, color: c.warn),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Undo')),
          ],
        ),
      ) ??
      false;
  if (ok) SafeFixes.instance.undo(f);
}

/// True when a shell command writes to a file by itself.
bool writesFile(String command) => RegExp(r'>|\bsed\s+-i|\btee\b|\bperl\s+-[a-z]*i').hasMatch(command);

class SmartBar extends StatefulWidget {
  final List<LogLine> lines;
  final String projectPath;

  /// Adds to the log below. What a fix or an agent runs goes there, so there
  /// is one log to read rather than a small one inside this bar.
  final void Function(String text, LogLevel level) log;
  const SmartBar({super.key, required this.lines, required this.projectPath, required this.log});

  @override
  State<SmartBar> createState() => _SmartBarState();
}

class _SmartBarState extends State<SmartBar> {
  AiAnswer? _answer;
  String? _aiError;
  bool _asking = false;
  final List<ShellJob> _runs = [];
  String? _editMsg;
  int _seenErrors = 0;
  AgentRun? _agentRun;

  @override
  void initState() {
    super.initState();
    SafeFixes.instance.addListener(_safeChanged);
  }

  @override
  void dispose() {
    SafeFixes.instance.removeListener(_safeChanged);
    super.dispose();
  }

  void _safeChanged() {
    if (mounted) setState(() {});
  }

  /// A fix is running: nothing else may start, or the two would be mixed up
  /// in one undo.
  bool get _protecting => SafeFixes.instance.latest(widget.projectPath)?.state == SafeFixState.running;

  /// Everything that changes the project goes through here.
  Future<void> _guarded(String title, Future<int?> Function() action) async {
    final log = widget.log;
    await SafeFixes.instance.guard(
      title,
      widget.projectPath,
      action,
      say: (text, bad) => log(text, bad ? LogLevel.warn : LogLevel.system),
    );
  }

  Future<void> _fixWithAgent(Agent a) async {
    final c = C.of(context);
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: c.panel,
            title: Text('Let ${a.name} fix it?', style: TextStyle(fontSize: 16, color: c.text)),
            content: SizedBox(
              width: 440,
              child: Text(
                '${a.name} gets the end of this log and edits files in ${widget.projectPath} to fix it. '
                'You see everything it does here. A copy of the project is saved first, so you can undo it.',
                style: TextStyle(fontSize: 13, height: 1.4, color: c.muted),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Fix with ${a.name}')),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) return;
    final run = AgentRun(a, widget.projectPath);
    _follow(run, run.log);
    setState(() => _agentRun = run);
    final failure = List<LogLine>.of(widget.lines);
    await _guarded('Fix with ${a.name}', () async {
      await run.start(failure);
      return run.exitCode;
    });
  }

  /// Sends what [source] prints to the log, even after this bar has gone: a
  /// command keeps running if you switch tabs.
  void _follow(Listenable source, List<LogLine> lines) {
    final log = widget.log;
    var sent = 0;
    void send() {
      while (sent < lines.length) {
        final l = lines[sent++];
        log(l.text, l.level);
      }
      if (mounted) setState(() {});
    }

    source.addListener(send);
    send();
  }

  int get _errors => widget.lines.where((l) => l.level == LogLevel.error).length;

  @override
  void didUpdateWidget(SmartBar old) {
    super.didUpdateWidget(old);
    // A fresh run: yesterday's answer no longer applies.
    if (widget.lines.isEmpty || _errors < _seenErrors) {
      _answer = null;
      _aiError = null;
      _runs.clear();
      _editMsg = null;
      if (!(_agentRun?.running ?? false)) _agentRun = null;
    }
    _seenErrors = _errors;
  }

  Future<void> _runCommand(String command) async {
    final job = ShellJob(command, cwd: widget.projectPath);
    setState(() => _runs.add(job));
    _follow(job, job.log);
    await _guarded(command, job.start);
  }

  Future<void> _applyFix(Fix f) async {
    await _guarded(f.title, () async {
      for (final s in f.steps) {
        if (s.edit != null) {
          final err = await s.edit!();
          if (mounted) setState(() => _editMsg = err ?? '${s.label}: done');
          if (err != null) return 1;
        } else if (s.command != null) {
          final job = ShellJob(s.command!, cwd: widget.projectPath);
          if (mounted) setState(() => _runs.add(job));
          _follow(job, job.log);
          final code = await job.start();
          if (code != 0) return code;
        }
      }
      return 0;
    });
  }

  Future<void> _ask() async {
    if (!Ai.instance.connected) {
      setState(() => _aiError = 'Connect an AI model in Settings to use this. Your key stays in the keychain.');
      return;
    }
    setState(() {
      _asking = true;
      _aiError = null;
      _answer = null;
    });
    try {
      final v = await Sdk.instance.version(cwd: widget.projectPath);
      final a = await Ai.instance.explain(
        log: widget.lines,
        projectPath: widget.projectPath,
        flutterVersion: v == null ? null : '${v['frameworkVersion']} (${v['channel']})',
      );
      if (mounted) setState(() => _answer = a);
    } catch (e) {
      if (mounted) setState(() => _aiError = '$e');
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  Future<bool> _confirm(String command) async {
    final c = C.of(context);
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: c.panel,
            title: Text('Run this?', style: TextStyle(fontSize: 16, color: c.text)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (writesFile(command))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_rounded, size: 16, color: c.warn),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'This command changes a file. AI often gets that wrong, so check it first, or make the change yourself.',
                            style: TextStyle(fontSize: 12.5, height: 1.4, color: c.warn),
                          ),
                        ),
                      ],
                    ),
                  ),
                Text('In ${widget.projectPath}', style: TextStyle(fontSize: 12, color: c.muted)),
                const SizedBox(height: 4),
                Text(
                  'A copy of the project is saved first, so you can undo this. Anything it changes outside the project can\'t be undone.',
                  style: TextStyle(fontSize: 12, height: 1.4, color: c.muted),
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.bg,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: c.line),
                  ),
                  child: SelectableText(command, style: mono.copyWith(color: c.text)),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Run')),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final fix = Fixes.find(widget.lines, widget.projectPath);
    final errors = _errors;
    final safe = SafeFixes.instance.latest(widget.projectPath);
    if (fix == null && errors == 0 && _answer == null && _runs.isEmpty && _agentRun == null && safe == null) {
      return const SizedBox.shrink();
    }
    final agent = Agents.instance.current;
    final run = _agentRun;
    final busy = _runs.any((r) => r.running) || _protecting;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: (fix != null ? c.warn : c.bad).withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    fix != null ? Icons.build_circle_outlined : Icons.error_outline_rounded,
                    size: 17,
                    color: fix != null ? c.warn : c.bad,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fix?.title ?? '$errors ${errors == 1 ? 'error' : 'errors'} in this log',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        fix?.detail ??
                            (Ai.instance.connected
                                ? 'Ask the AI to read the log and suggest a fix.'
                                : 'Connect an AI model in Settings and it can read the log and suggest a fix.'),
                        style: TextStyle(fontSize: 12.5, color: c.muted),
                      ),
                      if (fix != null) ...[
                        const SizedBox(height: 6),
                        for (final s in fix.steps)
                          Text(
                            s.command != null ? '› ${s.command}' : '› ${s.label}',
                            style: mono.copyWith(fontSize: 11.5, color: c.muted),
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                if (fix != null)
                  FilledButton(
                    onPressed: busy ? null : () => _applyFix(fix),
                    child: Text(fix.steps.length == 1 ? fix.steps.first.label : 'Fix'),
                  ),
                if (agent != null) ...[
                  const SizedBox(width: 6),
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => _fixWithAgent(agent),
                    icon: const Icon(Icons.terminal_rounded, size: 15),
                    label: Text((run?.running ?? false) ? '${agent.name} is working…' : 'Fix with ${agent.name}'),
                  ),
                ],
                const SizedBox(width: 6),
                OutlinedButton.icon(
                  onPressed: _asking ? null : _ask,
                  // A still icon on purpose: a local model can take minutes, and
                  // a spinner would redraw the whole window all that time.
                  icon: Icon(_asking ? Icons.hourglass_empty_rounded : Icons.auto_awesome_outlined, size: 15),
                  label: Text(_asking ? 'Reading…' : 'Ask AI'),
                ),
              ],
            ),
          ),
          if (_editMsg != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(39, 0, 12, 8),
              child: Text(_editMsg!, style: TextStyle(fontSize: 12, color: c.text)),
            ),
          if (_aiError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(39, 0, 12, 10),
              child: Text(_aiError!, style: TextStyle(fontSize: 12.5, color: c.bad)),
            ),
          if (safe != null) _outcome(c, safe),
          if (_answer != null) _answerView(c, _answer!),
          if (run != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!run.running && run.git && run.changed.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              run.changed.take(4).join(', ') + (run.changed.length > 4 ? ' +${run.changed.length - 4}' : ''),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: mono.copyWith(fontSize: 11.5, color: c.muted),
                            ),
                          ),
                          TextButton(onPressed: run.showDiff, child: const Text('Show changes')),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// How the last fix turned out, with Undo while it can still be undone.
  Widget _outcome(C c, SafeFix f) {
    final files = f.changes.all;
    final names = files.take(3).join(', ') + (files.length > 3 ? ' +${files.length - 3} more' : '');
    final (IconData icon, Color color, String text) = switch (f.state) {
      SafeFixState.running => (Icons.shield_outlined, c.muted, 'Project saved. Working…'),
      SafeFixState.unprotected => (Icons.block_rounded, c.bad, f.error ?? ''),
      SafeFixState.restored => (Icons.shield_outlined, c.warn, 'That broke ${f.broke}. Your files are back as they were.'),
      SafeFixState.undone => (Icons.undo_rounded, c.muted, 'Undone. Your files are back as they were.'),
      SafeFixState.kept when f.error != null => (Icons.error_outline_rounded, c.bad, f.error!),
      SafeFixState.kept when files.isEmpty => (Icons.info_outline_rounded, c.muted, 'It changed no files.'),
      SafeFixState.kept when f.addedErrors > 0 => (
        Icons.warning_amber_rounded,
        c.warn,
        'Changed $names, but the analyzer now finds ${f.addedErrors} more errors.',
      ),
      SafeFixState.kept => (Icons.check_circle_outline_rounded, c.good, 'Changed $names'),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: c.text),
            ),
          ),
          if (f.canUndo) TextButton(onPressed: () => confirmUndo(context, f), child: const Text('Undo')),
          if (f.state != SafeFixState.running)
            IconButton(
              tooltip: 'Close',
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              onPressed: () => SafeFixes.instance.dismiss(widget.projectPath),
              icon: const Icon(Icons.close_rounded),
            ),
        ],
      ),
    );
  }

  /// The answer, as plain text in the bar: a dark box here read as a second
  /// terminal.
  Widget _answerView(C c, AiAnswer a) => Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: c.line)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.auto_awesome_outlined, size: 14, color: c.accent),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                a.summary,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text),
              ),
            ),
            IconButton(
              tooltip: 'Close',
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _answer = null),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SelectableText(a.cause, style: TextStyle(fontSize: 12.5, height: 1.45, color: c.muted)),
        for (final s in a.steps) ...[
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.title,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.text),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(s.command, style: mono.copyWith(fontSize: 12, color: c.text)),
                    Text(s.why, style: TextStyle(fontSize: 11.5, color: c.muted)),
                  ],
                ),
              ),
              OutlinedButton(
                onPressed: _protecting
                    ? null
                    : () async {
                        if (await _confirm(s.command)) _runCommand(s.command);
                      },
                child: const Text('Run'),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'AI can be wrong. Check a command before you run it.',
          style: TextStyle(fontSize: 11, color: c.muted.withValues(alpha: 0.7)),
        ),
      ],
    ),
  );
}
