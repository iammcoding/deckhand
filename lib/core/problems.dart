import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'sdk.dart';

/// One analyzer finding.
class Problem {
  final String severity; // ERROR, WARNING, INFO
  final String type;
  final String code;
  final String file;
  final int line;
  final int column;
  final String message;
  const Problem(this.severity, this.type, this.code, this.file, this.line, this.column, this.message);
}

/// `dart analyze --format=machine` for the open project, parsed.
class Problems extends ChangeNotifier {
  Problems._();
  static final Problems instance = Problems._();

  List<Problem> list = const [];
  bool running = false;
  String? error;
  DateTime? at;

  int get errors => list.where((x) => x.severity == 'ERROR').length;
  int get warnings => list.where((x) => x.severity == 'WARNING').length;

  Future<void> run(String projectPath) async {
    final dart = Sdk.instance.dartBin;
    if (dart == null || running) return;
    running = true;
    error = null;
    notifyListeners();
    try {
      final r = await Process.run(
        dart,
        ['analyze', '--format=machine', '.'],
        workingDirectory: projectPath,
        environment: Sdk.instance.env,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(minutes: 3));
      // SEVERITY|TYPE|CODE|FILE|LINE|COLUMN|LENGTH|MESSAGE, on stderr.
      final out = '${r.stderr}\n${r.stdout}';
      final found = <Problem>[];
      for (final line in const LineSplitter().convert(out)) {
        final parts = line.split('|');
        if (parts.length < 8 || !const {'ERROR', 'WARNING', 'INFO'}.contains(parts[0])) continue;
        found.add(
          Problem(
            parts[0],
            parts[1],
            parts[2],
            parts[3],
            int.tryParse(parts[4]) ?? 0,
            int.tryParse(parts[5]) ?? 0,
            parts.sublist(7).join('|').replaceAll(r'\|', '|'),
          ),
        );
      }
      const order = {'ERROR': 0, 'WARNING': 1, 'INFO': 2};
      found.sort(
        (a, b) => (order[a.severity]! - order[b.severity]!) != 0
            ? order[a.severity]! - order[b.severity]!
            : a.file.compareTo(b.file) != 0
            ? a.file.compareTo(b.file)
            : a.line - b.line,
      );
      list = found;
      at = DateTime.now();
    } catch (e) {
      error = '$e';
    } finally {
      running = false;
      notifyListeners();
    }
  }
}
