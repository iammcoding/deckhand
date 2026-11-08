import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'sdk.dart';

/// What a project asks for: `.fvmrc` (or the older `.fvm/fvm_config.json`),
/// in the project folder or a folder above it, as in a monorepo.
class FvmPin {
  final String version;
  final String root; // the folder holding the config
  final String configPath;
  final Map<String, String> flavors;
  const FvmPin(this.version, this.root, this.configPath, this.flavors);
}

/// A Flutter version in FVM's cache, from `fvm api list`.
class FvmVersion {
  final String name;
  final String flutter;
  final String dart;
  final String channel;
  final bool isSetup;
  final String directory;
  final bool unused;
  const FvmVersion(this.name, this.flutter, this.dart, this.channel, this.isSetup, this.directory, this.unused);
}

/// A Flutter release that can be installed, from `fvm api releases`.
class FvmRelease {
  final String version;
  final String channel;
  final String dart;
  final DateTime? date;
  const FvmRelease(this.version, this.channel, this.dart, this.date);
}

class FvmError implements Exception {
  final String message;
  FvmError(this.message);
  @override
  String toString() => message;
}

/// FVM: several Flutter versions on one computer, a chosen one per project.
///
/// A project's pin is read straight from its files on every command, so a
/// `git checkout` that changes `.fvmrc` is followed at once and FVM doesn't
/// have to be installed for a teammate's pin to work.
class Fvm extends ChangeNotifier {
  Fvm._();
  static final Fvm instance = Fvm._();

  String? bin;
  String? version;

  /// FVM's version cache; replaced by what FVM reports once it's found.
  String? _versionsDir;
  String? _globalLink;

  bool get installed => bin != null;

  static String get _home => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';

  String get versionsDir {
    if (_versionsDir != null) return _versionsDir!;
    final custom = Sdk.instance.env['FVM_CACHE_PATH'];
    return p.join(custom != null && custom.isNotEmpty ? custom : p.join(_home, 'fvm'), 'versions');
  }

  /// Finds FVM and asks it where its cache is. Safe to call again, after an
  /// install for instance.
  Future<void> detect() async {
    bin = await _find();
    version = null;
    _versionsDir = null;
    _globalLink = null;
    if (bin != null) {
      try {
        final c = await api(['context']);
        final ctx = c['context'];
        if (ctx is Map) {
          version = ctx['fvmVersion'] as String?;
          _versionsDir = ctx['versionsCachePath'] as String?;
          _globalLink = ctx['globalCacheLink'] as String?;
        }
      } catch (_) {
        // An older FVM without this command still works for everything else.
        try {
          final r = await run(['--version']);
          version = '${r.stdout}'.trim().split('\n').first;
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  Future<String?> _find() async {
    final found = await _fromShell();
    if (found != null) return found;
    final local = Platform.environment['LOCALAPPDATA'] ?? '';
    final candidates = Platform.isWindows
        ? [p.join(local, 'Pub', 'Cache', 'bin', 'fvm.bat'), r'C:\ProgramData\chocolatey\bin\fvm.exe']
        : [
            if ((Sdk.instance.env['PUB_CACHE'] ?? '').isNotEmpty) p.join(Sdk.instance.env['PUB_CACHE']!, 'bin', 'fvm'),
            p.join(_home, '.pub-cache', 'bin', 'fvm'),
            p.join(_home, 'fvm', 'bin', 'fvm'),
            p.join(_home, '.fvm_flutter', 'bin', 'fvm'),
            '/opt/homebrew/bin/fvm',
            '/usr/local/bin/fvm',
          ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  Future<String?> _fromShell() async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('where', ['fvm'], runInShell: true);
        final first = '${r.stdout}'.split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty).firstOrNull;
        return first;
      }
      final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
      final r = await Process.run(shell, ['-lc', 'command -v fvm']).timeout(const Duration(seconds: 8));
      final out = '${r.stdout}'.trim();
      // A shell function or alias prints a name, not a path.
      return out.isNotEmpty && p.isAbsolute(out) && File(out).existsSync() ? out : null;
    } catch (_) {
      return null;
    }
  }

  /// FVM's arguments. The flag makes it take the safe default rather than
  /// wait for an answer nobody can give here.
  static List<String> args(List<String> a) => [...a, '--fvm-skip-input'];

  /// FVM started through pub runs `dart`, so that has to be on PATH.
  Map<String, String> get env {
    final e = Map<String, String>.of(Sdk.instance.env);
    final f = Sdk.instance.flutterBin;
    if (f != null) {
      final sep = Platform.isWindows ? ';' : ':';
      e['PATH'] = '${p.dirname(f)}$sep${e['PATH'] ?? ''}';
    }
    return e;
  }

  Future<ProcessResult> run(List<String> a, {String? cwd, Duration timeout = const Duration(minutes: 2)}) {
    final b = bin;
    if (b == null) throw FvmError('FVM is not installed.');
    return Process.run(
      b,
      args(a),
      workingDirectory: cwd,
      environment: env,
      runInShell: Platform.isWindows,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(timeout);
  }

  /// `fvm api …`, parsed.
  Future<Map<String, dynamic>> api(List<String> a, {String? cwd, Duration timeout = const Duration(minutes: 2)}) async {
    final r = await run(['api', ...a], cwd: cwd, timeout: timeout);
    final out = '${r.stdout}';
    if (r.exitCode != 0) {
      final why = '${r.stderr}'.trim();
      throw FvmError(why.isNotEmpty ? why : (out.trim().isNotEmpty ? out.trim() : 'FVM stopped with code ${r.exitCode}.'));
    }
    return parseJson(out);
  }

  /// Takes the JSON out of what FVM printed: it can put a notice before it.
  @visibleForTesting
  static Map<String, dynamic> parseJson(String out) {
    final start = out.indexOf('{');
    final end = out.lastIndexOf('}');
    if (start < 0 || end <= start) throw FvmError('FVM answered with something unexpected.');
    try {
      return Map<String, dynamic>.from(jsonDecode(out.substring(start, end + 1)) as Map);
    } on FormatException {
      throw FvmError('FVM answered with something unexpected.');
    }
  }

  @visibleForTesting
  static List<FvmVersion> parseList(Map<String, dynamic> j) {
    final unused = {for (final x in (j['unreferencedVersions'] as List? ?? const [])) '$x'};
    return [
      for (final v in (j['versions'] as List? ?? const []))
        if (v is Map)
          FvmVersion(
            '${v['name'] ?? ''}',
            '${v['flutterSdkVersion'] ?? ''}',
            '${v['dartSdkVersion'] ?? ''}',
            '${v['releaseChannel'] ?? ''}',
            v['isSetup'] == true,
            '${v['directory'] ?? ''}',
            unused.contains('${v['name']}'),
          ),
    ];
  }

  @visibleForTesting
  static List<FvmRelease> parseReleases(Map<String, dynamic> j) => [
    for (final v in (j['versions'] as List? ?? const []))
      if (v is Map)
        FvmRelease(
          '${v['version'] ?? ''}',
          '${v['channelName'] ?? v['channel'] ?? ''}',
          '${v['dart_sdk_version'] ?? ''}',
          DateTime.tryParse('${v['release_date'] ?? ''}'),
        ),
  ];

  Future<({List<FvmVersion> versions, String size})> list({bool sizes = false}) async {
    final j = await api(['list', if (!sizes) '--skip-size-calculation']);
    return (versions: parseList(j), size: '${j['size'] ?? ''}');
  }

  Future<List<FvmRelease>> releases({String channel = 'stable', int limit = 200}) async {
    return parseReleases(await api(['releases', '--limit', '$limit', '--filter-channel', channel]));
  }

  /// Versions nothing pins, and what `fvm cleanup --remove-unused` would
  /// delete. Null on an FVM too old to have the command.
  Future<({List<String> unused, List<String> removable, List<String> upgrades})?> cleanup() async {
    try {
      final j = await api(['cleanup']);
      return (
        unused: [for (final x in (j['unused'] as List? ?? const [])) '$x'],
        removable: [for (final x in (j['removable'] as List? ?? const [])) '$x'],
        upgrades: [
          for (final u in (j['upgrades'] as List? ?? const []))
            if (u is Map) '${u['fromVersion']} → ${u['toVersion']}: ${u['reason'] ?? ''}',
        ],
      );
    } catch (_) {
      return null;
    }
  }

  /// The version `fvm global` points at, read from its link.
  String? get globalVersion {
    final link = _globalLink ?? p.join(p.dirname(versionsDir), 'default');
    try {
      final l = Link(link);
      return l.existsSync() ? p.basename(l.targetSync()) : null;
    } catch (_) {
      return null;
    }
  }

  // ---- A project's pin -------------------------------------------------------

  /// The pin that applies to [dir], looking up through its parents.
  static FvmPin? pinFor(String? dir) {
    if (dir == null) return null;
    var d = p.normalize(p.absolute(dir));
    for (var i = 0; i < 12; i++) {
      final pin = _readPin(d);
      if (pin != null) return pin;
      final up = p.dirname(d);
      if (up == d) return null;
      d = up;
    }
    return null;
  }

  static FvmPin? _readPin(String dir) {
    for (final (file, key) in [
      (p.join(dir, '.fvmrc'), 'flutter'),
      (p.join(dir, '.fvm', 'fvm_config.json'), 'flutterSdkVersion'),
    ]) {
      final f = File(file);
      if (!f.existsSync()) continue;
      try {
        final j = jsonDecode(f.readAsStringSync());
        if (j is! Map) continue;
        final v = j[key] ?? j['flutter'] ?? j['flutterSdkVersion'];
        if (v is! String || v.trim().isEmpty) continue;
        final flavors = j['flavors'];
        return FvmPin(v.trim(), dir, file, {
          if (flavors is Map)
            for (final e in flavors.entries) '${e.key}': '${e.value}',
        });
      } catch (_) {
        // A broken file isn't a pin; carry on as if it weren't there.
      }
    }
    return null;
  }

  static String _flutterName() => Platform.isWindows ? 'flutter.bat' : 'flutter';

  /// The pinned SDK's folder on this computer, or null if it isn't there.
  /// `.fvmrc` decides: a `.fvm/flutter_sdk` link left over from before a
  /// `git checkout` isn't trusted unless it points at the pinned version.
  String? sdkDirFor(FvmPin pin) {
    bool ok(String dir) => File(p.join(dir, 'bin', _flutterName())).existsSync();
    final cached = p.join(versionsDir, pin.version);
    if (ok(cached)) return cached;
    final local = p.join(pin.root, '.fvm', 'versions', pin.version);
    if (ok(local)) return local;
    final link = Link(p.join(pin.root, '.fvm', 'flutter_sdk'));
    try {
      if (link.existsSync() && p.basename(link.targetSync()) == pin.version && ok(link.path)) return link.path;
    } catch (_) {}
    return null;
  }

  /// The `flutter` a project should use, or null when it has no usable pin.
  String? flutterFor(String? dir) {
    final pin = pinFor(dir);
    if (pin == null) return null;
    final sdk = sdkDirFor(pin);
    return sdk == null ? null : p.join(sdk, 'bin', _flutterName());
  }

  /// True when a project pins a version that isn't on this computer.
  bool missingFor(String? dir) {
    final pin = pinFor(dir);
    return pin != null && sdkDirFor(pin) == null;
  }

  /// Takes FVM out of a project: its config and its folder of links. The
  /// SDKs in the cache are untouched.
  static Future<void> unpin(FvmPin pin) async {
    final rc = File(p.join(pin.root, '.fvmrc'));
    if (rc.existsSync()) await rc.delete();
    final dir = Directory(p.join(pin.root, '.fvm'));
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}
