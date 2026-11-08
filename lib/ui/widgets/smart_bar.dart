import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/agents.dart';
import '../../core/ai.dart';
import '../../core/ai_agent.dart';
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

class SmartBar extends StatefulWidget {
  final List<LogLine> lines;
  final String projectPath;

  /// Adds to the log below. What a fix or an agent runs goes there, so there
  /// is one log to read rather than a small one inside this bar.
  final void Function(String text, LogLevel level) log;

  /// The command that failed, so a fix can be checked by trying it again.
  final List<String>? retry;
  const SmartBar({super.key, required this.lines, required this.projectPath, required this.log, this.retry});

  @override
  State<SmartBar> createState() => _SmartBarState();
}

class _SmartBarState extends State<SmartBar> {
  String? _answer;
  bool _answerIsFix = false;
  AiAgent? _agent;
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
  Future<SafeFix> _guarded(String title, Future<int?> Function() action, {bool check = false}) {
    final log = widget.log;
    final project = widget.projectPath;
    final retry = widget.retry;
    final failure = Verdict.errorsIn(widget.lines.where((l) => l.level == LogLevel.error).map((l) => l.text));
    return SafeFixes.instance.guard(
      title,
      project,
      action,
      say: (text, bad) => log(text, bad ? LogLevel.warn : LogLevel.system),
      // Deckhand checks an AI's work itself, whatever the AI claims.
      verify: check
          ? (changes) => Verdict.check(
              changes: changes,
              run: (args) => Sdk.instance.run(args, cwd: project, timeout: const Duration(minutes: 5)),
              retry: retry,
              failure: failure,
            )
          : null,
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
    }, check: true);
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

  /// A cloud model will now see project files, not only the log: said once
  /// per provider. A local model keeps everything on this computer.
  Future<bool> _okToShareFiles() async {
    final provider = Ai.instance.provider;
    if (provider == Provider.ollama || provider == Provider.custom) return true;
    final prefs = await SharedPreferences.getInstance();
    final key = 'ai_files_ok_${provider.name}';
    if (prefs.getBool(key) == true) return true;
    if (!mounted) return false;
    final c = C.of(context);
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: c.panel,
            title: Text('Let ${provider.label} read this project?', style: TextStyle(fontSize: 16, color: c.text)),
            content: SizedBox(
              width: 440,
              child: Text(
                'To work out the cause, the AI reads files in this project, and what it reads is sent to ${provider.label}. '
                "It can't read .env files, signing keys or similar, but a password typed into ordinary code or a script would be seen.",
                style: TextStyle(fontSize: 13, height: 1.45, color: c.muted),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Allow')),
            ],
          ),
        ) ??
        false;
    if (ok) await prefs.setBool(key, true);
    return ok;
  }

  Future<String?> _flutterVersion() async {
    final v = await Sdk.instance.version(cwd: widget.projectPath);
    return v == null ? null : '${v['frameworkVersion']} (${v['channel']})';
  }

  /// Runs the AI, showing each thing it does in the log. Null if stopped.
  Future<String?> _runAgent({required bool canEdit, String? earlier}) async {
    final log = widget.log;
    final failure = List<LogLine>.of(widget.lines);
    final agent = AiAgent(widget.projectPath, canEdit: canEdit, onStep: (s) => log('AI $s', LogLevel.system));
    setState(() => _agent = agent);
    try {
      return await agent.run(failure, flutterVersion: await _flutterVersion(), earlier: earlier);
    } on AiStopped {
      return null;
    } finally {
      if (mounted) setState(() => _agent = null);
    }
  }

  /// Reads the project and explains. It can't change anything here.
  Future<void> _ask() async {
    if (!Ai.instance.connected) {
      setState(() => _aiError = 'Connect an AI model in Settings to use this. Your key stays in the keychain.');
      return;
    }
    if (!await _okToShareFiles() || !mounted) return;
    setState(() {
      _asking = true;
      _aiError = null;
      _answer = null;
    });
    try {
      final a = await _runAgent(canEdit: false);
      if (mounted && a != null) {
        setState(() {
          _answer = a;
          _answerIsFix = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _aiError = '$e');
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  /// Lets the AI change files, inside the safety net.
  Future<void> _fixWithAi() async {
    if (!await _okToShareFiles() || !mounted) return;
    final earlier = _answer;
    setState(() {
      _asking = true;
      _aiError = null;
    });
    String? said;
    try {
      final fix = await _guarded('AI fix', () async {
        said = await _runAgent(canEdit: true, earlier: earlier);
        return said == null ? 1 : 0;
      }, check: true);
      // If it was rejected, what the AI claimed no longer means anything.
      if (fix.state == SafeFixState.restored) {
        if (mounted) setState(() => _answer = null);
      } else if (mounted && said != null) {
        setState(() {
          _answer = said;
          _answerIsFix = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _aiError = '$e');
    } finally {
      if (mounted) setState(() => _asking = false);
    }
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
                    onPressed: busy || _asking ? null : () => _fixWithAgent(agent),
                    icon: const Icon(Icons.terminal_rounded, size: 15),
                    label: Text((run?.running ?? false) ? '${agent.name} is working…' : 'Fix with ${agent.name}'),
                  ),
                ],
                const SizedBox(width: 6),
                OutlinedButton.icon(
                  onPressed: _asking || busy ? null : _ask,
                  // A still icon on purpose: a local model can take minutes, and
                  // a spinner would redraw the whole window all that time.
                  icon: Icon(_asking ? Icons.hourglass_empty_rounded : Icons.auto_awesome_outlined, size: 15),
                  label: Text(_asking ? 'Reading…' : 'Ask AI'),
                ),
                if (_agent != null)
                  TextButton(
                    onPressed: _agent!.stop,
                    child: Text('Stop', style: TextStyle(color: c.bad)),
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
      SafeFixState.restored => (
        Icons.shield_outlined,
        c.warn,
        f.broke != null
            ? 'That broke ${f.broke}. Your files are back as they were.'
            : "It didn't work: ${f.failedCheck}. Your files are back as they were.",
      ),
      SafeFixState.undone => (Icons.undo_rounded, c.muted, 'Undone. Your files are back as they were.'),
      SafeFixState.kept when f.error != null => (Icons.error_outline_rounded, c.bad, f.error!),
      SafeFixState.kept when files.isEmpty => (Icons.info_outline_rounded, c.muted, 'It changed no files.'),
      SafeFixState.kept when f.addedErrors > 0 => (
        Icons.warning_amber_rounded,
        c.warn,
        'Changed $names, but the analyzer now finds ${f.addedErrors} more errors.',
      ),
      SafeFixState.kept when f.note != null => (Icons.warning_amber_rounded, c.warn, 'Changed $names. ${f.note}'),
      SafeFixState.kept => (Icons.check_circle_outline_rounded, c.good, 'Changed $names, and checked it works.'),
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
  Widget _answerView(C c, String a) {
    final lines = a.trim().split('\n');
    final rest = lines.skip(1).join('\n').trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.auto_awesome_outlined, size: 14, color: c.accent),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SelectableText(
                  lines.first,
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
          if (rest.isNotEmpty) ...[
            const SizedBox(height: 4),
            SelectableText(rest, style: TextStyle(fontSize: 12.5, height: 1.45, color: c.muted)),
          ],
          if (!_answerIsFix) ...[
            const SizedBox(height: 10),
            FilledButton(onPressed: _asking || _protecting ? null : _fixWithAi, child: const Text('Let AI fix it')),
          ],
          const SizedBox(height: 6),
          Text(
            _answerIsFix ? 'AI can be wrong. Undo is above if this looks off.' : "AI can be wrong. Nothing has changed yet.",
            style: TextStyle(fontSize: 11, color: c.muted.withValues(alpha: 0.7)),
          ),
        ],
      ),
    );
  }
}
