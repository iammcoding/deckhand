import 'dart:io';

import 'package:path/path.dart' as p;

import 'fvm.dart';
import 'sessions.dart';

/// One thing to do to fix it: a shell command, or an edit Deckhand makes.
class FixStep {
  final String label;
  final String? command;
  final Future<String?> Function()? edit; // returns an error, or null
  const FixStep(this.label, {this.command, this.edit});
}

/// A problem recognised in a log, and how to fix it.
class Fix {
  final String title;
  final String detail;
  final List<FixStep> steps;
  const Fix(this.title, this.detail, this.steps);
}

/// Known errors and their fixes. Each rule reads the log; the first match
/// wins. Rules only suggest: nothing runs until the person clicks Fix.
class Fixes {
  Fixes._();

  static Fix? find(List<LogLine> log, String projectPath) {
    // The last 400 lines are enough, and keep this cheap on a long log.
    final lines = log.length > 400 ? log.sublist(log.length - 400) : log;
    final text = lines.map((l) => l.text).join('\n');
    // A pinned version that isn't here explains most of what follows.
    final pin = Fvm.pinFor(projectPath);
    if (pin != null && Fvm.instance.installed && Fvm.instance.sdkDirFor(pin) == null) {
      return Fix(
        'Flutter ${pin.version} isn\'t installed',
        'This project pins it with FVM, so this ran on your default Flutter instead.',
        [FixStep('Install ${pin.version}', command: 'fvm install ${pin.version}')],
      );
    }
    for (final rule in _rules) {
      final f = rule(text, projectPath);
      if (f != null) return f;
    }
    return null;
  }

  /// [pubspec] with `generate: true` under its `flutter:` section. It adds to
  /// the section that's there: a second `flutter:` would break the file.
  static String addGenerateFlag(String pubspec) {
    final lines = pubspec.split('\n');
    final at = lines.indexWhere((l) => RegExp(r'^flutter:\s*(#.*)?$').hasMatch(l));
    if (at < 0) {
      final body = pubspec.endsWith('\n') ? pubspec : '$pubspec\n';
      return '${body}\nflutter:\n  generate: true\n';
    }
    for (var i = at + 1; i < lines.length; i++) {
      if (RegExp(r'^\S').hasMatch(lines[i])) break; // the next section
      final m = RegExp(r'^\s+generate:\s*(\S*)').firstMatch(lines[i]);
      if (m != null) {
        if (m.group(1) == 'true') return pubspec;
        lines[i] = lines[i].replaceFirst(m.group(0)!, '  generate: true');
        return lines.join('\n');
      }
    }
    lines.insert(at + 1, '  generate: true');
    return lines.join('\n');
  }

  static final List<Fix? Function(String text, String project)> _rules = [
    // gen-l10n needs a flag in the pubspec.
    (t, pr) {
      if (!t.contains('generate flag turned on')) return null;
      return Fix(
        'Translations need a setting in pubspec.yaml',
        'Adds generate: true under flutter: in pubspec.yaml. Run Generate translations again afterwards.',
        [
          FixStep(
            'Add the setting',
            edit: () async {
              try {
                final f = File(p.join(pr, 'pubspec.yaml'));
                await f.writeAsString(addGenerateFlag(await f.readAsString()));
                return null;
              } catch (e) {
                return "Couldn't change pubspec.yaml: $e";
              }
            },
          ),
        ],
      );
    },

    // A desktop target the project was never set up for.
    (t, pr) {
      final m = RegExp(r'No (macOS|Windows|Linux) desktop project configured').firstMatch(t);
      if (m == null) return null;
      final plat = m.group(1)!.toLowerCase();
      return Fix(
        'This project has no ${m.group(1)} folder',
        'Flutter needs the $plat/ folder to run on ${m.group(1)}. Adding it creates only that folder; nothing else changes.',
        [FixStep('Add ${m.group(1)} support', command: 'flutter create --platforms=$plat .')],
      );
    },

    // Android's minimum SDK is lower than a plugin needs.
    (t, pr) {
      final m =
          RegExp(r'minSdkVersion (\d+) cannot be smaller than version (\d+)').firstMatch(t) ??
          RegExp(r'requires a higher (?:Android SDK|minSdk)[^\d]*(\d+)?[^\d]*(\d+)').firstMatch(t);
      if (m == null) return null;
      final need = m.group(2) ?? m.group(1);
      if (need == null) return null;
      return Fix(
        'Android minimum SDK is too low',
        'A package needs Android SDK $need or newer. Deckhand can set minSdk to $need in android/app/build.gradle.',
        [
          FixStep('Set minSdk to $need', edit: () => _setMinSdk(pr, int.parse(need))),
          const FixStep('Run again', command: 'flutter pub get'),
        ],
      );
    },

    // CocoaPods isn't installed.
    (t, pr) {
      if (!RegExp(r'CocoaPods not installed|pod: command not found|CocoaPods is not installed').hasMatch(t)) return null;
      return const Fix(
        'CocoaPods is not installed',
        'iOS and macOS builds need CocoaPods for plugins. It installs with Homebrew.',
        [FixStep('Install CocoaPods', command: 'brew install cocoapods')],
      );
    },

    // Pods out of date or a pod version mismatch.
    (t, pr) {
      if (!RegExp(r"CocoaPods could not find compatible versions|out-of-date source repos|pod repo update|Podfile\.lock")
          .hasMatch(t)) {
        return null;
      }
      final dir = t.contains('macos/') && !t.contains('ios/') ? 'macos' : 'ios';
      return Fix(
        'CocoaPods needs updating',
        'The pod specs on this computer are older than a plugin needs. This refreshes them and reinstalls the pods.',
        [FixStep('Update pods ($dir)', command: 'cd $dir && pod install --repo-update')],
      );
    },

    // Gradle or build cache trouble.
    (t, pr) {
      if (!RegExp(r"Could not resolve all (?:files|dependencies)|Execution failed for task ':app:|Gradle task assemble\w* failed")
          .hasMatch(t)) {
        return null;
      }
      return const Fix(
        'The Android build failed',
        'Often a stale build cache or packages. Cleaning and getting packages again fixes most of these; if not, ask the AI.',
        [FixStep('Clean the build', command: 'flutter clean'), FixStep('Get packages', command: 'flutter pub get')],
      );
    },

    // Windows needs Developer Mode for plugin symlinks.
    (t, pr) {
      if (!RegExp(r'Building with plugins requires symlink support|enable Developer Mode').hasMatch(t)) return null;
      return const Fix(
        'Windows Developer Mode is off',
        'Flutter plugins need symlinks on Windows, which Developer Mode allows. Turn it on in Settings, then run again.',
        [FixStep('Open Developer settings', command: 'start ms-settings:developers')],
      );
    },

    // Packages not fetched.
    (t, pr) {
      if (!RegExp(r"Target of URI doesn't exist: 'package:|pubspec\.lock.*(?:missing|out of date)|Run `(?:flutter )?pub get`")
          .hasMatch(t)) {
        return null;
      }
      return const Fix('Packages are missing', 'Some imported packages are not on this computer yet.', [
        FixStep('Get packages', command: 'flutter pub get'),
      ]);
    },
  ];

  /// Sets minSdk in android/app/build.gradle(.kts) to [n].
  static Future<String?> _setMinSdk(String project, int n) async {
    for (final name in ['build.gradle.kts', 'build.gradle']) {
      final f = File(p.join(project, 'android', 'app', name));
      if (!f.existsSync()) continue;
      var s = await f.readAsString();
      final kts = name.endsWith('.kts');
      final re = kts ? RegExp(r'minSdk\s*=\s*[^\n]+') : RegExp(r'minSdk(?:Version)?\s+[^\n]+');
      if (!re.hasMatch(s)) return "Couldn't find minSdk in $name. Set it to $n by hand.";
      s = s.replaceFirst(re, kts ? 'minSdk = $n' : 'minSdkVersion $n');
      await f.writeAsString(s);
      return null;
    }
    return 'No android/app/build.gradle found.';
  }
}
