import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

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
      final r = await Process.run(shell, ['-lc', 'echo \$PATH'])
          .timeout(const Duration(seconds: 8));
      final path = '${r.stdout}'.trim();
      if (path.isNotEmpty) env = {...Platform.environment, 'PATH': path};
    } catch (_) {}
  }

  Future<String?> _find() async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('where', ['flutter'], runInShell: true);
        final first = '${r.stdout}'.split(RegExp(r'\r?\n')).map((l) => l.trim()).firstWhere(
            (l) => l.toLowerCase().endsWith('flutter.bat'),
            orElse: () => '');
        return first.isEmpty ? null : first;
      }
      final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
      final r = await Process.run(shell, ['-lc', 'command -v flutter'])
          .timeout(const Duration(seconds: 8));
      final p = '${r.stdout}'.trim();
      return p.isEmpty ? null : p;
    } catch (_) {
      return null;
    }
  }

  bool get ready => flutterBin != null;

  /// Start the Flutter tool with [args] in [cwd], streaming its output.
  Future<Process> start(List<String> args, {String? cwd}) {
    final bin = flutterBin;
    if (bin == null) throw StateError('Flutter was not found. Set its path in Settings.');
    return Process.start(bin, args,
        workingDirectory: cwd, environment: env, runInShell: Platform.isWindows);
  }

  /// Run the Flutter tool and collect what it printed.
  Future<ProcessResult> run(List<String> args, {String? cwd, Duration timeout = const Duration(minutes: 3)}) {
    final bin = flutterBin;
    if (bin == null) throw StateError('Flutter was not found. Set its path in Settings.');
    return Process.run(bin, args,
            workingDirectory: cwd,
            environment: env,
            runInShell: Platform.isWindows,
            stdoutEncoding: utf8,
            stderrEncoding: utf8)
        .timeout(timeout);
  }

  /// `flutter --version --machine`: the SDK's version, channel and Dart.
  Future<Map<String, dynamic>?> version() async {
    try {
      final r = await run(['--version', '--machine'], timeout: const Duration(seconds: 60));
      final out = '${r.stdout}';
      final start = out.indexOf('{');
      if (start < 0) return null;
      return Map<String, dynamic>.from(jsonDecode(out.substring(start)) as Map);
    } catch (_) {
      return null;
    }
  }
}
