import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'fvm.dart';
import 'sdk.dart';

enum LogLevel { info, warn, error, progress, system }

/// The app running now, for the Run page and the status bar.
final currentRun = ValueNotifier<RunSession?>(null);

/// Says in the log when a project's FVM pin decides the Flutter, and warns
/// when the pinned version isn't installed, so a wrong-version failure can't
/// look like a mystery.
void _sayWhichFlutter(String? cwd, void Function(String, LogLevel) add) {
  final pin = Fvm.pinFor(cwd);
  if (pin == null) return;
  if (Fvm.instance.sdkDirFor(pin) != null) {
    add('Using Flutter ${pin.version}, pinned with FVM.', LogLevel.system);
  } else {
    add('This project pins Flutter ${pin.version} with FVM, but it isn\'t installed. Using your default Flutter.', LogLevel.warn);
  }
}

class LogLine {
  final DateTime at;
  final String text;
  final LogLevel level;
  LogLine(this.text, [this.level = LogLevel.info]) : at = DateTime.now();
}

/// A running Flutter command with its log: a build, pub get, doctor.
class Job extends ChangeNotifier {
  final String title;
  final List<String> args;
  final String? cwd;
  final List<LogLine> log = [];
  Process? _p;
  int? exitCode;
  final DateTime started = DateTime.now();
  DateTime? ended;

  Job(this.title, this.args, {this.cwd});

  bool get running => _p != null && exitCode == null;
  Duration get took => (ended ?? DateTime.now()).difference(started);

  void add(String text, [LogLevel level = LogLevel.info]) {
    log.add(LogLine(cleanLine(text), level));
    if (log.length > 20000) log.removeRange(0, log.length - 20000);
    notifyListeners();
  }

  static final _ansi = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');

  /// Tools colour their output; a log shows the text.
  static String cleanLine(String line) => line.replaceAll(_ansi, '');

  /// A line from stderr. Tools also warn there, which isn't a failure.
  static LogLevel stderrLevel(String line) {
    final l = line.toLowerCase();
    return l.contains('[warn]') || l.startsWith('warning') ? LogLevel.warn : LogLevel.error;
  }

  static LogLevel guess(String line) {
    final l = line.toLowerCase();
    if (l.contains('error') || l.contains('exception') || l.contains('failed')) return LogLevel.error;
    if (l.contains('warning')) return LogLevel.warn;
    return LogLevel.info;
  }

  Future<int> start() async {
    final tool = const {'dart', 'fvm'}.contains(args.first);
    add(tool ? '\$ ${args.join(' ')}' : '\$ flutter ${args.join(' ')}', LogLevel.system);
    if (args.first != 'fvm') _sayWhichFlutter(cwd, add);
    try {
      final p = await Sdk.instance.start(args, cwd: cwd);
      _p = p;
      // Nothing answers prompts here: an empty stdin makes a command that
      // asks something stop with an error instead of waiting forever.
      p.stdin.close();
      notifyListeners();
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => add(l, guess(l)));
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => add(l, stderrLevel(l)));
      exitCode = await p.exitCode;
    } catch (e) {
      add('$e', LogLevel.error);
      exitCode = -1;
    }
    ended = DateTime.now();
    add(
      exitCode == 0 ? 'Done in ${_fmt(took)}' : 'Stopped with code $exitCode after ${_fmt(took)}',
      exitCode == 0 ? LogLevel.system : LogLevel.error,
    );
    return exitCode!;
  }

  void cancel() => _p?.kill();

  static String _fmt(Duration d) => d.inMinutes > 0 ? '${d.inMinutes}m ${d.inSeconds % 60}s' : '${d.inSeconds}s';
}

/// `flutter run --machine`: the app on a device, its log, and hot reload,
/// restart and stop over the tool's JSON protocol rather than keystrokes.
class RunSession extends ChangeNotifier {
  final String projectPath;
  final String deviceId;
  final String deviceName;
  final List<String> extraArgs;

  /// `flutter attach`: connect to an app already running on the device
  /// instead of starting it.
  final bool attach;
  RunSession({
    required this.projectPath,
    required this.deviceId,
    required this.deviceName,
    this.extraArgs = const [],
    this.attach = false,
  });

  final List<LogLine> log = [];
  Process? _p;
  String? appId;
  bool started = false;
  bool stopped = false;
  String? progress;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  String? lastReload;

  void _add(String text, [LogLevel level = LogLevel.info]) {
    log.add(LogLine(text, level));
    if (log.length > 20000) log.removeRange(0, log.length - 20000);
    notifyListeners();
  }

  Future<void> start() async {
    final args = [attach ? 'attach' : 'run', '--machine', '-d', deviceId, ...extraArgs];
    _add('\$ flutter ${args.join(' ')}', LogLevel.system);
    _sayWhichFlutter(projectPath, _add);
    try {
      final p = await Sdk.instance.start(args, cwd: projectPath);
      _p = p;
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine);
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => _add(l, LogLevel.error));
      final code = await p.exitCode;
      stopped = true;
      progress = null;
      _add(attach ? 'Detached (code $code).' : 'The app stopped (code $code).', code == 0 ? LogLevel.system : LogLevel.error);
    } catch (e) {
      stopped = true;
      _add('$e', LogLevel.error);
    }
  }

  void _onLine(String line) {
    final t = line.trim();
    if (!t.startsWith('[{')) {
      if (t.isNotEmpty) _add(t, Job.guess(t));
      return;
    }
    try {
      final list = jsonDecode(t) as List;
      for (final m in list.whereType<Map>()) {
        _onMessage(Map<String, dynamic>.from(m));
      }
    } catch (_) {
      _add(t);
    }
  }

  void _onMessage(Map<String, dynamic> m) {
    final id = m['id'];
    if (id is int && _pending.containsKey(id)) {
      _pending.remove(id)!.complete(m);
      return;
    }
    final event = '${m['event'] ?? ''}';
    final params = m['params'] is Map ? Map<String, dynamic>.from(m['params'] as Map) : const <String, dynamic>{};
    switch (event) {
      case 'app.start':
        appId = '${params['appId']}';
      case 'app.started':
        started = true;
        progress = null;
        _add(attach ? 'Attached to the app on $deviceName.' : 'Running on $deviceName.', LogLevel.system);
      case 'app.log':
        final text = '${params['log'] ?? ''}';
        for (final l in const LineSplitter().convert(text)) {
          _add(l, params['error'] == true ? LogLevel.error : Job.guess(l));
        }
      case 'app.progress':
        if (params['finished'] == true) {
          progress = null;
        } else {
          progress = '${params['message'] ?? ''}';
          if (progress!.isNotEmpty) _add(progress!, LogLevel.progress);
        }
        notifyListeners();
      case 'daemon.logMessage':
        final level = '${params['level']}';
        _add(
          '${params['message'] ?? ''}',
          level == 'error'
              ? LogLevel.error
              : level == 'warning'
              ? LogLevel.warn
              : LogLevel.info,
        );
      case 'app.stop':
        stopped = true;
        notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> _send(String method, Map<String, dynamic> params) async {
    final p = _p;
    if (p == null || stopped) return null;
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    p.stdin.writeln(
      jsonEncode([
        {'id': id, 'method': method, 'params': params},
      ]),
    );
    try {
      return await c.future.timeout(const Duration(minutes: 2));
    } catch (_) {
      _pending.remove(id);
      return null;
    }
  }

  bool get canReload => started && !stopped && appId != null;

  /// Hot reload, or a hot restart with [full].
  Future<void> reload({bool full = false}) async {
    if (!canReload) return;
    final sw = Stopwatch()..start();
    _add(full ? 'Hot restart…' : 'Hot reload…', LogLevel.system);
    final r = await _send('app.restart', {'appId': appId, 'fullRestart': full, 'pause': false, 'reason': 'manual'});
    final res = r?['result'];
    final ok = res is Map && (res['code'] == 0 || res['code'] == null) && r?['error'] == null;
    lastReload = ok ? '${full ? 'Restarted' : 'Reloaded'} in ${sw.elapsedMilliseconds} ms' : null;
    _add(
      ok
          ? lastReload!
          : '${full ? 'Restart' : 'Reload'} failed: ${res is Map ? res['message'] ?? '' : r?['error'] ?? 'no answer'}',
      ok ? LogLevel.system : LogLevel.error,
    );
  }

  Future<void> stop() async {
    if (stopped) return;
    if (appId != null) await _send('app.stop', {'appId': appId});
    // The tool sometimes waits; don't leave it holding the device.
    Future.delayed(const Duration(seconds: 4), () {
      if (!stopped) _p?.kill();
    });
  }

  void clear() {
    log.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    if (!stopped) _p?.kill();
    super.dispose();
  }
}
