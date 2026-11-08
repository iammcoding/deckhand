import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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

/// The model providers Deckhand can ask.
enum Provider {
  anthropic('Anthropic (Claude)', needsKey: true, keyHint: 'sk-ant-…', keyUrl: 'console.anthropic.com → API keys'),
  openai('OpenAI', needsKey: true, keyHint: 'sk-…', keyUrl: 'platform.openai.com → API keys'),
  gemini('Google Gemini', needsKey: true, keyHint: 'AIza…', keyUrl: 'aistudio.google.com → Get API key'),
  openrouter('OpenRouter', needsKey: true, keyHint: 'sk-or-…', keyUrl: 'openrouter.ai → Keys'),
  ollama('Ollama (local, open source)', needsKey: false, defaultUrl: 'http://localhost:11434'),
  custom('OpenAI-compatible (LM Studio, vLLM…)', needsKey: false, defaultUrl: 'http://localhost:1234/v1');

  final String label;
  final bool needsKey;
  final String keyHint;
  final String keyUrl;
  final String defaultUrl;
  const Provider(this.label, {this.needsKey = false, this.keyHint = '', this.keyUrl = '', this.defaultUrl = ''});

  bool get hasUrl => this == ollama || this == custom;
}

/// "Ask AI" on an error, with whichever model you connect: the log tail and
/// the pubspec go in, the cause and the commands that fix it come out.
/// Keys live in the Mac keychain (the system credential store elsewhere),
/// never in a file.
class Ai {
  Ai._();
  static final Ai instance = Ai._();

  static const _storage = FlutterSecureStorage();
  Provider provider = Provider.anthropic;
  String model = 'claude-opus-5-5';
  String baseUrl = '';
  final Map<Provider, String> _keys = {};

  String _svc(Provider p) => 'app.deckhand.${p.name}';

  bool get connected => model.isNotEmpty && (!provider.needsKey || (_keys[provider] ?? '').isNotEmpty);

  bool hasKey(Provider p) => (_keys[p] ?? '').isNotEmpty;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    provider = Provider.values.where((p) => p.name == prefs.getString('ai_provider')).firstOrNull ?? Provider.anthropic;
    model = prefs.getString('ai_model_${provider.name}') ?? (provider == Provider.anthropic ? 'claude-opus-5-5' : '');
    baseUrl = prefs.getString('ai_url_${provider.name}') ?? provider.defaultUrl;
    for (final p in Provider.values.where((p) => p.needsKey)) {
      final k = await _readKey(p);
      if (k != null && k.isNotEmpty) _keys[p] = k;
    }
  }

  Future<void> use(Provider p, {String? model, String? url}) async {
    final prefs = await SharedPreferences.getInstance();
    provider = p;
    await prefs.setString('ai_provider', p.name);
    if (model != null) {
      this.model = model;
      await prefs.setString('ai_model_${p.name}', model);
    } else {
      this.model = prefs.getString('ai_model_${p.name}') ?? (p == Provider.anthropic ? 'claude-opus-5-5' : '');
    }
    if (url != null) {
      baseUrl = url;
      await prefs.setString('ai_url_${p.name}', url);
    } else {
      baseUrl = prefs.getString('ai_url_${p.name}') ?? p.defaultUrl;
    }
  }

  Future<String?> _readKey(Provider p) async {
    try {
      if (Platform.isMacOS) {
        final r = await Process.run('security', ['find-generic-password', '-s', _svc(p), '-w']);
        return r.exitCode == 0 ? '${r.stdout}'.trim() : null;
      }
      return await _storage.read(key: _svc(p));
    } catch (_) {
      return null;
    }
  }

  Future<void> setKey(Provider p, String? key) async {
    final k = (key ?? '').trim();
    if (Platform.isMacOS) {
      await Process.run('security', ['delete-generic-password', '-s', _svc(p)]);
      if (k.isNotEmpty) {
        final r = await Process.run('security', ['add-generic-password', '-a', 'deckhand', '-s', _svc(p), '-w', k, '-U']);
        if (r.exitCode != 0) throw AiError("Couldn't save the key to the keychain: ${r.stderr}");
      }
    } else if (k.isEmpty) {
      await _storage.delete(key: _svc(p));
    } else {
      await _storage.write(key: _svc(p), value: k);
    }
    if (k.isEmpty) {
      _keys.remove(p);
    } else {
      _keys[p] = k;
    }
  }

  String _url(String path) {
    final b = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return '$b$path';
  }

  /// The models this provider offers, from the provider itself.
  Future<List<String>> listModels(Provider p) async {
    final key = _keys[p] ?? '';
    final url = p == provider ? baseUrl : p.defaultUrl;
    String u(String path) => '${url.endsWith('/') ? url.substring(0, url.length - 1) : url}$path';
    try {
      final (Uri uri, Map<String, String> h) = switch (p) {
        Provider.anthropic => (
          Uri.parse('https://api.anthropic.com/v1/models?limit=100'),
          {'x-api-key': key, 'anthropic-version': '2026-10-21'},
        ),
        Provider.openai => (Uri.parse('https://api.openai.com/v1/models'), {'authorization': 'Bearer $key'}),
        Provider.gemini => (
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?key=$key&pageSize=200'),
          <String, String>{},
        ),
        Provider.openrouter => (Uri.parse('https://openrouter.ai/api/v1/models'), {'authorization': 'Bearer $key'}),
        Provider.ollama => (Uri.parse(u('/api/tags')), <String, String>{}),
        Provider.custom => (Uri.parse(u('/models')), key.isEmpty ? <String, String>{} : {'authorization': 'Bearer $key'}),
      };
      final r = await http.get(uri, headers: h).timeout(const Duration(seconds: 20));
      if (r.statusCode >= 400)
        throw AiError('${p.label} answered ${r.statusCode}. Check the key${p.hasUrl ? ' and address' : ''}.');
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final List<String> ids = switch (p) {
        Provider.gemini => [
          for (final m in (j['models'] as List? ?? const []))
            if ((m['supportedGenerationMethods'] as List? ?? const []).contains('generateContent'))
              '${m['name']}'.replaceFirst('models/', ''),
        ],
        Provider.ollama => [for (final m in (j['models'] as List? ?? const [])) '${m['name']}'],
        _ => [for (final m in (j['data'] as List? ?? const [])) '${m['id']}'],
      };
      ids.sort();
      return ids;
    } on SocketException {
      throw AiError(
        p == Provider.ollama ? 'Ollama is not running. Start it, or install it from ollama.com.' : "Couldn't reach ${p.label}.",
      );
    }
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
If the fix is a change to their code or config, explain exactly what to change in "cause" and leave "steps" empty. Never edit a file with a command (no echo, >>, sed, tee): appending to pubspec.yaml or any YAML file breaks it.
Write for a developer: short, specific, no filler.
Answer with JSON only: {"summary": string, "cause": string, "steps": [{"title": string, "command": string, "why": string}]}.''';

  Future<AiAnswer> explain({required List<LogLine> log, required String projectPath, String? flutterVersion}) async {
    if (!connected) throw AiError('Connect an AI model in Settings first.');
    final tail = log.length > 160 ? log.sublist(log.length - 160) : log;
    String pubspec = '';
    try {
      pubspec = await File('$projectPath/pubspec.yaml').readAsString();
    } catch (_) {}
    final user =
        '''
OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}
Flutter: ${flutterVersion ?? 'unknown'}

pubspec.yaml:
$pubspec

Log (last ${tail.length} lines):
${tail.map((l) => l.text).join('\n')}''';

    try {
      final text = switch (provider) {
        Provider.anthropic => await _anthropic(user),
        Provider.gemini => await _gemini(user),
        Provider.ollama => await _ollama(user),
        _ => await _openaiStyle(user),
      };
      return _parse(text);
    } on SocketException {
      throw AiError(provider == Provider.ollama ? 'Ollama is not running.' : "Couldn't reach ${provider.label}.");
    }
  }

  AiAnswer _parse(String text) {
    // Local models sometimes wrap the JSON in prose or a code fence.
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start)
      throw AiError('The model didn\'t answer in the expected format. Try again or pick another model.');
    final j = jsonDecode(text.substring(start, end + 1)) as Map;
    return AiAnswer('${j['summary'] ?? ''}', '${j['cause'] ?? ''}', [
      for (final s in (j['steps'] as List? ?? const []))
        if (s is Map) (title: '${s['title']}', command: '${s['command']}', why: '${s['why'] ?? ''}'),
    ]);
  }

  Never _fail(http.Response r) {
    String msg = '';
    try {
      final b = jsonDecode(utf8.decode(r.bodyBytes));
      msg = '${b['error'] is Map ? b['error']['message'] : b['error'] ?? b['message'] ?? ''}';
    } catch (_) {}
    if (r.statusCode == 401 || r.statusCode == 403) throw AiError('The key was refused. Check it in Settings.');
    if (r.statusCode == 429) throw AiError('Rate limited. Try again in a moment.');
    throw AiError('${provider.label} error ${r.statusCode}${msg.isEmpty ? '' : ': $msg'}');
  }

  /// Claude, over the Messages API, with structured output.
  Future<String> _anthropic(String user) async {
    final r = await http
        .post(
          Uri.parse('https://api.anthropic.com/v1/messages'),
          headers: {
            'content-type': 'application/json',
            'x-api-key': _keys[Provider.anthropic]!,
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
    if (r.statusCode >= 400) _fail(r);
    final b = jsonDecode(utf8.decode(r.bodyBytes));
    if (b['stop_reason'] == 'refusal') throw AiError('The model declined to answer this one.');
    return [
      for (final c in (b['content'] as List? ?? const []))
        if (c is Map && c['type'] == 'text') '${c['text']}',
    ].join();
  }

  /// OpenAI, OpenRouter and any OpenAI-compatible server: chat completions,
  /// asking for JSON.
  Future<String> _openaiStyle(String user) async {
    final (url, key) = switch (provider) {
      Provider.openai => ('https://api.openai.com/v1/chat/completions', _keys[Provider.openai] ?? ''),
      Provider.openrouter => ('https://openrouter.ai/api/v1/chat/completions', _keys[Provider.openrouter] ?? ''),
      _ => (_url('/chat/completions'), _keys[Provider.custom] ?? ''),
    };
    final r = await http
        .post(
          Uri.parse(url),
          headers: {
            'content-type': 'application/json',
            if (key.isNotEmpty) 'authorization': 'Bearer $key',
            if (provider == Provider.openrouter) 'X-Title': 'Deckhand',
          },
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'system', 'content': _system},
              {'role': 'user', 'content': user},
            ],
            'response_format': provider == Provider.custom
                ? {'type': 'json_object'}
                : {
                    'type': 'json_schema',
                    'json_schema': {'name': 'fix', 'strict': true, 'schema': _schema},
                  },
          }),
        )
        .timeout(const Duration(minutes: 4));
    if (r.statusCode >= 400) _fail(r);
    final b = jsonDecode(utf8.decode(r.bodyBytes));
    return '${b['choices']?[0]?['message']?['content'] ?? ''}';
  }

  /// Gemini's generateContent with a JSON response.
  Future<String> _gemini(String user) async {
    final r = await http
        .post(
          Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=${_keys[Provider.gemini]}',
          ),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'systemInstruction': {
              'parts': [
                {'text': _system},
              ],
            },
            'contents': [
              {
                'role': 'user',
                'parts': [
                  {'text': user},
                ],
              },
            ],
            'generationConfig': {'responseMimeType': 'application/json'},
          }),
        )
        .timeout(const Duration(minutes: 4));
    if (r.statusCode >= 400) _fail(r);
    final b = jsonDecode(utf8.decode(r.bodyBytes));
    final parts = b['candidates']?[0]?['content']?['parts'] as List? ?? const [];
    return parts.map((p) => '${p['text'] ?? ''}').join();
  }

  /// A model running in Ollama on this computer, held to the schema.
  Future<String> _ollama(String user) async {
    final r = await http
        .post(
          Uri.parse(_url('/api/chat')),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'model': model,
            'stream': false,
            'format': _schema,
            'messages': [
              {'role': 'system', 'content': _system},
              {'role': 'user', 'content': user},
            ],
          }),
        )
        // A local model on a laptop can be slow.
        .timeout(const Duration(minutes: 10));
    if (r.statusCode >= 400) _fail(r);
    final b = jsonDecode(utf8.decode(r.bodyBytes));
    return '${b['message']?['content'] ?? ''}';
  }

  // ---- Chat ----------------------------------------------------------------

  /// A free conversation, streamed: yields the answer's text as it arrives.
  /// Cancelling the subscription closes the connection.
  Stream<String> chat({required String system, required List<({bool user, String text})> messages}) async* {
    if (!connected) throw AiError('Connect an AI model in Settings first.');
    final client = http.Client();
    try {
      final req = _chatRequest(system, messages);
      final http.StreamedResponse res;
      try {
        res = await client.send(req).timeout(const Duration(minutes: 2));
      } on SocketException {
        throw AiError(provider == Provider.ollama ? 'Ollama is not running.' : "Couldn't reach ${provider.label}.");
      }
      if (res.statusCode >= 400) _fail(await http.Response.fromStream(res));
      final lines = res.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        final t = _chatDelta(line);
        if (t != null && t.isNotEmpty) yield t;
      }
    } finally {
      client.close();
    }
  }

  http.Request _chatRequest(String system, List<({bool user, String text})> messages) {
    http.Request post(String url, Map<String, String> headers, Object body) => http.Request('POST', Uri.parse(url))
      ..headers.addAll({'content-type': 'application/json', ...headers})
      ..body = jsonEncode(body);
    final turns = [for (final m in messages) (role: m.user ? 'user' : 'assistant', text: m.text)];
    switch (provider) {
      case Provider.anthropic:
        return post(
          'https://api.anthropic.com/v1/messages',
          {
            'x-api-key': _keys[Provider.anthropic]!,
            'anthropic-version': '2026-10-21',
            'anthropic-beta': 'server-side-fallback-2026-07-01',
          },
          {
            'model': model,
            'max_tokens': 16000,
            'stream': true,
            'fallbacks': 'default',
            'system': system,
            'thinking': {'type': 'adaptive'},
            'output_config': {'effort': 'medium'},
            'messages': [
              for (final t in turns) {'role': t.role, 'content': t.text},
            ],
          },
        );
      case Provider.gemini:
        return post(
          'https://generativelanguage.googleapis.com/v1beta/models/$model:streamGenerateContent?alt=sse&key=${_keys[Provider.gemini]}',
          const {},
          {
            'systemInstruction': {
              'parts': [
                {'text': system},
              ],
            },
            'contents': [
              for (final t in turns)
                {
                  'role': t.role == 'user' ? 'user' : 'model',
                  'parts': [
                    {'text': t.text},
                  ],
                },
            ],
          },
        );
      case Provider.ollama:
        return post(_url('/api/chat'), const {}, {
          'model': model,
          'stream': true,
          'messages': [
            {'role': 'system', 'content': system},
            for (final t in turns) {'role': t.role, 'content': t.text},
          ],
        });
      case Provider.openai:
      case Provider.openrouter:
      case Provider.custom:
        final (url, key) = switch (provider) {
          Provider.openai => ('https://api.openai.com/v1/chat/completions', _keys[Provider.openai] ?? ''),
          Provider.openrouter => ('https://openrouter.ai/api/v1/chat/completions', _keys[Provider.openrouter] ?? ''),
          _ => (_url('/chat/completions'), _keys[Provider.custom] ?? ''),
        };
        return post(
          url,
          {if (key.isNotEmpty) 'authorization': 'Bearer $key', if (provider == Provider.openrouter) 'X-Title': 'Deckhand'},
          {
            'model': model,
            'stream': true,
            'messages': [
              {'role': 'system', 'content': system},
              for (final t in turns) {'role': t.role, 'content': t.text},
            ],
          },
        );
    }
  }

  /// The text in one line of a streamed answer, if it has any.
  String? _chatDelta(String line) {
    if (provider == Provider.ollama) {
      if (line.trim().isEmpty) return null;
      final j = jsonDecode(line);
      if (j['error'] != null) throw AiError('${j['error']}');
      return '${j['message']?['content'] ?? ''}';
    }
    if (!line.startsWith('data:')) return null;
    final data = line.substring(5).trim();
    if (data.isEmpty || data == '[DONE]') return null;
    final j = jsonDecode(data);
    if (j is! Map) return null;
    switch (provider) {
      case Provider.anthropic:
        if (j['type'] == 'error') throw AiError('${j['error']?['message'] ?? 'The answer stopped with an error.'}');
        if (j['type'] == 'message_delta' && j['delta']?['stop_reason'] == 'refusal') {
          throw AiError('The model declined to answer this one.');
        }
        if (j['type'] == 'content_block_delta' && j['delta']?['type'] == 'text_delta') return '${j['delta']['text']}';
        return null;
      case Provider.gemini:
        final parts = j['candidates']?[0]?['content']?['parts'] as List? ?? const [];
        return parts.map((p) => '${p['text'] ?? ''}').join();
      default:
        if (j['error'] != null) throw AiError('${j['error'] is Map ? j['error']['message'] : j['error']}');
        return '${j['choices']?[0]?['delta']?['content'] ?? ''}';
    }
  }
}
