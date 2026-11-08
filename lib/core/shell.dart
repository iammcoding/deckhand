import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'sdk.dart';
import 'sessions.dart';

/// A shell command with its log: what a fix or the AI suggests running.
/// Runs through the login shell (macOS, Linux) or cmd (Windows), in the
/// project folder, with the PATH the terminal has.
class ShellJob extends ChangeNotifier {
  final String command;
  final String cwd;
  final List<LogLine> log = [];
  Process? _p;
  int? exitCode;

  ShellJob(this.command, {required this.cwd});

  bool get running => _p != null && exitCode == null;

  void _add(String t, [LogLevel l = LogLevel.info]) {
    log.add(LogLine(t, l));
    notifyListeners();
  }

  Future<int> start() async {
    _add('\$ $command', LogLevel.system);
    // `flutter …` means the Flutter Deckhand uses, even if it isn't on PATH.
    final bin = Sdk.instance.flutterBin;
    final cmd = bin != null && command.startsWith('flutter ') ? '"$bin" ${command.substring(8)}' : command;
    try {
      final p = Platform.isWindows
          ? await Process.start('cmd', ['/c', cmd], workingDirectory: cwd, environment: Sdk.instance.env)
          : await Process.start(Platform.environment['SHELL'] ?? '/bin/zsh', ['-lc', cmd],
              workingDirectory: cwd, environment: Sdk.instance.env);
      _p = p;
      notifyListeners();
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => _add(l, Job.guess(l)));
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => _add(l, LogLevel.warn));
      exitCode = await p.exitCode;
    } catch (e) {
      _add('$e', LogLevel.error);
      exitCode = -1;
    }
    _add(exitCode == 0 ? 'Done' : 'Exited with code $exitCode', exitCode == 0 ? LogLevel.system : LogLevel.error);
    return exitCode!;
  }

  void cancel() => _p?.kill();
}
