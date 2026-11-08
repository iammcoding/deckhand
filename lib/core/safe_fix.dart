import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'problems.dart';

/// What changed in a project since its [Snapshot].
class Changes {
  final List<String> modified;
  final List<String> added;
  final List<String> removed;

  /// Changed, but too big to have been copied, so it can't be put back.
  final List<String> cannotRestore;
  const Changes({this.modified = const [], this.added = const [], this.removed = const [], this.cannotRestore = const []});

  List<String> get all => [...modified, ...added, ...removed]..sort();
  bool get isEmpty => all.isEmpty;
}

/// A copy of a project's own files, taken before a fix runs. Works without
/// git. Build output and caches are left out, since tools recreate them.
class Snapshot {
  final String root;
  final String dir;

  /// Path → size, modified time (ms), and whether a copy was kept.
  final Map<String, ({int size, int modified, bool copied})> files;

  /// Files too big to copy: they're watched, not protected.
  final int skipped;
  const Snapshot(this.root, this.dir, this.files, this.skipped);

  static const maxFile = 5 * 1024 * 1024;
  static const maxTotal = 300 * 1024 * 1024;

  static const _skipDirs = {
    '.git', '.dart_tool', '.gradle', '.idea', '.fvm', '.symlinks', '.build', '.swiftpm', '.widget_preview', //
    'Pods', 'node_modules', 'ephemeral', 'DerivedData',
  };

  /// Whether [rel] is the project's own, and not something tools make. `build`
  /// is output anywhere except in source folders, where it can be real code.
  static bool ownFile(String rel) {
    final parts = p.split(rel);
    for (var i = 0; i < parts.length - 1; i++) {
      final d = parts[i];
      if (_skipDirs.contains(d)) return false;
      if (d == 'build' && parts.first != 'lib' && parts.first != 'test') return false;
    }
    return parts.last != '.DS_Store';
  }

  static List<File> _walk(String root) {
    final out = <File>[];
    void walk(Directory d) {
      try {
        for (final e in d.listSync(followLinks: false)) {
          // Links are left alone: what they point at isn't this project's.
          final rel = p.relative(e.path, from: root);
          if (e is Directory) {
            if (ownFile(p.join(rel, 'x'))) walk(e);
          } else if (e is File && ownFile(rel)) {
            out.add(e);
          }
        }
      } catch (_) {
        // A folder we can't read can't be changed by a fix run as this user
        // either, and shouldn't stop the rest being saved.
      }
    }

    walk(Directory(root));
    return out;
  }

  /// Copies [root] into a new folder under [store]. Off the main thread: a
  /// big project shouldn't freeze the window.
  static Future<Snapshot> take(String root, String store) => Isolate.run(() => _take(root, store));

  static Snapshot _take(String root, String store) {
    final at = DateTime.now().microsecondsSinceEpoch;
    final dir = p.join(store, '$at');
    Directory(p.join(dir, 'files')).createSync(recursive: true);
    // It can hold .env and signing files: only this user may read it.
    if (!Platform.isWindows) Process.runSync('chmod', ['-R', '700', store]);
    final files = <String, ({int size, int modified, bool copied})>{};
    var total = 0, skipped = 0;
    // Smallest first: if the limit is hit, it's assets that miss out, not code.
    final all = [for (final f in _walk(root)) (f, f.statSync())]..sort((a, b) => a.$2.size.compareTo(b.$2.size));
    for (final (f, s) in all) {
      final rel = p.relative(f.path, from: root);
      final copy = s.size <= maxFile && total + s.size <= maxTotal;
      if (copy) {
        final to = File(p.join(dir, 'files', rel));
        to.parent.createSync(recursive: true);
        f.copySync(to.path);
        total += s.size;
      } else {
        skipped++;
      }
      files[rel] = (size: s.size, modified: s.modified.millisecondsSinceEpoch, copied: copy);
    }
    return Snapshot(root, dir, files, skipped);
  }

  String _copyOf(String rel) => p.join(dir, 'files', rel);

  /// What's different now. A file rewritten with the same bytes hasn't changed.
  Changes diff() {
    final modified = <String>[], added = <String>[], removed = <String>[], lost = <String>[];
    final seen = <String>{};
    for (final f in _walk(root)) {
      final rel = p.relative(f.path, from: root);
      seen.add(rel);
      final was = files[rel];
      if (was == null) {
        added.add(rel);
        continue;
      }
      final s = f.statSync();
      if (s.size == was.size && s.modified.millisecondsSinceEpoch == was.modified) continue;
      if (was.copied) {
        if (s.size == was.size && listEquals(f.readAsBytesSync(), File(_copyOf(rel)).readAsBytesSync())) continue;
      } else {
        lost.add(rel);
      }
      modified.add(rel);
    }
    for (final rel in files.keys) {
      if (!seen.contains(rel)) {
        removed.add(rel);
        if (!files[rel]!.copied) lost.add(rel);
      }
    }
    return Changes(modified: modified, added: added, removed: removed, cannotRestore: lost);
  }

  /// Puts the project back. What's being replaced is kept in `replaced/`, so
  /// nothing is ever lost by undoing.
  void restore(Changes c) {
    final keep = p.join(dir, 'replaced');
    void set(String rel) {
      final now = File(p.join(root, rel));
      if (now.existsSync()) {
        final to = File(p.join(keep, rel));
        to.parent.createSync(recursive: true);
        now.copySync(to.path);
      }
    }

    for (final rel in c.added) {
      set(rel);
      File(p.join(root, rel)).deleteSync();
    }
    for (final rel in [...c.modified, ...c.removed]) {
      if (c.cannotRestore.contains(rel)) continue;
      set(rel);
      final to = File(p.join(root, rel));
      to.parent.createSync(recursive: true);
      File(_copyOf(rel)).copySync(to.path);
      to.setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(files[rel]!.modified));
    }
  }

  // ---- Is the project still intact? ------------------------------------------

  /// Why a config file no longer reads, or null if it does.
  @visibleForTesting
  static String? problemIn(String rel, String text) {
    final ext = p.extension(rel).toLowerCase();
    try {
      if (ext == '.yaml' || ext == '.yml') {
        final doc = loadYaml(text);
        if (p.basename(rel) == 'pubspec.yaml' && (doc is! Map || doc['name'] == null)) {
          return 'it has no project name any more';
        }
      } else if (ext == '.json' || ext == '.arb' || p.basename(rel) == '.fvmrc') {
        jsonDecode(text);
      }
      return null;
    } on YamlException catch (e) {
      return '${e.message} (line ${(e.span?.start.line ?? -1) + 1})';
    } on FormatException catch (e) {
      return e.message;
    }
  }

  /// A config file this fix broke, as `path: why`. A file that was already
  /// broken before doesn't count: the fix isn't to blame.
  String? brokenBy(Changes c) {
    for (final rel in [...c.modified, ...c.added]) {
      final File now = File(p.join(root, rel));
      if (!now.existsSync()) continue;
      String text;
      try {
        text = now.readAsStringSync();
      } catch (_) {
        continue; // Not text.
      }
      final why = problemIn(rel, text);
      if (why == null) continue;
      final was = files[rel];
      if (was != null && was.copied) {
        try {
          if (problemIn(rel, File(_copyOf(rel)).readAsStringSync()) != null) continue;
        } catch (_) {
          continue;
        }
      }
      return '$rel: $why';
    }
    // The project's main file going missing is breakage too.
    if (c.removed.contains('pubspec.yaml')) return 'pubspec.yaml: it was deleted';
    return null;
  }
}

/// Deckhand's own check of a fix, which doesn't rely on what the AI claims.
class Verdict {
  /// Why the project should go back, or null if it stays.
  final String? failed;

  /// Worth knowing, but no reason to undo.
  final String? note;
  const Verdict({this.failed, this.note});

  static const _commandsWorthRetrying = {'pub', 'gen-l10n', 'analyze', 'dart'};
  static final _noNetwork = RegExp(
    r'SocketException|Failed host lookup|Connection (refused|failed|closed)|Network is unreachable',
    caseSensitive: false,
  );

  /// The error lines of a log, to recognise the same failure coming back.
  static Set<String> errorsIn(Iterable<String> lines) => {
    for (final l in lines.map((x) => x.trim()))
      if (l.length >= 12 && !l.startsWith('#') && !l.startsWith('Stopped with code')) l,
  };

  static String _lastWords(String out) {
    final lines = out
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#') && !l.startsWith('<asynchronous'));
    final useful = lines.where((l) => !l.toLowerCase().startsWith('unhandled exception'));
    final first = useful.firstWhere(
      (l) => RegExp('error|exception|failed|because', caseSensitive: false).hasMatch(l),
      orElse: () => useful.isEmpty ? '' : useful.first,
    );
    return first.length > 160 ? '${first.substring(0, 160)}…' : first;
  }

  /// Does the project still work, and is the failure gone? [run] runs a Flutter
  /// tool in the project; [retry] is the command that failed, when it's quick
  /// to try again; [failure] is its error lines.
  static Future<Verdict> check({
    required Changes changes,
    required Future<ProcessResult> Function(List<String> args) run,
    List<String>? retry,
    Set<String> failure = const {},
  }) async {
    if (changes.isEmpty) return const Verdict(note: "It didn't change anything.");
    if (changes.all.contains('pubspec.yaml') || changes.all.contains('pubspec.lock')) {
      final r = await run(['pub', 'get']);
      final out = '${r.stdout}\n${r.stderr}';
      if (r.exitCode != 0 && !_noNetwork.hasMatch(out)) {
        return Verdict(failed: 'flutter pub get fails with its changes (${_lastWords(out)})');
      }
    }
    if (retry == null || retry.isEmpty || !_commandsWorthRetrying.contains(retry.first)) return const Verdict();
    final r = await run(retry);
    if (r.exitCode == 0) return const Verdict();
    final out = '${r.stdout}\n${r.stderr}';
    final name = retry.first == 'dart' ? retry.join(' ') : 'flutter ${retry.join(' ')}';
    if (errorsIn(out.split('\n')).any(failure.contains)) {
      return Verdict(failed: '$name still fails the same way');
    }
    // Moved on to a different problem: that can be real progress, so keep it.
    return Verdict(note: '$name now fails differently: ${_lastWords(out)}');
  }
}

enum SafeFixState { running, kept, restored, undone, unprotected }

/// One protected fix: its copy of the project, and how it turned out.
class SafeFix {
  final String title;
  final String projectPath;
  SafeFixState state = SafeFixState.running;
  Snapshot? snapshot;
  Changes changes = const Changes();

  /// The config file it broke, when Deckhand put things back.
  String? broke;

  /// Why Deckhand's own check rejected it, when it put things back.
  String? failedCheck;

  /// What Deckhand's own check found that's worth saying.
  String? note;

  /// Analyzer errors it added, when that went up.
  int addedErrors = 0;
  int? exitCode;
  String? error;
  SafeFix(this.title, this.projectPath);

  bool get canUndo => state == SafeFixState.kept && snapshot != null && changes.all.isNotEmpty;
}

/// The safety net round everything that changes a project for you: a Fix
/// button, an AI suggestion, a coding agent.
///
/// A copy is saved first. Afterwards, if a config file no longer reads, the
/// project is put back straight away, because that is never what was wanted.
/// More analyzer errors could be half a job, so that's only reported, with
/// Undo next to it. Only the project's files are covered: a command that
/// installs something on the computer can't be undone from here.
class SafeFixes extends ChangeNotifier {
  SafeFixes._();
  static final SafeFixes instance = SafeFixes._();

  static const keep = 5;
  final Map<String, SafeFix> _latest = {};

  /// Where copies go; set by tests.
  @visibleForTesting
  static String? storeOverride;

  SafeFix? latest(String project) => _latest[project];

  void dismiss(String project) {
    _latest.remove(project);
    notifyListeners();
  }

  static String get _base {
    if (storeOverride != null) return storeOverride!;
    final env = Platform.environment;
    if (Platform.isMacOS) return p.join(env['HOME'] ?? '', 'Library', 'Application Support', 'Deckhand', 'snapshots');
    if (Platform.isWindows) return p.join(env['APPDATA'] ?? '', 'Deckhand', 'snapshots');
    return p.join(env['XDG_DATA_HOME'] ?? p.join(env['HOME'] ?? '', '.local', 'share'), 'deckhand', 'snapshots');
  }

  static String _storeFor(String project) => p.join(_base, base64Url.encode(utf8.encode(project)).replaceAll('=', ''));

  /// Old copies go; a project's copies shouldn't pile up forever.
  static void _prune(String store) {
    try {
      final dirs = Directory(store).listSync().whereType<Directory>().toList()..sort((a, b) => b.path.compareTo(a.path));
      for (final d in dirs.skip(keep)) {
        d.deleteSync(recursive: true);
      }
    } catch (_) {}
  }

  /// Runs [action] protected. It isn't run at all if the copy can't be made.
  Future<SafeFix> guard(
    String title,
    String project,
    Future<int?> Function() action, {
    void Function(String text, bool isProblem)? say,
    bool checkAnalyzer = true,
    Future<Verdict> Function(Changes changes)? verify,
  }) async {
    final fix = SafeFix(title, project);
    _latest[project] = fix;
    notifyListeners();
    final store = _storeFor(project);
    try {
      fix.snapshot = await Snapshot.take(project, store);
    } catch (e) {
      fix
        ..state = SafeFixState.unprotected
        ..error = "Couldn't save a copy of the project first, so nothing was run: $e";
      say?.call(fix.error!, true);
      notifyListeners();
      return fix;
    }
    _prune(store);
    final snap = fix.snapshot!;
    if (snap.skipped > 0) say?.call("${snap.skipped} big files aren't in the saved copy, so they can't be undone.", false);
    // Before the fix, so the comparison is with this project and not whatever
    // was last analyzed.
    final problems = Problems.instance;
    final before = checkAnalyzer && problems.at != null && !problems.running ? problems.errors : null;
    try {
      fix.exitCode = await action();
    } catch (e) {
      fix.error = '$e';
      say?.call('$e', true);
    }
    fix.changes = await Isolate.run(snap.diff);
    final why = snap.brokenBy(fix.changes);
    if (why != null) {
      fix.broke = why;
      undo(fix);
      if (fix.state == SafeFixState.undone) {
        fix.state = SafeFixState.restored;
        say?.call('That broke $why. Deckhand put your files back as they were.', true);
      } else {
        fix.state = SafeFixState.kept;
        say?.call('That broke $why. ${fix.error}', true);
      }
    } else {
      fix.state = SafeFixState.kept;
      if (verify != null && fix.error == null && !fix.changes.isEmpty) {
        say?.call('Checking it worked…', false);
        Verdict verdict;
        try {
          verdict = await verify(fix.changes);
        } catch (e) {
          verdict = Verdict(note: "Couldn't check it worked: $e");
        }
        fix.note = verdict.note;
        if (verdict.failed != null) {
          fix.failedCheck = verdict.failed;
          undo(fix);
          if (fix.state == SafeFixState.undone) {
            fix.state = SafeFixState.restored;
            say?.call("It didn't work: ${verdict.failed}. Deckhand put your files back as they were.", true);
            notifyListeners();
            if (checkAnalyzer) await Problems.instance.run(project);
            return fix;
          }
          fix.state = SafeFixState.kept;
          say?.call("It didn't work: ${verdict.failed}. ${fix.error}", true);
        } else if (verdict.note != null) {
          say?.call(verdict.note!, true);
        }
      }
      if (fix.changes.isEmpty) {
        say?.call('It changed no files.', false);
      } else {
        say?.call('Changed: ${fix.changes.all.join(', ')}', false);
      }
    }
    notifyListeners();
    final code = fix.changes.all.any((f) => f.endsWith('.dart') || p.basename(f) == 'pubspec.yaml');
    if (checkAnalyzer && code && (fix.state == SafeFixState.restored || fix.state == SafeFixState.kept)) {
      await problems.run(project);
      if (fix.state == SafeFixState.kept && before != null && problems.errors > before) {
        fix.addedErrors = problems.errors - before;
        say?.call('The analyzer now finds ${fix.addedErrors} more errors than before.', true);
      }
      notifyListeners();
    }
    return fix;
  }

  /// Puts the project back from this fix's copy.
  void undo(SafeFix fix) {
    final snap = fix.snapshot;
    if (snap == null) return;
    try {
      snap.restore(fix.changes);
      fix.state = SafeFixState.undone;
    } catch (e) {
      fix.error = "Couldn't put everything back: $e. Your copy is in ${snap.dir}.";
    }
    notifyListeners();
  }
}
