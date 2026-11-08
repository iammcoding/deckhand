import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'sdk.dart';
import 'sessions.dart';

/// A coding agent on this computer that can fix code by itself. Deckhand
/// hands it the error; it edits the files.
class Agent {
  final String id;
  final String name;
  final String bin; // the command
  final String defaultTemplate; // {prompt} is one argument
  final bool openSource;
  final String site;
  const Agent(this.id, this.name, this.bin, this.defaultTemplate, {this.openSource = false, required this.site});
}

const agents = <Agent>[
  Agent('opencode', 'opencode', 'opencode', 'opencode run {prompt}', openSource: true, site: 'opencode.ai'),
  Agent(
    'aider',
    'Aider',
    'aider',
    'aider --yes-always --no-auto-commits --message {prompt}',
    openSource: true,
    site: 'aider.chat',
  ),
  Agent('claude', 'Claude Code', 'claude', 'claude -p {prompt} --permission-mode acceptEdits', site: 'claude.com/claude-code'),
  Agent(
    'gemini',
    'Gemini CLI',
    'gemini',
    'gemini --approval-mode auto_edit -p {prompt}',
    openSource: true,
    site: 'github.com/google-gemini/gemini-cli',
  ),
  Agent('codex', 'Codex CLI', 'codex', 'codex exec --full-auto {prompt}', openSource: true, site: 'github.com/openai/codex'),
];

/// Which agents are installed, which one to use, and the command for each.
class Agents extends ChangeNotifier {
  Agents._();
  static final Agents instance = Agents._();

  final Map<String, String> found = {}; // id → path
  String? chosen;
  final Map<String, String> templates = {};

  Agent? get current => agents.where((a) => a.id == chosen && found.containsKey(a.id)).firstOrNull;
  String template(Agent a) => templates[a.id] ?? a.defaultTemplate;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    chosen = prefs.getString('agent');
    for (final a in agents) {
      final t = prefs.getString('agent_tpl_${a.id}');
      if (t != null) templates[a.id] = t;
    }
    await detect();
  }

  Future<void> detect() async {
    found.clear();
    for (final a in agents) {
      try {
        final r = Platform.isWindows
            ? await Process.run('where', [a.bin], environment: Sdk.instance.env, runInShell: true)
            : await Process.run('which', [a.bin], environment: Sdk.instance.env);
        final path = '${r.stdout}'.split(RegExp(r'\r?\n')).first.trim();
        if (r.exitCode == 0 && path.isNotEmpty) found[a.id] = path;
      } catch (_) {}
    }
    if (chosen == null || !found.containsKey(chosen)) chosen = agents.where((a) => found.containsKey(a.id)).firstOrNull?.id;
    notifyListeners();
  }

  Future<void> choose(String id) async {
    chosen = id;
    (await SharedPreferences.getInstance()).setString('agent', id);
    notifyListeners();
  }

  Future<void> setTemplate(Agent a, String t) async {
    final prefs = await SharedPreferences.getInstance();
    if (t.trim().isEmpty || t.trim() == a.defaultTemplate) {
      templates.remove(a.id);
      await prefs.remove('agent_tpl_${a.id}');
    } else {
      templates[a.id] = t.trim();
      await prefs.setString('agent_tpl_${a.id}', t.trim());
    }
    notifyListeners();
  }
}

/// One agent run on a failure: its live output, then what it changed, with
/// an undo for the files it touched that were clean before.
class AgentRun extends ChangeNotifier {
  final Agent agent;
  final String projectPath;
  final List<LogLine> log = [];
  Process? _p;
  int? exitCode;
  bool git = false;
  Set<String> _dirtyBefore = {};
  List<String> changed = [];
  bool undone = false;

  AgentRun(this.agent, this.projectPath);

  bool get running => _p != null && exitCode == null;

  void _add(String t, [LogLevel l = LogLevel.info]) {
    log.add(LogLine(t, l));
    notifyListeners();
  }

  Future<Set<String>> _dirty() async {
    final r = await Process.run(
      'git',
      ['status', '--porcelain', '-uall'],
      workingDirectory: projectPath,
      environment: Sdk.instance.env,
    );
    if (r.exitCode != 0) return {};
    return {
      for (final l in const LineSplitter().convert('${r.stdout}'))
        if (l.length > 3) l.substring(3).trim(),
    };
  }

  static String prompt(List<LogLine> log) {
    final tail = log.length > 120 ? log.sublist(log.length - 120) : log;
    return '''
This Flutter project fails with the log below. Find the cause and fix it with the smallest change that works.
Change only what the fix needs; don't reformat or touch unrelated files. Don't run long builds or start the app.
When you're done, say in one or two sentences what you changed.

Log:
${tail.map((l) => l.text).join('\n')}''';
  }

  Future<void> start(List<LogLine> failure) async {
    final path = Agents.instance.found[agent.id];
    if (path == null) {
      _add('${agent.name} was not found.', LogLevel.error);
      return;
    }
    final r = await Process.run(
      'git',
      ['rev-parse', '--is-inside-work-tree'],
      workingDirectory: projectPath,
      environment: Sdk.instance.env,
    );
    git = r.exitCode == 0 && '${r.stdout}'.trim() == 'true';
    if (git) _dirtyBefore = await _dirty();

    // The template's words, with the prompt as one argument (never through a
    // shell, so nothing in the log can run as a command).
    final words = Agents.instance.template(agent).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final args = [for (final w in words.skip(1)) w == '{prompt}' ? prompt(failure) : w];
    _add('\$ ${words.join(' ')}', LogLevel.system);
    try {
      final proc = await Process.start(path, args, workingDirectory: projectPath, environment: Sdk.instance.envFor(projectPath));
      _p = proc;
      notifyListeners();
      proc.stdin.close();
      proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => _add(l, Job.guess(l)));
      proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => _add(l, LogLevel.warn));
      exitCode = await proc.exitCode;
    } catch (e) {
      _add('$e', LogLevel.error);
      exitCode = -1;
    }
    if (git) {
      final after = await _dirty();
      changed = after.difference(_dirtyBefore).toList()..sort();
    }
    _add(
      exitCode == 0
          ? (git
                ? (changed.isEmpty
                      ? 'Finished. No files changed.'
                      : 'Finished. Changed ${changed.length} file${changed.length == 1 ? '' : 's'}.')
                : 'Finished.')
          : '${agent.name} stopped with code $exitCode.',
      exitCode == 0 ? LogLevel.system : LogLevel.error,
    );
  }

  void cancel() => _p?.kill();

  /// The diff of what it changed, into the log.
  Future<void> showDiff() async {
    if (!git || changed.isEmpty) return;
    final r = await Process.run('git', ['diff', '--', ...changed], workingDirectory: projectPath, environment: Sdk.instance.env);
    for (final l in const LineSplitter().convert('${r.stdout}')) {
      _add(
        l,
        l.startsWith('+') && !l.startsWith('+++')
            ? LogLevel.system
            : l.startsWith('-') && !l.startsWith('---')
            ? LogLevel.error
            : LogLevel.info,
      );
    }
    final untracked = changed.where((f) => !'${r.stdout}'.contains(f)).toList();
    for (final f in untracked) {
      _add('new file: $f', LogLevel.system);
    }
  }

  /// Puts back only the files the agent changed (they were clean before).
  Future<void> undo() async {
    if (!git || changed.isEmpty || undone) return;
    final tracked = await Process.run(
      'git',
      ['ls-files', '--', ...changed],
      workingDirectory: projectPath,
      environment: Sdk.instance.env,
    );
    final trackedSet = const LineSplitter().convert('${tracked.stdout}').toSet();
    final restore = changed.where(trackedSet.contains).toList();
    if (restore.isNotEmpty) {
      await Process.run('git', ['checkout', '--', ...restore], workingDirectory: projectPath, environment: Sdk.instance.env);
    }
    for (final f in changed.where((f) => !trackedSet.contains(f))) {
      try {
        File(p.join(projectPath, f)).deleteSync();
      } catch (_) {}
    }
    undone = true;
    _add('Undone: ${changed.length} file${changed.length == 1 ? '' : 's'} put back.', LogLevel.system);
  }
}
