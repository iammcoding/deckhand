import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'sdk.dart';

enum LogLevel { info, warn, error, progress, system }

/// The app running now, for the Run page and the status bar.
final currentRun = ValueNotifier<RunSession?>(null);

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
    log.add(LogLine(text, level));
    if (log.length > 20000) log.removeRange(0, log.length - 20000);
    notifyListeners();
  }

  static LogLevel guess(String line) {
    final l = line.toLowerCase();
    if (l.contains('error') || l.contains('exception') || l.contains('failed')) return LogLevel.error;
    if (l.contains('warning')) return LogLevel.warn;
    return LogLevel.info;
  }

  Future<int> start() async {
    add('\$ flutter ${args.join(' ')}', LogLevel.system);
    try {
      final p = await Sdk.instance.start(args, cwd: cwd);
      _p = p;
      notifyListeners();
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => add(l, guess(l)));
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => add(l, LogLevel.error));
      exitCode = await p.exitCode;
    } catch (e) {
      add('$e', LogLevel.error);
      exitCode = -1;
    }
    ended = DateTime.now();
    add(exitCode == 0 ? 'Done in ${_fmt(took)}' : 'Stopped with code $exitCode after ${_fmt(took)}',
        exitCode == 0 ? LogLevel.system : LogLevel.error);
    return exitCode!;
  }

  void cancel() => _p?.kill();

  static String _fmt(Duration d) =>
      d.inMinutes > 0 ? '${d.inMinutes}m ${d.inSeconds % 60}s' : '${d.inSeconds}s';
}

/// `flutter run --machine`: the app on a device, its log, and hot reload,
/// restart and stop over the tool's JSON protocol rather than keystrokes.
class RunSession extends ChangeNotifier {
  final String projectPath;
  final String deviceId;
  final String deviceName;
  final List<String> extraArgs;
  RunSession({required this.projectPath, required this.deviceId, required this.deviceName, this.extraArgs = const []});

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
    final args = ['run', '--machine', '-d', deviceId, ...extraArgs];
    _add('\$ flutter ${args.join(' ')}', LogLevel.system);
    try {
      final p = await Sdk.instance.start(args, cwd: projectPath);
      _p = p;
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine);
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => _add(l, LogLevel.error));
      final code = await p.exitCode;
      stopped = true;
      progress = null;
      _add('The app stopped (code $code).', code == 0 ? LogLevel.system : LogLevel.error);
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
        _add('Running on $deviceName.', LogLevel.system);
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
        _add('${params['message'] ?? ''}', level == 'error' ? LogLevel.error : level == 'warning' ? LogLevel.warn : LogLevel.info);
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
    p.stdin.writeln(jsonEncode([
      {'id': id, 'method': method, 'params': params}
    ]));
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
    _add(ok ? lastReload! : '${full ? 'Restart' : 'Reload'} failed: ${res is Map ? res['message'] ?? '' : r?['error'] ?? 'no answer'}',
        ok ? LogLevel.system : LogLevel.error);
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
