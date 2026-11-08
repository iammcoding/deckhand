import 'dart:io';

import 'package:deckhand/core/fixes.dart';
import 'package:deckhand/core/fvm.dart';
import 'package:deckhand/core/sdk.dart';
import 'package:deckhand/core/sessions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late String cache;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('deckhand_fvm').absolute;
    // The real path: macOS's temp folder is behind a link.
    tmp = Directory(tmp.resolveSymbolicLinksSync());
    cache = p.join(tmp.path, 'cache');
    Sdk.instance.env = {...Platform.environment, 'FVM_CACHE_PATH': cache, 'PATH': '/usr/bin'};
    Sdk.instance.flutterBin = '/default/bin/flutter';
    Fvm.instance.bin = null;
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  String project([String name = 'app']) {
    final d = p.join(tmp.path, name);
    Directory(d).createSync(recursive: true);
    return d;
  }

  void write(String path, String text) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  /// A version in FVM's cache, with a flutter to find.
  String install(String version) {
    final dir = p.join(cache, 'versions', version);
    write(p.join(dir, 'bin', 'flutter'), '');
    write(p.join(dir, 'bin', 'dart'), '');
    return dir;
  }

  group('reading the pin', () {
    test('no config, no pin', () => expect(Fvm.pinFor(project()), isNull));

    test('.fvmrc', () {
      final d = project();
      write(p.join(d, '.fvmrc'), '{"flutter": "3.24.0", "flavors": {"dev": "beta"}}');
      final pin = Fvm.pinFor(d)!;
      expect(pin.version, '3.24.0');
      expect(pin.root, d);
      expect(pin.flavors, {'dev': 'beta'});
    });

    test('the older .fvm/fvm_config.json', () {
      final d = project();
      write(p.join(d, '.fvm', 'fvm_config.json'), '{"flutterSdkVersion": "3.10.0", "flavors": {}}');
      expect(Fvm.pinFor(d)!.version, '3.10.0');
    });

    test('.fvmrc wins when both exist, as FVM writes both', () {
      final d = project();
      write(p.join(d, '.fvmrc'), '{"flutter": "3.24.0"}');
      write(p.join(d, '.fvm', 'fvm_config.json'), '{"flutterSdkVersion": "3.10.0"}');
      expect(Fvm.pinFor(d)!.version, '3.24.0');
    });

    test('from a parent folder, as in a monorepo', () {
      final root = project('mono');
      final app = project('mono/packages/app');
      write(p.join(root, '.fvmrc'), '{"flutter": "stable"}');
      final pin = Fvm.pinFor(app)!;
      expect(pin.version, 'stable');
      expect(pin.root, root);
    });

    test('a broken or empty config is not a pin, and does not throw', () {
      final d = project();
      write(p.join(d, '.fvmrc'), '{not json');
      expect(Fvm.pinFor(d), isNull);
      write(p.join(d, '.fvmrc'), '{"flutter": ""}');
      expect(Fvm.pinFor(d), isNull);
      write(p.join(d, '.fvmrc'), '[1]');
      expect(Fvm.pinFor(d), isNull);
    });

    test('null folder', () => expect(Fvm.pinFor(null), isNull));
  });

  group('which Flutter runs', () {
    test('no pin: the default', () {
      final d = project();
      expect(Sdk.instance.flutterFor(d), '/default/bin/flutter');
      expect(Sdk.instance.envFor(d)['PATH'], '/usr/bin');
    });

    test('pinned and installed: the pinned one, first on PATH', () {
      final d = project();
      final sdk = install('3.24.0');
      write(p.join(d, '.fvmrc'), '{"flutter": "3.24.0"}');
      expect(Sdk.instance.flutterFor(d), p.join(sdk, 'bin', 'flutter'));
      expect(Sdk.instance.dartFor(d), p.join(sdk, 'bin', 'dart'));
      expect(Sdk.instance.envFor(d)['PATH'], '${p.join(sdk, 'bin')}:/usr/bin');
      expect(Fvm.instance.missingFor(d), isFalse);
    });

    test('pinned but missing: the default, and it says so', () {
      final d = project();
      write(p.join(d, '.fvmrc'), '{"flutter": "3.24.0"}');
      expect(Sdk.instance.flutterFor(d), '/default/bin/flutter');
      expect(Fvm.instance.missingFor(d), isTrue);
    });

    test('a leftover link to another version is not trusted', () {
      final d = project();
      final old = install('3.10.0');
      write(p.join(d, '.fvmrc'), '{"flutter": "3.24.0"}');
      Directory(p.join(d, '.fvm')).createSync();
      Link(p.join(d, '.fvm', 'flutter_sdk')).createSync(old);
      expect(Fvm.instance.missingFor(d), isTrue);
      expect(Sdk.instance.flutterFor(d), '/default/bin/flutter');
    });

    test('a link to the pinned version, outside the cache, is used', () {
      final d = project();
      final elsewhere = p.join(tmp.path, 'elsewhere', '3.24.0');
      write(p.join(elsewhere, 'bin', 'flutter'), '');
      write(p.join(d, '.fvmrc'), '{"flutter": "3.24.0"}');
      Directory(p.join(d, '.fvm')).createSync();
      Link(p.join(d, '.fvm', 'flutter_sdk')).createSync(elsewhere);
      expect(Fvm.instance.missingFor(d), isFalse);
      expect(Sdk.instance.flutterFor(d), p.join(d, '.fvm', 'flutter_sdk', 'bin', 'flutter'));
    });

    test('a git checkout that changes .fvmrc is followed at once', () {
      final d = project();
      install('3.24.0');
      final other = install('3.27.0');
      write(p.join(d, '.fvmrc'), '{"flutter": "3.24.0"}');
      Sdk.instance.flutterFor(d);
      write(p.join(d, '.fvmrc'), '{"flutter": "3.27.0"}');
      expect(Sdk.instance.flutterFor(d), p.join(other, 'bin', 'flutter'));
    });
  });

  group('the version of a pinned project', () {
    test('comes from the SDK\'s own file, without running anything', () async {
      final d = project();
      final sdk = install('3.24.0');
      write(p.join(d, '.fvmrc'), '{"flutter": "3.24.0"}');
      write(
        p.join(sdk, 'bin', 'cache', 'flutter.version.json'),
        '{"frameworkVersion": "3.24.0", "channel": "stable", "dartSdkVersion": "3.5.0"}',
      );
      final v = await Sdk.instance.version(cwd: d);
      expect(v?['channel'], 'stable');
      expect(v?['dartSdkVersion'], '3.5.0');
    });

    test('not set up yet: still answers, and starts no download', () async {
      final d = project();
      install('3.24.0');
      write(p.join(d, '.fvmrc'), '{"flutter": "3.24.0"}');
      final v = await Sdk.instance.version(cwd: d);
      expect(v?['frameworkVersion'], '3.24.0');
      expect(v?['channel'], 'not set up yet');
    });
  });

  group('what FVM prints', () {
    test('a notice before the JSON is skipped', () {
      expect(Fvm.parseJson('A new FVM is out!\n{"size": "1 GB"}\n'), {'size': '1 GB'});
    });

    test('not JSON is a clear error', () {
      expect(() => Fvm.parseJson('Could not run'), throwsA(isA<FvmError>()));
      expect(() => Fvm.parseJson('{oops}'), throwsA(isA<FvmError>()));
    });

    test('list: a version not set up yet has no Flutter or Dart version', () {
      final list = Fvm.parseList({
        'size': '635.88 MB',
        'versions': [
          {'name': '3.47.9', 'type': 'release', 'directory': '/v/3.47.9', 'isSetup': false},
          {
            'name': 'stable',
            'releaseChannel': 'stable',
            'directory': '/v/stable',
            'flutterSdkVersion': '3.47.9',
            'dartSdkVersion': '3.13.7',
            'isSetup': true,
          },
        ],
        'projects': [],
        'unreferencedVersions': ['stable'],
      });
      expect(list[0].flutter, '');
      expect(list[0].isSetup, isFalse);
      expect(list[0].unused, isFalse);
      expect(list[1].flutter, '3.47.9');
      expect(list[1].dart, '3.13.7');
      expect(list[1].unused, isTrue);
    });

    test('releases', () {
      final r = Fvm.parseReleases({
        'versions': [
          {
            'version': '3.47.9',
            'channelName': 'stable',
            'channel': 'stable',
            'dart_sdk_version': '3.13.7',
            'release_date': '2026-10-29T19:05:00.489218Z',
          },
        ],
      });
      expect(r.single.version, '3.47.9');
      expect(r.single.dart, '3.13.7');
      expect(r.single.date!.year, 2026);
    });

    test('colour codes are taken out of a log', () {
      expect(Job.cleanLine('\x1B[33m│ \x1B[m⚠ path is incorrect\x1B[33m │\x1B[m'), '│ ⚠ path is incorrect │');
    });

    test('a warning on stderr is not an error', () {
      expect(Job.stderrLevel('[WARN] Not checking for version mismatch'), LogLevel.warn);
      expect(Job.stderrLevel('Something broke'), LogLevel.error);
    });
  });

  group('never waits for an answer', () {
    test('every FVM call says not to ask', () {
      expect(Fvm.args(['use', '3.24.0', '--force']), ['use', '3.24.0', '--force', '--fvm-skip-input']);
    });
  });

  group('the Fix button', () {
    test('offers the pinned version when FVM can install it', () {
      final d = project();
      write(p.join(d, '.fvmrc'), '{"flutter": "3.24.0"}');
      Fvm.instance.bin = '/somewhere/fvm';
      final fix = Fixes.find([], d)!;
      expect(fix.steps.single.command, 'fvm install 3.24.0');
    });

    test('says nothing when it is installed', () {
      final d = project();
      install('3.24.0');
      write(p.join(d, '.fvmrc'), '{"flutter": "3.24.0"}');
      Fvm.instance.bin = '/somewhere/fvm';
      expect(Fixes.find([], d), isNull);
    });
  });

  group('stop using FVM', () {
    test('removes the config and links, never the SDK they point at', () async {
      final d = project();
      final sdk = install('3.24.0');
      write(p.join(d, '.fvmrc'), '{"flutter": "3.24.0"}');
      write(p.join(d, 'pubspec.yaml'), 'name: app');
      Directory(p.join(d, '.fvm')).createSync();
      Link(p.join(d, '.fvm', 'flutter_sdk')).createSync(sdk);
      await Fvm.unpin(Fvm.pinFor(d)!);
      expect(File(p.join(d, '.fvmrc')).existsSync(), isFalse);
      expect(Directory(p.join(d, '.fvm')).existsSync(), isFalse);
      expect(File(p.join(d, 'pubspec.yaml')).existsSync(), isTrue);
      expect(File(p.join(sdk, 'bin', 'flutter')).existsSync(), isTrue, reason: 'the installed SDK must survive');
    });
  });
}
