import 'dart:io';

import 'package:deckhand/core/ai.dart';
import 'package:deckhand/core/ai_agent.dart';
import 'package:deckhand/core/ai_tools.dart';
import 'package:deckhand/core/sessions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late String root;
  late ProjectTools tools;

  void write(String rel, String text) {
    File(p.join(root, rel))
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  String read(String rel) => File(p.join(root, rel)).readAsStringSync();

  Future<AiToolResult> call(String name, Map<String, dynamic> args) => tools.run(AiToolCall('1', name, args));

  setUp(() {
    tmp = Directory(Directory.systemTemp.createTempSync('deckhand_tools').resolveSymbolicLinksSync());
    root = p.join(tmp.path, 'app');
    tools = ProjectTools(root);
    write('pubspec.yaml', 'name: app\n\nflutter:\n  uses-material-design: true\n');
    write('lib/main.dart', 'void main() {}\n');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('reading', () {
    test('a file', () async {
      expect((await call('read_file', {'path': 'pubspec.yaml'})).text, startsWith('1| name: app'));
    });

    test('part of a file', () async {
      write('a.txt', 'one\ntwo\nthree\nfour');
      final r = await call('read_file', {'path': 'a.txt', 'first_line': 2, 'last_line': 3});
      expect(r.text, startsWith('2| two\n3| three'));
      expect(r.text, contains('lines 2 to 3 of 4'));
    });

    test('nonsense line numbers do not crash', () async {
      write('a.txt', 'one\ntwo');
      final r = await call('read_file', {'path': 'a.txt', 'first_line': 99, 'last_line': -3});
      expect(r.error, isFalse);
    });

    test('a long file is cut, and says so', () async {
      write('long.txt', List.generate(20000, (i) => 'line $i').join('\n'));
      final r = await call('read_file', {'path': 'long.txt'});
      expect(r.text.length, lessThan(ProjectTools.maxRead + 200));
      expect(r.text, contains('first_line'));
    });

    test('binary and missing files are refused with a reason', () async {
      File(p.join(root, 'a.png')).writeAsBytesSync([1, 0, 2]);
      expect((await call('read_file', {'path': 'a.png'})).error, isTrue);
      expect((await call('read_file', {'path': 'nope.dart'})).text, contains('No such file'));
    });

    test('a missing argument is an error for the model, not a crash', () async {
      expect((await call('read_file', {})).error, isTrue);
      expect((await call('edit_file', {'path': 'pubspec.yaml'})).error, isTrue);
    });

    test('search finds it, with file and line', () async {
      final r = await call('search', {'text': 'MATERIAL'});
      expect(r.text, contains('pubspec.yaml:4'));
    });

    test('listing', () async {
      final r = await call('list_files', {});
      expect(r.text, contains('lib/'));
      expect(r.text, contains('pubspec.yaml'));
    });
  });

  group('editing', () {
    test('exact text, once', () async {
      final r = await call('edit_file', {
        'path': 'lib/main.dart',
        'old_text': 'void main() {}',
        'new_text': 'void main() { run(); }',
      });
      expect(r.error, isFalse);
      expect(read('lib/main.dart'), 'void main() { run(); }\n');
    });

    test('by line number: the error said line 96', () async {
      write('pubspec.yaml', 'name: app\nflutter:\n  a: 1\nflutter:\n  generate: true\n');
      final r = await call('replace_lines', {'path': 'pubspec.yaml', 'first_line': 4, 'last_line': 5, 'new_text': ''});
      expect(r.error, isFalse);
      expect(read('pubspec.yaml'), 'name: app\nflutter:\n  a: 1\n');
    });

    test('by line number: an impossible range changes nothing', () async {
      final r = await call('replace_lines', {'path': 'lib/main.dart', 'first_line': 5, 'last_line': 9, 'new_text': 'x'});
      expect(r.error, isTrue);
      expect(read('lib/main.dart'), 'void main() {}\n');
    });

    test('by line number: refused if the result would break the config', () async {
      final r = await call('replace_lines', {'path': 'pubspec.yaml', 'first_line': 1, 'last_line': 1, 'new_text': '{bad'});
      expect(r.error, isTrue);
      expect(read('pubspec.yaml'), startsWith('name: app'));
    });

    test('line numbers copied from read_file into old_text still match', () async {
      final r = await call('edit_file', {
        'path': 'lib/main.dart',
        'old_text': '1| void main() {}',
        'new_text': '1| void main() { run(); }',
      });
      expect(r.error, isFalse);
      expect(read('lib/main.dart'), 'void main() { run(); }\n');
    });

    test('text that is not there changes nothing', () async {
      final r = await call('edit_file', {'path': 'lib/main.dart', 'old_text': 'nope', 'new_text': 'x'});
      expect(r.error, isTrue);
      expect(read('lib/main.dart'), 'void main() {}\n');
    });

    test('text that appears twice changes nothing: the linkdate case', () async {
      write('pubspec.yaml', 'name: app\nflutter:\n  a: 1\nflutter:\n  generate: true\n');
      final r = await call('edit_file', {'path': 'pubspec.yaml', 'old_text': 'flutter:', 'new_text': ''});
      expect(r.text, contains('2 times'));
      final ok = await call('edit_file', {'path': 'pubspec.yaml', 'old_text': 'flutter:\n  generate: true\n', 'new_text': ''});
      expect(ok.error, isFalse);
      expect(read('pubspec.yaml'), 'name: app\nflutter:\n  a: 1\n');
    });

    test('dollar signs in the new text are kept literally', () async {
      await call('edit_file', {'path': 'lib/main.dart', 'old_text': 'void main() {}', 'new_text': r"var a = '$b $1';"});
      expect(read('lib/main.dart'), contains(r"var a = '$b $1';"));
    });

    test('Windows line endings still match', () async {
      write('a.txt', 'one\r\ntwo\r\n');
      final r = await call('edit_file', {'path': 'a.txt', 'old_text': 'one\ntwo', 'new_text': 'x\ny'});
      expect(r.error, isFalse);
      expect(read('a.txt'), 'x\r\ny\r\n');
    });

    test('an edit that would break a config file is refused, and nothing is written', () async {
      final r = await call('edit_file', {'path': 'pubspec.yaml', 'old_text': 'name: app', 'new_text': 'name: app\nname: other'});
      expect(r.error, isTrue);
      expect(r.text, contains('Not saved'));
      expect(read('pubspec.yaml'), startsWith('name: app\n\nflutter'));
    });

    test('an already broken config can still be repaired step by step', () async {
      write('pubspec.yaml', 'name: app\nflutter:\n  a: 1\nflutter:\n  b: 2\n');
      final r = await call('edit_file', {'path': 'pubspec.yaml', 'old_text': 'flutter:\n  b: 2\n', 'new_text': '  b: 2\n'});
      expect(r.error, isFalse);
    });

    test('the empty file the model made for a folder is refused', () async {
      expect((await call('create_file', {'path': 'lib/l10n', 'content': ''})).error, isTrue);
      expect(File(p.join(root, 'lib/l10n')).existsSync(), isFalse);
    });

    test('a broken new config file is refused', () async {
      expect((await call('create_file', {'path': 'lib/l10n/en.arb', 'content': '{bad'})).error, isTrue);
    });

    test('a new file, in a new folder; but never over an existing one', () async {
      expect((await call('create_file', {'path': 'lib/l10n/en.arb', 'content': '{}'})).error, isFalse);
      expect(read('lib/l10n/en.arb'), '{}');
      expect((await call('create_file', {'path': 'pubspec.yaml', 'content': 'x'})).error, isTrue);
      expect(read('pubspec.yaml'), startsWith('name: app'));
    });
  });

  group('the walls', () {
    late File outside;
    setUp(() {
      outside = File(p.join(tmp.path, 'outside.txt'))..writeAsStringSync('private');
    });

    for (final path in ['../outside.txt', 'lib/../../outside.txt']) {
      test('no way out: $path', () async {
        expect((await call('read_file', {'path': path})).text, isNot(contains('private')));
        await call('edit_file', {'path': path, 'old_text': 'private', 'new_text': 'x'});
        expect(outside.readAsStringSync(), 'private');
      });
    }

    test('no way out by absolute path', () async {
      expect((await call('read_file', {'path': outside.path})).error, isTrue);
      expect((await call('read_file', {'path': '/etc/passwd'})).error, isTrue);
      expect((await call('create_file', {'path': p.join(tmp.path, 'new.txt'), 'content': 'x'})).error, isTrue);
      expect(File(p.join(tmp.path, 'new.txt')).existsSync(), isFalse);
    });

    test('no way out through a link', () async {
      Link(p.join(root, 'sneaky.txt')).createSync(outside.path);
      Link(p.join(root, 'sneaky_dir')).createSync(tmp.path);
      expect((await call('read_file', {'path': 'sneaky.txt'})).error, isTrue);
      expect((await call('read_file', {'path': 'sneaky_dir/outside.txt'})).error, isTrue);
      expect((await call('edit_file', {'path': 'sneaky.txt', 'old_text': 'private', 'new_text': 'x'})).error, isTrue);
      expect((await call('create_file', {'path': 'sneaky_dir/made.txt', 'content': 'x'})).error, isTrue);
      expect(outside.readAsStringSync(), 'private');
      expect(File(p.join(tmp.path, 'made.txt')).existsSync(), isFalse);
    });

    for (final name in [
      '.env', '.env.production', 'android/key.properties', 'android/app/upload.jks', 'android/local.properties', //
      'ios/AuthKey_ABC.p8', 'android/app/google-services.json', 'ios/Runner/GoogleService-Info.plist',
    ]) {
      test('secrets stay secret: $name', () async {
        write(name, 'SECRET_VALUE');
        expect((await call('read_file', {'path': name})).text, isNot(contains('SECRET_VALUE')));
        expect((await call('search', {'text': 'SECRET_VALUE'})).text, 'Nothing found.');
        expect((await call('list_files', {'path': p.dirname(name)})).text, isNot(contains(p.basename(name))));
        await call('edit_file', {'path': name, 'old_text': 'SECRET_VALUE', 'new_text': 'x'});
        expect(read(name), 'SECRET_VALUE');
      });
    }

    test('git and build output are off limits', () async {
      write('.git/config', 'token');
      write('build/out.txt', 'x');
      expect((await call('read_file', {'path': '.git/config'})).error, isTrue);
      expect((await call('edit_file', {'path': 'build/out.txt', 'old_text': 'x', 'new_text': 'y'})).error, isTrue);
    });

    test('an unknown check or tool does not run anything', () async {
      expect((await call('run_check', {'check': 'rm -rf /'})).error, isTrue);
      expect((await call('shell', {'command': 'rm -rf /'})).error, isTrue);
    });
  });

  group('calls a model writes as text', () {
    const names = {'read_file', 'edit_file'};

    test('what your local model really sent', () {
      final c = ProjectTools.callsInText('{"name": "read_file", "arguments": {"path": "pubspec.yaml"}}', names);
      expect(c.single.name, 'read_file');
      expect(c.single.args['path'], 'pubspec.yaml');
    });

    test('in a code fence or tags, or with words around it', () {
      expect(ProjectTools.callsInText('```json\n{"name":"read_file","arguments":{"path":"a"}}\n```', names), hasLength(1));
      expect(
        ProjectTools.callsInText('<tool_call>{"name":"read_file","arguments":{"path":"a"}}</tool_call>', names),
        hasLength(1),
      );
      expect(ProjectTools.callsInText('Let me look. {"name":"read_file","arguments":{"path":"a"}}', names), hasLength(1));
    });

    test('braces inside strings do not confuse it', () {
      final c = ProjectTools.callsInText(
        r'{"name":"edit_file","arguments":{"path":"a","old_text":"void main() {","new_text":"say \"}\""}}',
        names,
      );
      expect(c.single.args['old_text'], 'void main() {');
    });

    test('a normal answer, or JSON that is not a call, is not a call', () {
      expect(ProjectTools.callsInText('The cause is a duplicate key in pubspec.yaml.', names), isEmpty);
      expect(ProjectTools.callsInText('Add {"name": "my_app"} to it', names), isEmpty);
      expect(ProjectTools.callsInText('{"name":"delete_everything","arguments":{}}', names), isEmpty);
      expect(ProjectTools.callsInText('{broken', names), isEmpty);
    });
  });

  group('the loop', () {
    final log = [LogLine('Duplicate mapping key', LogLevel.error)];

    /// A pretend model: gives each turn in order, recording what it was offered.
    AiStep scripted(List<AiTurn> turns, {List<List<AiTool>>? offered}) {
      var i = 0;
      return (system, messages, tools) async {
        offered?.add(tools);
        messages.add({'role': 'assistant', 'content': 'turn $i'});
        return turns[i++];
      };
    }

    test('reads, edits, then answers', () async {
      write('pubspec.yaml', 'name: app\nflutter:\n  a: 1\nflutter:\n  generate: true\n');
      final steps = <String>[];
      final agent = AiAgent(
        root,
        canEdit: true,
        onStep: steps.add,
        step: scripted([
          const AiTurn('', [
            AiToolCall('1', 'read_file', {'path': 'pubspec.yaml'}),
          ], native: true),
          const AiTurn('', [
            AiToolCall('2', 'edit_file', {'path': 'pubspec.yaml', 'old_text': 'flutter:\n  generate: true\n', 'new_text': ''}),
          ], native: true),
          const AiTurn('There was a second flutter section.', [], native: true),
        ]),
      );
      expect(await agent.run(log), 'There was a second flutter section.');
      expect(read('pubspec.yaml'), 'name: app\nflutter:\n  a: 1\n');
      expect(steps, ['read pubspec.yaml', 'edited pubspec.yaml']);
    });

    test('Ask AI cannot edit, even if the model tries', () async {
      final offered = <List<AiTool>>[];
      final agent = AiAgent(
        root,
        canEdit: false,
        step: scripted([
          const AiTurn('', [
            AiToolCall('1', 'edit_file', {'path': 'lib/main.dart', 'old_text': 'void', 'new_text': 'int'}),
          ], native: true),
          const AiTurn('Change void to int.', [], native: true),
        ], offered: offered),
      );
      await agent.run(log);
      expect(read('lib/main.dart'), 'void main() {}\n');
      expect(offered.first.map((t) => t.name), isNot(contains('edit_file')));
      expect(offered.first.map((t) => t.name), isNot(contains('create_file')));
    });

    test('a model going in circles is stopped', () async {
      final agent = AiAgent(
        root,
        canEdit: false,
        step: (s, m, t) async => const AiTurn('', [
          AiToolCall('1', 'read_file', {'path': 'pubspec.yaml'}),
        ], native: false),
      );
      Ai.instance.provider = Provider.ollama;
      final steps = await agent.run(log);
      expect(steps, contains("didn't finish"));
    });

    test('Stop stops it, and nothing more runs', () async {
      late AiAgent agent;
      var turns = 0;
      agent = AiAgent(
        root,
        canEdit: true,
        step: (s, m, t) async {
          turns++;
          agent.stop();
          return const AiTurn('', [
            AiToolCall('1', 'edit_file', {'path': 'lib/main.dart', 'old_text': 'void', 'new_text': 'int'}),
          ], native: true);
        },
      );
      await expectLater(agent.run(log), throwsA(isA<AiStopped>()));
      expect(turns, 1);
      expect(read('lib/main.dart'), 'void main() {}\n');
    });

    test('answering without looking gets sent back to look, once', () async {
      final sent = <String>[];
      var i = 0;
      final agent = AiAgent(
        root,
        canEdit: false,
        step: (s, messages, t) async {
          sent.add('${messages.last['content']}');
          return switch (i++) {
            0 => const AiTurn('Probably a duplicate key somewhere.', [], native: true),
            1 => const AiTurn('', [
              AiToolCall('1', 'read_file', {'path': 'pubspec.yaml'}),
            ], native: true),
            _ => const AiTurn('Line 3 of pubspec.yaml.', [], native: true),
          };
        },
      );
      expect(await agent.run(log), 'Line 3 of pubspec.yaml.');
      expect(sent[1], contains('read_file'));
    });

    test('an empty answer says so rather than showing nothing', () async {
      final agent = AiAgent(root, canEdit: false, step: scripted([const AiTurn('  ', [], native: true)]));
      expect(await agent.run(log), contains("didn't give an answer"));
    });
  });

  group('tool answers go back in each provider\'s own format', () {
    const results = [AiToolResult(AiToolCall('id1', 'read_file', {}), 'body')];

    tearDown(() => Ai.instance.provider = Provider.anthropic);

    test('Claude', () {
      Ai.instance.provider = Provider.anthropic;
      final m = Ai.instance.resultMessages(results, native: true).single;
      expect(m['role'], 'user');
      expect((m['content'] as List).single, {'type': 'tool_result', 'tool_use_id': 'id1', 'content': 'body'});
    });

    test('OpenAI style', () {
      Ai.instance.provider = Provider.openai;
      expect(Ai.instance.resultMessages(results, native: true).single, {
        'role': 'tool',
        'tool_call_id': 'id1',
        'content': 'body',
      });
    });

    test('Gemini', () {
      Ai.instance.provider = Provider.gemini;
      final part = (Ai.instance.resultMessages(results, native: true).single['parts'] as List).single as Map;
      expect(part['functionResponse']['name'], 'read_file');
    });

    test('Ollama', () {
      Ai.instance.provider = Provider.ollama;
      expect(Ai.instance.resultMessages(results, native: true).single, {
        'role': 'tool',
        'tool_name': 'read_file',
        'content': 'body',
      });
    });

    test('a call written as text is answered as an ordinary message', () {
      Ai.instance.provider = Provider.ollama;
      final m = Ai.instance.resultMessages(results, native: false).single;
      expect(m['role'], 'user');
      expect(m['content'], contains('body'));
    });
  });
}
