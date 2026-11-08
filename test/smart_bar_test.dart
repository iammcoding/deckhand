import 'package:deckhand/core/ai.dart';
import 'package:deckhand/core/fixes.dart';
import 'package:deckhand/core/sessions.dart';
import 'package:deckhand/ui/theme.dart';
import 'package:deckhand/ui/widgets/smart_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the translations fix', () {
    test('adds to the flutter section that is there, not a second one', () {
      const before = 'name: app\n\nflutter:\n  uses-material-design: true\n';
      final after = Fixes.addGenerateFlag(before);
      expect(RegExp(r'^flutter:', multiLine: true).allMatches(after).length, 1);
      expect(after, 'name: app\n\nflutter:\n  generate: true\n  uses-material-design: true\n');
    });

    test('leaves it alone when it is already on', () {
      const before = 'flutter:\n  generate: true\n';
      expect(Fixes.addGenerateFlag(before), before);
    });

    test('turns it on when it is off', () {
      expect(Fixes.addGenerateFlag('flutter:\n  generate: false\n'), 'flutter:\n  generate: true\n');
    });

    test('a generate key in another section is not it', () {
      const before = 'flutter:\n  assets:\n    - a.png\nother:\n  generate: false\n';
      expect(Fixes.addGenerateFlag(before), startsWith('flutter:\n  generate: true\n'));
    });

    test('the flutter dependency is not the flutter section', () {
      const before = 'dependencies:\n  flutter:\n    sdk: flutter\n';
      final after = Fixes.addGenerateFlag(before);
      expect(after, contains('  flutter:\n    sdk: flutter\n'));
      expect(after, endsWith('\nflutter:\n  generate: true\n'));
    });

    test('no flutter section: one is added', () {
      expect(Fixes.addGenerateFlag('name: app'), 'name: app\n\nflutter:\n  generate: true\n');
    });

    test('the log text finds the fix', () {
      final fix = Fixes.find([
        LogLine('Attempted to generate localizations code without having the flutter: generate flag turned on.'),
      ], '/nowhere');
      expect(fix?.steps.single.edit, isNotNull);
      expect(fix?.steps.single.command, isNull, reason: 'it edits the file itself, no shell');
    });
  });

  group('commands that change files are called out', () {
    for (final c in [
      "echo 'flutter:' >> pubspec.yaml",
      'cat a > b',
      "sed -i '' 's/a/b/' pubspec.yaml",
      'echo x | tee pubspec.yaml',
    ]) {
      test(c, () => expect(writesFile(c), isTrue));
    }
    for (final c in ['flutter pub get', 'pod install --repo-update', 'flutter gen-l10n']) {
      test('not: $c', () => expect(writesFile(c), isFalse));
    }
  });

  group('waiting for the AI', () {
    Future<void> pump(WidgetTester t, List<String> out) async {
      Ai.instance.provider = Provider.ollama;
      Ai.instance.model = 'test';
      Ai.instance.baseUrl = 'http://127.0.0.1:9';
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SmartBar(
                lines: [LogLine('Something failed', LogLevel.error)],
                projectPath: '/nowhere',
                log: (text, _) => out.add(text),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('nothing animates, so the window is not redrawn all that time', (t) async {
      await pump(t, []);
      await t.tap(find.text('Ask AI'));
      await t.pump();
      expect(find.text('Reading…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // Let the button's own press and hover animations finish.
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
      expect(t.binding.hasScheduledFrame, isFalse, reason: 'no frames while waiting');
      // Let the failed call finish.
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
      await t.pump();
    });

    testWidgets('there is no second log inside the bar', (t) async {
      await pump(t, []);
      expect(find.text('Search the log'), findsNothing);
    });
  });
}
