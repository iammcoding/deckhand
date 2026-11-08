import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'fvm.dart';

/// Finding and running the Flutter tool.
///
/// A desktop app opened from the Dock or Start menu doesn't get the PATH your
/// terminal has, so `flutter` alone usually isn't found. The path is asked
/// from a login shell once (macOS, Linux) or from `where` (Windows), and
/// remembered. It can be set by hand in Settings.
class Sdk {
  Sdk._();
  static final Sdk instance = Sdk._();

  static const _key = 'flutter_bin';
  String? flutterBin;

  /// The environment commands run with: the login shell's PATH on macOS and
  /// Linux, so `pod`, `adb`, `git` and `xcrun` are found too.
  Map<String, String> env = Map.of(Platform.environment);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    flutterBin = prefs.getString(_key);
    await _loadLoginPath();
    if (flutterBin == null || !File(flutterBin!).existsSync()) {
      flutterBin = await _find();
      if (flutterBin != null) await prefs.setString(_key, flutterBin!);
    }
  }

  Future<void> setFlutterBin(String path) async {
    flutterBin = path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, path);
  }

  Future<void> _loadLoginPath() async {
    if (Platform.isWindows) return;
    try {
      final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
      final r = await Process.run(shell, ['-lc', 'echo \$PATH']).timeout(const Duration(seconds: 8));
      final path = '${r.stdout}'.trim();
      if (path.isNotEmpty) env = {...Platform.environment, 'PATH': path};
    } catch (_) {}
  }

  Future<String?> _find() async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('where', ['flutter'], runInShell: true);
        final first = '${r.stdout}'
            .split(RegExp(r'\r?\n'))
            .map((l) => l.trim())
            .firstWhere((l) => l.toLowerCase().endsWith('flutter.bat'), orElse: () => '');
        return first.isEmpty ? null : first;
      }
      final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
      final r = await Process.run(shell, ['-lc', 'command -v flutter']).timeout(const Duration(seconds: 8));
      final p = '${r.stdout}'.trim();
      return p.isEmpty ? null : p;
    } catch (_) {
      return null;
    }
  }

  bool get ready => flutterBin != null;

  /// The `flutter` for work in [cwd]: the project's FVM version when it pins
  /// one that's installed, otherwise the default.
  String? flutterFor(String? cwd) => Fvm.instance.flutterFor(cwd) ?? flutterBin;

  /// The dart that ships inside the Flutter used for [cwd]. Links are
  /// followed: Homebrew's `flutter` is a link into the real SDK.
  String? dartFor(String? cwd) {
    final f = flutterFor(cwd);
    if (f == null) return null;
    final name = Platform.isWindows ? 'dart.bat' : 'dart';
    final beside = p.join(p.dirname(f), name);
    if (File(beside).existsSync()) return beside;
    try {
      final real = p.join(p.dirname(File(f).resolveSymbolicLinksSync()), name);
      if (File(real).existsSync()) return real;
    } catch (_) {}
    return null;
  }

  /// The environment for work in [cwd]: when a project pins a version, its
  /// `flutter` and `dart` come first on PATH, for whatever else gets started
  /// there (a shell command, a coding agent).
  Map<String, String> envFor(String? cwd) {
    final pinned = Fvm.instance.flutterFor(cwd);
    if (pinned == null) return env;
    final sep = Platform.isWindows ? ';' : ':';
    return {...env, 'PATH': '${p.dirname(pinned)}$sep${env['PATH'] ?? ''}'};
  }

  /// What the first argument picks: `dart` and `fvm` run those tools,
  /// anything else is the Flutter tool for [cwd].
  ({String? bin, List<String> args, Map<String, String> env}) _command(List<String> args, String? cwd) {
    if (args.isNotEmpty && args.first == 'fvm') {
      return (bin: Fvm.instance.bin, args: Fvm.args(args.sublist(1)), env: Fvm.instance.env);
    }
    if (args.isNotEmpty && args.first == 'dart') {
      return (bin: dartFor(cwd), args: args.sublist(1), env: envFor(cwd));
    }
    return (bin: flutterFor(cwd), args: args, env: envFor(cwd));
  }

  static Never _notFound(List<String> args) {
    if (args.isNotEmpty && args.first == 'fvm') throw StateError('FVM is not installed.');
    throw StateError('Flutter was not found. Set its path in Settings.');
  }

  /// Start a tool with [args] in [cwd], streaming its output.
  Future<Process> start(List<String> args, {String? cwd}) {
    final c = _command(args, cwd);
    if (c.bin == null) _notFound(args);
    return Process.start(c.bin!, c.args, workingDirectory: cwd, environment: c.env, runInShell: Platform.isWindows);
  }

  /// Run a tool and collect what it printed.
  Future<ProcessResult> run(List<String> args, {String? cwd, Duration timeout = const Duration(minutes: 3)}) {
    final c = _command(args, cwd);
    if (c.bin == null) _notFound(args);
    return Process.run(
      c.bin!,
      c.args,
      workingDirectory: cwd,
      environment: c.env,
      runInShell: Platform.isWindows,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(timeout);
  }

  /// `flutter --version --machine`: the SDK's version, channel and Dart.
  ///
  /// For a pinned project this is read from the SDK's own file: a version
  /// FVM just installed downloads its tools on first use, which takes minutes
  /// and shouldn't start because a status bar wanted a number.
  Future<Map<String, dynamic>?> version({String? cwd}) async {
    final pin = Fvm.pinFor(cwd);
    final dir = pin == null ? null : Fvm.instance.sdkDirFor(pin);
    if (pin != null && dir != null) {
      try {
        final f = File(p.join(dir, 'bin', 'cache', 'flutter.version.json'));
        return Map<String, dynamic>.from(jsonDecode(await f.readAsString()) as Map);
      } catch (_) {
        return {'frameworkVersion': pin.version, 'channel': 'not set up yet'};
      }
    }
    try {
      final r = await run(['--version', '--machine'], cwd: cwd, timeout: const Duration(seconds: 60));
      final out = '${r.stdout}';
      final start = out.indexOf('{');
      if (start < 0) return null;
      return Map<String, dynamic>.from(jsonDecode(out.substring(start)) as Map);
    } catch (_) {
      return null;
    }
  }
}
