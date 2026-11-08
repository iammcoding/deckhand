import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'safe_fix.dart';
import 'sdk.dart';

/// A tool the model can call.
class AiTool {
  final String name;
  final String description;
  final Map<String, dynamic> schema;
  const AiTool(this.name, this.description, this.schema);
}

/// A call the model made.
class AiToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> args;
  const AiToolCall(this.id, this.name, this.args);
}

/// A tool's answer. [error] answers go back to the model too, so it can try
/// another way.
class AiToolResult {
  final AiToolCall call;
  final String text;
  final bool error;
  const AiToolResult(this.call, this.text, {this.error = false});
}

/// What the AI can do, and nothing else. There is no shell: anything it reads
/// (a log, a file) could carry instructions, so the worst it can do is limited
/// to careful edits inside the project, under SafeFixes. It can't read secrets,
/// which could otherwise go to a cloud provider.
class ProjectTools {
  final String root;
  ProjectTools(this.root);

  /// As much of a file as one answer holds; the model asks for line ranges
  /// for more. Small enough for a local model's context.
  static const maxRead = 24000;
  static const maxFileSize = 1024 * 1024;

  static const _stringProp = {'type': 'string'};

  static const _readFile = AiTool(
    'read_file',
    'Read a text file in the project, with line numbers. Use first_line and last_line for part of a long file.',
    {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Relative to the project, like lib/main.dart'},
        'first_line': {'type': 'integer'},
        'last_line': {'type': 'integer'},
      },
      'required': ['path'],
    },
  );
  static const _listFiles = AiTool('list_files', 'List a folder in the project.', {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'Relative to the project; . for the top'},
    },
  });
  static const _searchTool = AiTool('search', "Find text across the project's files. Answers with file:line and the line.", {
    'type': 'object',
    'properties': {'text': _stringProp},
    'required': ['text'],
  });

  /// Looking only.
  static const read = [
    _readFile,
    _listFiles,
    _searchTool,
    AiTool('run_check', 'Run a check on the project and see its output. analyze finds code errors.', {
      'type': 'object',
      'properties': {
        'check': {
          'type': 'string',
          'enum': ['analyze'],
        },
      },
      'required': ['check'],
    }),
  ];

  /// With editing allowed: two ways to change files, and more checks.
  static const edit = [
    _readFile,
    _listFiles,
    _searchTool,
    AiTool(
      'replace_lines',
      'Replace lines of a file by number, as shown by read_file. Empty new_text deletes them. The easiest way to act on an '
          'error that names a line.',
      {
        'type': 'object',
        'properties': {
          'path': _stringProp,
          'first_line': {'type': 'integer'},
          'last_line': {'type': 'integer'},
          'new_text': _stringProp,
        },
        'required': ['path', 'first_line', 'last_line', 'new_text'],
      },
    ),
    AiTool(
      'edit_file',
      'Replace text in a file. old_text must be copied exactly from the file, including spaces and line breaks, and must '
          'appear exactly once: include nearby lines if it appears more than once. An empty new_text deletes it. Read the '
          'file first.',
      {
        'type': 'object',
        'properties': {'path': _stringProp, 'old_text': _stringProp, 'new_text': _stringProp},
        'required': ['path', 'old_text', 'new_text'],
      },
    ),
    AiTool('create_file', 'Create a new file. Fails if it already exists; use edit_file to change one.', {
      'type': 'object',
      'properties': {'path': _stringProp, 'content': _stringProp},
      'required': ['path', 'content'],
    }),
    AiTool('run_check', 'Run a check on the project and see its output, to confirm a change worked.', {
      'type': 'object',
      'properties': {
        'check': {
          'type': 'string',
          'enum': ['analyze', 'pub_get', 'gen_l10n', 'test'],
        },
      },
      'required': ['check'],
    }),
  ];

  /// Files that aren't anyone's business but the owner's.
  @visibleForTesting
  static bool isSecret(String rel) {
    final name = p.basename(rel).toLowerCase();
    if (name == '.env' || name.startsWith('.env.') || name.endsWith('.env')) return true;
    const exact = {
      'key.properties', 'local.properties', 'keystore.properties', 'google-services.json', 'googleservice-info.plist', //
      '.netrc', '.npmrc', '.pypirc', 'credentials.json', 'service-account.json', 'secrets.json', 'secrets.yaml', 'secrets.dart',
    };
    if (exact.contains(name)) return true;
    const ext = {'.jks', '.keystore', '.p12', '.p8', '.pem', '.key', '.mobileprovision', '.cer', '.der', '.pfx'};
    return ext.contains(p.extension(name));
  }

  /// A path the model gave, if it's inside the project, its own, and not a
  /// secret. Links are followed before deciding, so one can't lead outside.
  String? _inside(String path, {bool mustExist = true}) {
    final clean = p.normalize(p.isAbsolute(path) ? path : p.join(root, path));
    final rootReal = Directory(root).resolveSymbolicLinksSync();
    final inRoot = p.equals(clean, root) || p.isWithin(root, clean) || p.isWithin(rootReal, clean);
    if (!inRoot) return null;
    final rel = p.relative(clean, from: p.isWithin(rootReal, clean) ? rootReal : root);
    if (isSecret(rel)) return null;
    if (rel != '.' && !Snapshot.ownFile(rel)) return null;
    final exists = FileSystemEntity.typeSync(clean) != FileSystemEntityType.notFound;
    if (mustExist && !exists) return clean; // The caller reports "not found".
    // The nearest thing that exists decides where this really is.
    var probe = clean;
    while (FileSystemEntity.typeSync(probe) == FileSystemEntityType.notFound) {
      final up = p.dirname(probe);
      if (up == probe) return null;
      probe = up;
    }
    final real = FileSystemEntity.isDirectorySync(probe)
        ? Directory(probe).resolveSymbolicLinksSync()
        : File(probe).resolveSymbolicLinksSync();
    if (!p.equals(real, rootReal) && !p.isWithin(rootReal, real)) return null;
    return clean;
  }

  static const _refused = "That path isn't available: it's outside the project, build output, or a secret file.";

  Future<AiToolResult> run(AiToolCall c) async {
    try {
      final text = switch (c.name) {
        'read_file' => _read(c),
        'list_files' => _list(c),
        'search' => _search(c),
        'edit_file' => _edit(c),
        'replace_lines' => _replaceLines(c),
        'create_file' => _create(c),
        'run_check' => await _check(c),
        _ => throw _Refuse('There is no tool called ${c.name}.'),
      };
      return AiToolResult(c, text);
    } on _Refuse catch (e) {
      return AiToolResult(c, e.message, error: true);
    } catch (e) {
      return AiToolResult(c, 'That failed: $e', error: true);
    }
  }

  static int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');

  String _text(Map<String, dynamic> args, String key) {
    final v = args[key];
    if (v is! String) throw _Refuse('$key is needed, as text.');
    return v;
  }

  String _read(AiToolCall c) {
    final path = _inside(_text(c.args, 'path'));
    if (path == null) throw _Refuse(_refused);
    final f = File(path);
    if (!f.existsSync()) throw _Refuse('No such file. Use list_files or search to find it.');
    if (f.lengthSync() > maxFileSize) throw _Refuse('That file is too big to read.');
    final bytes = f.readAsBytesSync();
    if (bytes.take(8000).contains(0)) throw _Refuse('That is a binary file.');
    final lines = const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true));
    final first = (_int(c.args['first_line']) ?? 1).clamp(1, lines.isEmpty ? 1 : lines.length);
    final last = (_int(c.args['last_line']) ?? lines.length).clamp(first - 1, lines.length);
    var out = numbered(lines.sublist(first - 1, last), first);
    var note = first > 1 || last < lines.length ? '\n[lines $first to $last of ${lines.length}]' : '';
    if (out.length > maxRead) {
      out = out.substring(0, maxRead);
      note = '\n[cut here: the file has ${lines.length} lines. Ask for a range with first_line and last_line.]';
    }
    return '$out$note';
  }

  /// Lines with their numbers, like an error refers to them.
  static String numbered(List<String> lines, [int first = 1]) =>
      [for (var i = 0; i < lines.length; i++) '${first + i}| ${lines[i]}'].join('\n');

  /// A model copying from read_file can bring the numbers along.
  static String _withoutNumbers(String text) => text.replaceAll(RegExp(r'^\s*\d+\| ?', multiLine: true), '');

  String _replaceLines(AiToolCall c) {
    final path = _inside(_text(c.args, 'path'));
    if (path == null) throw _Refuse(_refused);
    final f = File(path);
    if (!f.existsSync()) throw _Refuse('No such file. Use create_file for a new one.');
    final first = _int(c.args['first_line']), last = _int(c.args['last_line']);
    if (first == null || last == null) throw _Refuse('first_line and last_line are needed.');
    final text = f.readAsStringSync();
    final eol = text.contains('\r\n') ? '\r\n' : '\n';
    final lines = const LineSplitter().convert(text);
    if (first < 1 || last < first || last > lines.length) {
      throw _Refuse('That range is outside the file, which has ${lines.length} lines.');
    }
    final neu = _withoutNumbers(_text(c.args, 'new_text'));
    final out = [
      ...lines.sublist(0, first - 1),
      if (neu.isNotEmpty) ...const LineSplitter().convert(neu),
      ...lines.sublist(last),
    ].join(eol);
    final result = text.endsWith('\n') ? '$out$eol' : out;
    final rel = p.relative(path, from: root);
    final why = Snapshot.problemIn(rel, result);
    if (why != null && Snapshot.problemIn(rel, text) == null) throw _Refuse('Not saved: that would break $rel ($why).');
    f.writeAsStringSync(result);
    return 'Replaced lines $first to $last of $rel.';
  }

  String _list(AiToolCall c) {
    final path = _inside('${c.args['path'] ?? '.'}');
    if (path == null) throw _Refuse(_refused);
    final d = Directory(path);
    if (!d.existsSync()) throw _Refuse('No such folder.');
    final out = <String>[];
    for (final e in d.listSync(followLinks: false)) {
      final rel = p.relative(e.path, from: root);
      if (e is Directory) {
        if (Snapshot.ownFile(p.join(rel, 'x'))) out.add('$rel/');
      } else if (e is File && Snapshot.ownFile(rel) && !isSecret(rel)) {
        out.add(rel);
      }
    }
    out.sort();
    return out.isEmpty ? '(empty)' : out.take(300).join('\n');
  }

  String _search(AiToolCall c) {
    final q = _text(c.args, 'text').toLowerCase();
    if (q.isEmpty) throw _Refuse('text is empty.');
    final hits = <String>[];
    void walk(Directory d) {
      if (hits.length >= 40) return;
      for (final e in d.listSync(followLinks: false)) {
        if (hits.length >= 40) return;
        final rel = p.relative(e.path, from: root);
        if (e is Directory) {
          if (Snapshot.ownFile(p.join(rel, 'x'))) walk(e);
        } else if (e is File && Snapshot.ownFile(rel) && !isSecret(rel) && e.lengthSync() <= maxFileSize) {
          final bytes = e.readAsBytesSync();
          if (bytes.take(8000).contains(0)) continue;
          final lines = const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true));
          for (var i = 0; i < lines.length && hits.length < 40; i++) {
            if (lines[i].toLowerCase().contains(q)) {
              final l = lines[i].trim();
              hits.add('$rel:${i + 1}: ${l.length > 200 ? l.substring(0, 200) : l}');
            }
          }
        }
      }
    }

    walk(Directory(root));
    return hits.isEmpty ? 'Nothing found.' : hits.join('\n');
  }

  String _edit(AiToolCall c) {
    final path = _inside(_text(c.args, 'path'));
    if (path == null) throw _Refuse(_refused);
    final f = File(path);
    if (!f.existsSync()) throw _Refuse('No such file. Use create_file for a new one.');
    final old = _text(c.args, 'old_text'), neu = _text(c.args, 'new_text');
    if (old.isEmpty) throw _Refuse('old_text is empty.');
    final text = f.readAsStringSync();
    // Windows line endings shouldn't make an exact copy fail.
    final crlf = text.contains('\r\n');
    final want = crlf ? old.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n') : old;
    final put = crlf ? neu.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n') : neu;
    final count = want.allMatches(text).length;
    if (count == 0 && RegExp(r'^\s*\d+\| ', multiLine: true).hasMatch(old)) {
      return _edit(AiToolCall(c.id, c.name, {...c.args, 'old_text': _withoutNumbers(old), 'new_text': _withoutNumbers(neu)}));
    }
    if (count == 0) throw _Refuse('old_text is not in the file. Read the file again and copy it exactly, or use replace_lines.');
    if (count > 1) throw _Refuse('old_text appears $count times. Include nearby lines so it appears once.');
    final result = text.replaceFirst(want, put);
    final rel = p.relative(path, from: root);
    // Never write a config file it can't read. It stays as it was.
    final why = Snapshot.problemIn(rel, result);
    if (why != null && Snapshot.problemIn(rel, text) == null) throw _Refuse('Not saved: that would break $rel ($why).');
    f.writeAsStringSync(result);
    return 'Edited $rel.';
  }

  String _create(AiToolCall c) {
    final path = _inside(_text(c.args, 'path'), mustExist: false);
    if (path == null) throw _Refuse(_refused);
    final f = File(path);
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) throw _Refuse('That already exists. Use edit_file.');
    final content = _text(c.args, 'content');
    final rel = p.relative(path, from: root);
    // An empty file with no extension is a folder someone meant to make.
    if (content.trim().isEmpty) throw _Refuse('Not created: content is empty. Files need content; folders appear by themselves.');
    final why = Snapshot.problemIn(rel, content);
    if (why != null) throw _Refuse('Not created: that would be a broken file ($why).');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    return 'Created $rel.';
  }

  static const _checks = {
    'analyze': ['dart', 'analyze', '.'],
    'pub_get': ['pub', 'get'],
    'gen_l10n': ['gen-l10n'],
    'test': ['test'],
  };

  Future<String> _check(AiToolCall c) async {
    final args = _checks['${c.args['check']}'];
    if (args == null) throw _Refuse('Checks: ${_checks.keys.join(', ')}.');
    final r = await Sdk.instance.run(args, cwd: root, timeout: const Duration(minutes: 5));
    var out = '${r.stdout}\n${r.stderr}'.trim();
    // The end is where the verdict is.
    if (out.length > 6000) out = '[start cut]\n${out.substring(out.length - 6000)}';
    return 'Exit code ${r.exitCode}.\n$out';
  }

  /// A short line for the log about what a call did.
  static String describe(AiToolCall c) => switch (c.name) {
    'read_file' => 'read ${c.args['path']}',
    'list_files' => 'looked in ${c.args['path'] ?? '.'}',
    'search' => 'searched for "${c.args['text']}"',
    'edit_file' || 'replace_lines' => 'edited ${c.args['path']}',
    'create_file' => 'created ${c.args['path']}',
    'run_check' => 'ran ${c.args['check']}',
    _ => c.name,
  };

  /// Calls a model wrote out as text rather than as a real tool call. Local
  /// models do this even when they say they support tools.
  static List<AiToolCall> callsInText(String text, Set<String> names) {
    final out = <AiToolCall>[];
    var i = 0;
    while (i < text.length) {
      final start = text.indexOf('{', i);
      if (start < 0) break;
      final end = _closing(text, start);
      if (end < 0) break;
      Object? j;
      try {
        j = jsonDecode(text.substring(start, end + 1));
      } on FormatException {
        i = start + 1;
        continue;
      }
      i = end + 1;
      if (j is! Map) continue;
      final name = j['name'] ?? j['tool'] ?? j['function'];
      final args = j['arguments'] ?? j['parameters'] ?? j['args'] ?? j['input'];
      if (name is String && names.contains(name) && (args is Map || args == null)) {
        out.add(AiToolCall('text-${out.length}', name, args == null ? {} : Map<String, dynamic>.from(args as Map)));
      }
    }
    return out;
  }

  /// Where the object opening at [start] closes, minding strings.
  static int _closing(String s, int start) {
    var depth = 0;
    var inString = false;
    for (var i = start; i < s.length; i++) {
      final ch = s[i];
      if (inString) {
        if (ch == r'\') {
          i++;
        } else if (ch == '"') {
          inString = false;
        }
      } else if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        if (--depth == 0) return i;
      }
    }
    return -1;
  }
}

class _Refuse implements Exception {
  final String message;
  _Refuse(this.message);
}
