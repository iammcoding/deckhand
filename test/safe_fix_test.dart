import 'dart:io';

import 'package:deckhand/core/safe_fix.dart';
import 'package:deckhand/core/shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _pubspec = 'name: app\n\nflutter:\n  uses-material-design: true\n';

void main() {
  _verdicts();

  late Directory tmp;
  late String root;
  final safe = SafeFixes.instance;

  void write(String rel, String text) {
    File(p.join(root, rel))
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  String read(String rel) => File(p.join(root, rel)).readAsStringSync();
  bool has(String rel) => File(p.join(root, rel)).existsSync();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('deckhand_safe');
    root = p.join(tmp.path, 'app');
    SafeFixes.storeOverride = p.join(tmp.path, 'store');
    write('pubspec.yaml', _pubspec);
    write('lib/main.dart', 'void main() {}\n');
  });

  tearDown(() {
    SafeFixes.storeOverride = null;
    tmp.deleteSync(recursive: true);
  });

  /// A fix, without the analyzer: that needs a Flutter SDK.
  Future<SafeFix> guard(Future<int?> Function() action) => safe.guard('test', root, action, checkAnalyzer: false);

  group('a fix that breaks the project is put back at once', () {
    test('the linkdate accident: a real shell command adds a second flutter:', () async {
      final fix = await guard(ShellJob("echo 'flutter:\n  generate: true' >> pubspec.yaml", cwd: root).start);
      expect(read('pubspec.yaml'), _pubspec);
      expect(fix.state, SafeFixState.restored);
      expect(fix.broke, contains('pubspec.yaml'));
      expect(fix.broke, contains('Duplicate mapping key'));
    });

    test('pubspec deleted', () async {
      final fix = await guard(() async {
        File(p.join(root, 'pubspec.yaml')).deleteSync();
        return 0;
      });
      expect(fix.state, SafeFixState.restored);
      expect(read('pubspec.yaml'), _pubspec);
    });

    test('pubspec no longer has a name', () async {
      final fix = await guard(() async {
        write('pubspec.yaml', 'flutter:\n  generate: true\n');
        return 0;
      });
      expect(fix.state, SafeFixState.restored);
      expect(read('pubspec.yaml'), _pubspec);
    });

    test('other config: a broken translation file, and new files go too', () async {
      write('lib/l10n/en.arb', '{"a": "b"}');
      final fix = await guard(() async {
        write('lib/l10n/en.arb', '{"a": ');
        write('lib/new.dart', 'class A {}');
        return 0;
      });
      expect(fix.state, SafeFixState.restored);
      expect(read('lib/l10n/en.arb'), '{"a": "b"}');
      expect(has('lib/new.dart'), isFalse);
    });

    test('what was replaced is kept, so nothing is lost', () async {
      final fix = await guard(() async {
        write('pubspec.yaml', '{broken');
        return 0;
      });
      expect(File(p.join(fix.snapshot!.dir, 'replaced', 'pubspec.yaml')).readAsStringSync(), '{broken');
    });

    test('a file that was already broken is not blamed on the fix', () async {
      write('settings.json', '{not json');
      final fix = await guard(() async {
        write('settings.json', '{still not json');
        return 0;
      });
      expect(fix.state, SafeFixState.kept);
      expect(read('settings.json'), '{still not json');
    });
  });

  group('a fix that works is kept, with an undo', () {
    test('a real change stays, and undo puts everything back', () async {
      write('lib/old.dart', 'class Old {}');
      final fix = await guard(() async {
        write('lib/main.dart', 'void main() { print(1); }\n');
        write('lib/new.dart', 'class New {}');
        File(p.join(root, 'lib/old.dart')).deleteSync();
        return 0;
      });
      expect(fix.state, SafeFixState.kept);
      expect(fix.canUndo, isTrue);
      expect(fix.changes.modified, ['lib/main.dart']);
      expect(fix.changes.added, ['lib/new.dart']);
      expect(fix.changes.removed, ['lib/old.dart']);
      expect(read('lib/main.dart'), contains('print'));

      safe.undo(fix);
      expect(fix.state, SafeFixState.undone);
      expect(read('lib/main.dart'), 'void main() {}\n');
      expect(has('lib/new.dart'), isFalse);
      expect(read('lib/old.dart'), 'class Old {}');
      expect(fix.canUndo, isFalse, reason: 'once only');
    });

    test('nothing changed: nothing to undo', () async {
      final fix = await guard(() async => 0);
      expect(fix.changes.isEmpty, isTrue);
      expect(fix.canUndo, isFalse);
    });

    test('a file rewritten with the same content has not changed', () async {
      final fix = await guard(() async {
        await Future.delayed(const Duration(milliseconds: 20));
        write('pubspec.yaml', _pubspec);
        return 0;
      });
      expect(fix.changes.isEmpty, isTrue);
    });

    test('a failed command that changed files can still be undone', () async {
      final fix = await guard(() async {
        write('lib/main.dart', 'half done');
        return 1;
      });
      expect(fix.exitCode, 1);
      expect(fix.canUndo, isTrue);
    });

    test('an action that throws is reported, and its changes can be undone', () async {
      final fix = await guard(() async {
        write('lib/main.dart', 'half done');
        throw StateError('boom');
      });
      expect(fix.error, contains('boom'));
      safe.undo(fix);
      expect(read('lib/main.dart'), 'void main() {}\n');
    });
  });

  group('what the copy covers', () {
    test('build output and caches are ignored; source folders named build are not', () async {
      write('build/out.txt', 'old');
      write('.dart_tool/x.json', '{}');
      write('android/app/build/y.txt', 'old');
      write('lib/build/widgets.dart', 'class B {}');
      final fix = await guard(() async {
        write('build/out.txt', 'new');
        write('.dart_tool/x.json', '{"a":1}');
        write('android/app/build/y.txt', 'new');
        write('lib/build/widgets.dart', 'class C {}');
        return 0;
      });
      expect(fix.changes.all, ['lib/build/widgets.dart']);
    });

    test('.git is never touched by an undo', () async {
      write('.git/HEAD', 'ref: main');
      final fix = await guard(() async {
        write('.git/HEAD', 'ref: other');
        write('lib/main.dart', 'x');
        return 0;
      });
      safe.undo(fix);
      expect(read('.git/HEAD'), 'ref: other');
    });

    test('a link is left alone, and what it points at survives', () async {
      final target = Directory(p.join(tmp.path, 'sdk'))..createSync();
      File(p.join(target.path, 'bin')).writeAsStringSync('flutter');
      Link(p.join(root, 'sdk_link')).createSync(target.path);
      final fix = await guard(() async {
        write('lib/main.dart', 'x');
        return 0;
      });
      safe.undo(fix);
      expect(File(p.join(target.path, 'bin')).readAsStringSync(), 'flutter');
      expect(Link(p.join(root, 'sdk_link')).existsSync(), isTrue);
    });

    test('a file too big to copy is reported as unrestorable, not silently lost', () async {
      final big = File(p.join(root, 'assets/video.bin'));
      big.parent.createSync(recursive: true);
      big.writeAsBytesSync(List.filled(Snapshot.maxFile + 1, 1));
      final fix = await guard(() async {
        big.writeAsBytesSync(List.filled(Snapshot.maxFile + 2, 2));
        write('lib/main.dart', 'x');
        return 0;
      });
      expect(fix.snapshot!.skipped, 1);
      expect(fix.changes.cannotRestore, ['assets/video.bin']);
      safe.undo(fix);
      expect(read('lib/main.dart'), 'void main() {}\n');
      expect(big.lengthSync(), Snapshot.maxFile + 2);
    });

    test('nothing runs if the copy cannot be made', () async {
      File(p.join(tmp.path, 'blocked')).writeAsStringSync('a file, not a folder');
      SafeFixes.storeOverride = p.join(tmp.path, 'blocked');
      var ran = false;
      final fix = await guard(() async {
        ran = true;
        return 0;
      });
      expect(ran, isFalse);
      expect(fix.state, SafeFixState.unprotected);
    });

    test('only the last few copies are kept', () async {
      for (var i = 0; i < SafeFixes.keep + 3; i++) {
        await guard(() async => 0);
        await Future.delayed(const Duration(milliseconds: 2));
      }
      final store = Directory(p.join(tmp.path, 'store')).listSync().single as Directory;
      expect(store.listSync().length, SafeFixes.keep);
    });
  });

  test('a fix the check rejects goes back, even though the file still reads', () async {
    final fix = await safe.guard(
      'test',
      root,
      () async {
        write('pubspec.yaml', 'name: app\ndev_dependencies:\n  delegates:\n    - nonsense\n');
        return 0;
      },
      checkAnalyzer: false,
      verify: (changes) async => const Verdict(failed: 'flutter pub get fails'),
    );
    expect(fix.state, SafeFixState.restored);
    expect(fix.failedCheck, contains('pub get'));
    expect(read('pubspec.yaml'), _pubspec);
  });

  test('a fix that passes the check stays, and can be undone', () async {
    final fix = await safe.guard(
      'test',
      root,
      () async {
        write('lib/main.dart', 'x');
        return 0;
      },
      checkAnalyzer: false,
      verify: (changes) async => const Verdict(),
    );
    expect(fix.state, SafeFixState.kept);
    expect(fix.canUndo, isTrue);
  });

  test('if the check itself crashes, the fix stays and that is said', () async {
    final fix = await safe.guard(
      'test',
      root,
      () async {
        write('lib/main.dart', 'x');
        return 0;
      },
      checkAnalyzer: false,
      verify: (changes) async => throw StateError('no flutter'),
    );
    expect(fix.state, SafeFixState.kept);
    expect(fix.note, contains("Couldn't check"));
  });

  test('the last fix is remembered per project, and can be dismissed', () async {
    await guard(() async => 0);
    expect(safe.latest(root), isNotNull);
    expect(safe.latest('/other'), isNull);
    safe.dismiss(root);
    expect(safe.latest(root), isNull);
  });
}

ProcessResult _result(int code, [String out = '']) => ProcessResult(1, code, out, '');

void _verdicts() {
  const pubChange = Changes(modified: ['pubspec.yaml']);
  const dartChange = Changes(modified: ['lib/main.dart']);

  group('Deckhand checks a fix itself, whatever the AI claims', () {
    test('the real case: valid YAML, but Flutter crashes on it', () async {
      final v = await Verdict.check(
        changes: pubChange,
        run: (_) async => _result(255, 'Unhandled exception:\nError on line 42: bad dependency\n#0 main'),
      );
      expect(v.failed, contains('pub get'));
      expect(v.failed, contains('bad dependency'));
    });

    test('no network is not the fix\'s fault', () async {
      final v = await Verdict.check(
        changes: pubChange,
        run: (_) async => _result(69, 'SocketException: Failed host lookup: pub.dev'),
      );
      expect(v.failed, isNull);
    });

    test('the same error coming back means it did not work', () async {
      final v = await Verdict.check(
        changes: dartChange,
        retry: const ['gen-l10n'],
        failure: Verdict.errorsIn(['Error on line 96, column 1: Duplicate mapping key.']),
        run: (_) async => _result(1, 'Error on line 96, column 1: Duplicate mapping key.\n'),
      );
      expect(v.failed, contains('still fails the same way'));
    });

    test('a different error is progress: kept, and said out loud', () async {
      final v = await Verdict.check(
        changes: dartChange,
        retry: const ['gen-l10n'],
        failure: Verdict.errorsIn(['Error on line 96, column 1: Duplicate mapping key.']),
        run: (_) async => _result(1, 'Error: Cannot find the arb directory\n'),
      );
      expect(v.failed, isNull);
      expect(v.note, contains('fails differently'));
    });

    test('the command working again is a pass', () async {
      final v = await Verdict.check(changes: dartChange, retry: const ['gen-l10n'], run: (_) async => _result(0));
      expect(v.failed, isNull);
      expect(v.note, isNull);
    });

    test('slow commands are not retried', () async {
      var ran = 0;
      await Verdict.check(
        changes: dartChange,
        retry: const ['build', 'apk'],
        run: (_) async {
          ran++;
          return _result(0);
        },
      );
      expect(ran, 0);
    });

    test('changing nothing is said plainly', () async {
      final v = await Verdict.check(changes: const Changes(), run: (_) async => _result(0));
      expect(v.note, contains("didn't change"));
    });
  });
}
