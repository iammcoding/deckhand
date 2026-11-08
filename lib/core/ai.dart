import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'sessions.dart';

/// What the AI says about an error: the cause, and commands to try in order.
class AiAnswer {
  final String summary;
  final String cause;
  final List<({String title, String command, String why})> steps;
  const AiAnswer(this.summary, this.cause, this.steps);
}

class AiError implements Exception {
  final String message;
  AiError(this.message);
  @override
  String toString() => message;
}

/// "Ask AI" on an error: Claude reads the log and the pubspec and answers
/// with the cause and the commands that fix it. Your own Anthropic API key,
/// kept in the Mac keychain (or the system's credential store elsewhere),
/// never in a file.
class Ai {
  Ai._();
  static final Ai instance = Ai._();

  static const model = 'claude-opus-5-5';
  static const _service = 'app.deckhand.anthropic';
  static const _storage = FlutterSecureStorage();
  String? _key;

  bool get connected => (_key ?? '').isNotEmpty;

  Future<void> load() async {
    try {
      if (Platform.isMacOS) {
        final r = await Process.run('security', ['find-generic-password', '-s', _service, '-w']);
        _key = r.exitCode == 0 ? '${r.stdout}'.trim() : null;
      } else {
        _key = await _storage.read(key: _service);
      }
    } catch (_) {
      _key = null;
    }
  }

  Future<void> setKey(String? key) async {
    final k = (key ?? '').trim();
    if (Platform.isMacOS) {
      await Process.run('security', ['delete-generic-password', '-s', _service]);
      if (k.isNotEmpty) {
        final r = await Process.run('security', ['add-generic-password', '-a', 'deckhand', '-s', _service, '-w', k, '-U']);
        if (r.exitCode != 0) throw AiError("Couldn't save the key to the keychain: ${r.stderr}");
      }
    } else {
      if (k.isEmpty) {
        await _storage.delete(key: _service);
      } else {
        await _storage.write(key: _service, value: k);
      }
    }
    _key = k.isEmpty ? null : k;
  }

  static const _schema = {
    'type': 'object',
    'properties': {
      'summary': {'type': 'string', 'description': 'One sentence: what went wrong.'},
      'cause': {'type': 'string', 'description': 'Why it happened and what to change, in a few short sentences.'},
      'steps': {
        'type': 'array',
        'description': 'Shell commands to run from the project root, in order. Empty if the fix is a code change.',
        'items': {
          'type': 'object',
          'properties': {
            'title': {'type': 'string'},
            'command': {'type': 'string'},
            'why': {'type': 'string'},
          },
          'required': ['title', 'command', 'why'],
          'additionalProperties': false,
        },
      },
    },
    'required': ['summary', 'cause', 'steps'],
    'additionalProperties': false,
  };

  static const _system = '''
You help a Flutter developer fix a failure shown in their run or build log.
Find the real cause (usually the first error, not the last line), say it plainly, and give up to four shell commands that fix it, run in order from the project root.
The commands run in the user's own shell after they confirm each one. Never suggest sudo, deleting anything outside build output folders, git reset, or changing global settings unless there is no other way, and say so in "why" when you do.
If the fix is a change to their code or config, explain exactly what to change in "cause" and leave "steps" empty.
Write for a developer: short, specific, no filler.''';

  Future<AiAnswer> explain({
    required List<LogLine> log,
    required String projectPath,
    String? flutterVersion,
  }) async {
    final key = _key;
    if (key == null || key.isEmpty) throw AiError('Connect your Anthropic API key in Settings first.');
    final tail = log.length > 160 ? log.sublist(log.length - 160) : log;
    String pubspec = '';
    try {
      pubspec = await File('$projectPath/pubspec.yaml').readAsString();
    } catch (_) {}
    final user = '''
OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}
Flutter: ${flutterVersion ?? 'unknown'}

pubspec.yaml:
$pubspec

Log (last ${tail.length} lines):
${tail.map((l) => l.text).join('\n')}''';

    final http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('https://api.anthropic.com/v1/messages'),
            headers: {
              'content-type': 'application/json',
              'x-api-key': key,
              'anthropic-version': '2026-10-21',
              // On a safety decline the API retries on a fallback model itself.
              'anthropic-beta': 'server-side-fallback-2026-07-01',
            },
            body: jsonEncode({
              'model': model,
              'max_tokens': 16000,
              'fallbacks': 'default',
              'system': _system,
              'output_config': {
                'effort': 'medium',
                'format': {'type': 'json_schema', 'schema': _schema},
              },
              'messages': [
                {'role': 'user', 'content': user},
              ],
            }),
          )
          .timeout(const Duration(minutes: 4));
    } on SocketException {
      throw AiError("Couldn't reach the AI. Check your connection.");
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode == 401) throw AiError('The API key was refused. Check it in Settings.');
    if (res.statusCode == 429) throw AiError('Rate limited. Try again in a moment.');
    if (res.statusCode >= 400) {
      throw AiError('AI error ${res.statusCode}: ${body is Map ? (body['error']?['message'] ?? '') : ''}');
    }
    if (body['stop_reason'] == 'refusal') throw AiError('The AI declined to answer this one.');
    final text = [
      for (final b in (body['content'] as List? ?? const []))
        if (b is Map && b['type'] == 'text') '${b['text']}',
    ].join();
    final j = jsonDecode(text) as Map;
    return AiAnswer(
      '${j['summary'] ?? ''}',
      '${j['cause'] ?? ''}',
      [
        for (final s in (j['steps'] as List? ?? const []))
          if (s is Map) (title: '${s['title']}', command: '${s['command']}', why: '${s['why']}'),
      ],
    );
  }
}
