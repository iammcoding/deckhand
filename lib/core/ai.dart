import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_tools.dart';

/// One step: what the model said, and the tools it wants run. [native] is
/// false when it wrote the calls out as text instead of really making them.
class AiTurn {
  final String text;
  final List<AiToolCall> calls;
  final bool native;
  const AiTurn(this.text, this.calls, {required this.native});
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

/// The model you connect, used by Ask AI (through tools, see AiAgent) and chat.
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

  // ---- Tool use ---------------------------------------------------------------

  /// One step of a conversation with tools: what the model said and the calls
  /// it wants made. [messages] is in this provider's own format, and grows.
  Future<AiTurn> turn(String system, List<Map<String, dynamic>> messages, List<AiTool> tools) async {
    if (!connected) throw AiError('Connect an AI model in Settings first.');
    final names = {for (final t in tools) t.name};
    try {
      final (text, calls, raw) = switch (provider) {
        Provider.anthropic => await _anthropicTurn(system, messages, tools),
        Provider.gemini => await _geminiTurn(system, messages, tools),
        Provider.ollama => await _ollamaTurn(system, messages, tools),
        _ => await _openaiTurn(system, messages, tools),
      };
      messages.add(raw);
      if (calls.isNotEmpty) return AiTurn(text, calls, native: true);
      // Some models write the call out instead of making it.
      final written = ProjectTools.callsInText(text, names);
      return AiTurn(written.isEmpty ? text : '', written, native: false);
    } on SocketException {
      throw AiError(provider == Provider.ollama ? 'Ollama is not running.' : "Couldn't reach ${provider.label}.");
    }
  }

  /// The first message of a conversation, in this provider's format.
  Map<String, dynamic> userMessage(String text) => provider == Provider.gemini
      ? {
          'role': 'user',
          'parts': [
            {'text': text},
          ],
        }
      : {'role': 'user', 'content': text};

  /// Tool answers, in this provider's format. Calls the model wrote as text
  /// have no native answer, so they go back as an ordinary message.
  List<Map<String, dynamic>> resultMessages(List<AiToolResult> results, {required bool native}) {
    if (!native) {
      return [
        userMessage([for (final r in results) 'Result of ${r.call.name}${r.error ? ' (failed)' : ''}:\n${r.text}'].join('\n\n')),
      ];
    }
    return switch (provider) {
      Provider.anthropic => [
        {
          'role': 'user',
          'content': [
            for (final r in results)
              {'type': 'tool_result', 'tool_use_id': r.call.id, 'content': r.text, if (r.error) 'is_error': true},
          ],
        },
      ],
      Provider.gemini => [
        {
          'role': 'user',
          'parts': [
            for (final r in results)
              {
                'functionResponse': {
                  'name': r.call.name,
                  'response': {r.error ? 'error' : 'result': r.text},
                },
              },
          ],
        },
      ],
      Provider.ollama => [
        for (final r in results) {'role': 'tool', 'tool_name': r.call.name, 'content': r.text},
      ],
      _ => [
        for (final r in results) {'role': 'tool', 'tool_call_id': r.call.id, 'content': r.text},
      ],
    };
  }

  Future<Map<String, dynamic>> _postJson(String url, Map<String, String> headers, Object body, Duration timeout) async {
    final r = await http
        .post(Uri.parse(url), headers: {'content-type': 'application/json', ...headers}, body: jsonEncode(body))
        .timeout(timeout);
    if (r.statusCode >= 400) _fail(r);
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(r.bodyBytes)) as Map);
  }

  static Map<String, dynamic> _asMap(Object? v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    if (v is String) {
      try {
        final j = jsonDecode(v);
        if (j is Map) return Map<String, dynamic>.from(j);
      } on FormatException {
        // Not usable: the tool reports what's missing, and the model retries.
      }
    }
    return {};
  }

  /// Claude. The assistant turn goes back exactly as it came.
  Future<(String, List<AiToolCall>, Map<String, dynamic>)> _anthropicTurn(
    String system,
    List<Map<String, dynamic>> messages,
    List<AiTool> tools,
  ) async {
    final b = await _postJson(
      'https://api.anthropic.com/v1/messages',
      {
        'x-api-key': _keys[Provider.anthropic]!,
        'anthropic-version': '2026-10-21',
        'anthropic-beta': 'server-side-fallback-2026-07-01',
      },
      {
        'model': model,
        'max_tokens': 16000,
        'fallbacks': 'default',
        'system': system,
        'output_config': {'effort': 'medium'},
        'tools': [
          for (final t in tools) {'name': t.name, 'description': t.description, 'input_schema': t.schema},
        ],
        'messages': messages,
      },
      const Duration(minutes: 4),
    );
    if (b['stop_reason'] == 'refusal') throw AiError('The model declined to answer this one.');
    final content = b['content'] as List? ?? const [];
    return (
      [
        for (final c in content)
          if (c is Map && c['type'] == 'text') '${c['text']}',
      ].join(),
      [
        for (final c in content)
          if (c is Map && c['type'] == 'tool_use') AiToolCall('${c['id']}', '${c['name']}', _asMap(c['input'])),
      ],
      <String, dynamic>{'role': 'assistant', 'content': content},
    );
  }

  /// OpenAI, OpenRouter and anything that speaks chat completions.
  Future<(String, List<AiToolCall>, Map<String, dynamic>)> _openaiTurn(
    String system,
    List<Map<String, dynamic>> messages,
    List<AiTool> tools,
  ) async {
    final (url, key) = switch (provider) {
      Provider.openai => ('https://api.openai.com/v1/chat/completions', _keys[Provider.openai] ?? ''),
      Provider.openrouter => ('https://openrouter.ai/api/v1/chat/completions', _keys[Provider.openrouter] ?? ''),
      _ => (_url('/chat/completions'), _keys[Provider.custom] ?? ''),
    };
    final b = await _postJson(
      url,
      {if (key.isNotEmpty) 'authorization': 'Bearer $key', if (provider == Provider.openrouter) 'X-Title': 'Deckhand'},
      {
        'model': model,
        'messages': [
          {'role': 'system', 'content': system},
          ...messages,
        ],
        'tools': [
          for (final t in tools)
            {
              'type': 'function',
              'function': {'name': t.name, 'description': t.description, 'parameters': t.schema},
            },
        ],
      },
      provider == Provider.custom ? const Duration(minutes: 10) : const Duration(minutes: 4),
    );
    final msg = _asMap((b['choices'] as List?)?.firstOrNull is Map ? (b['choices'] as List).first['message'] : null);
    return (
      '${msg['content'] ?? ''}',
      [
        for (final c in (msg['tool_calls'] as List? ?? const []))
          if (c is Map && c['function'] is Map)
            AiToolCall('${c['id']}', '${c['function']['name']}', _asMap(c['function']['arguments'])),
      ],
      msg.isEmpty ? <String, dynamic>{'role': 'assistant', 'content': ''} : msg,
    );
  }

  /// Gemini. Its content goes back as it came, which keeps its signatures.
  Future<(String, List<AiToolCall>, Map<String, dynamic>)> _geminiTurn(
    String system,
    List<Map<String, dynamic>> messages,
    List<AiTool> tools,
  ) async {
    final b = await _postJson(
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=${_keys[Provider.gemini]}',
      const {},
      {
        'systemInstruction': {
          'parts': [
            {'text': system},
          ],
        },
        'contents': messages,
        'tools': [
          {
            'functionDeclarations': [
              for (final t in tools) {'name': t.name, 'description': t.description, 'parameters': t.schema},
            ],
          },
        ],
      },
      const Duration(minutes: 4),
    );
    final content = _asMap((b['candidates'] as List?)?.firstOrNull is Map ? (b['candidates'] as List).first['content'] : null);
    final parts = content['parts'] as List? ?? const [];
    var n = 0;
    return (
      [
        for (final x in parts)
          if (x is Map && x['text'] != null) '${x['text']}',
      ].join(),
      [
        for (final x in parts)
          if (x is Map && x['functionCall'] is Map)
            AiToolCall('gemini-${n++}', '${x['functionCall']['name']}', _asMap(x['functionCall']['args'])),
      ],
      content.isEmpty
          ? <String, dynamic>{
              'role': 'model',
              'parts': [
                {'text': ''},
              ],
            }
          : {...content, 'role': 'model'},
    );
  }

  /// A local model in Ollama. It needs more room than Ollama's default to hold
  /// a file and the conversation; a laptop can be slow.
  Future<(String, List<AiToolCall>, Map<String, dynamic>)> _ollamaTurn(
    String system,
    List<Map<String, dynamic>> messages,
    List<AiTool> tools,
  ) async {
    final b = await _postJson(_url('/api/chat'), const {}, {
      'model': model,
      'stream': false,
      'options': {'num_ctx': 8192},
      'messages': [
        {'role': 'system', 'content': system},
        ...messages,
      ],
      'tools': [
        for (final t in tools)
          {
            'type': 'function',
            'function': {'name': t.name, 'description': t.description, 'parameters': t.schema},
          },
      ],
    }, const Duration(minutes: 10));
    final msg = _asMap(b['message']);
    var n = 0;
    return (
      '${msg['content'] ?? ''}',
      [
        for (final c in (msg['tool_calls'] as List? ?? const []))
          if (c is Map && c['function'] is Map)
            AiToolCall('ollama-${n++}', '${c['function']['name']}', _asMap(c['function']['arguments'])),
      ],
      msg.isEmpty ? <String, dynamic>{'role': 'assistant', 'content': ''} : msg,
    );
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
