import 'dart:async';
import 'dart:io';

import 'package:deckhand/core/bench.dart';
import 'package:deckhand/core/projects.dart';
import 'package:deckhand/core/sdk.dart';
import 'package:deckhand/core/sessions.dart';
import 'package:deckhand/core/jobs.dart';
import 'package:deckhand/ui/pages/doctor_page.dart';
import 'package:deckhand/ui/theme.dart';
import 'package:deckhand/ui/workbench.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('deckhand_bench');
    File(p.join(tmp.path, 'pubspec.yaml'))
        .writeAsStringSync('name: demo\nversion: 1.0.0+1\ndependencies:\n  flutter:\n    sdk: flutter\n');
    Directory(p.join(tmp.path, 'android')).createSync();
    Directory(p.join(tmp.path, 'lib')).createSync();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> open(WidgetTester t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.runAsync(() async {
      await Bench.instance.load();
      expect(await Projects.instance.open(tmp.path), isNull);
      await Future.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Workbench(themeMode: ValueNotifier(ThemeMode.dark)),
      ),
    );
    await t.pump();
  }

  testWidgets('every sidebar section draws without an error', (t) async {
    await open(t);
    for (final a in Activity.values) {
      Bench.instance.showActivity(a);
      await t.pump();
      expect(t.takeException(), isNull, reason: 'in ${a.name}');
    }
  });

  testWidgets('every console tab draws without an error', (t) async {
    await open(t);
    final job = Job('Task', ['--version']);
    job.add('Something failed', LogLevel.error);
    currentTask.value = job;
    for (final tab in const [BottomTab.run, BottomTab.build, BottomTab.tasks, BottomTab.problems]) {
      Bench.instance.showBottom(tab);
      await t.pump();
      expect(t.takeException(), isNull, reason: 'in ${tab.name}');
    }
    currentTask.value = null;
  });

  testWidgets('leaving Doctor before it answers does not crash', (t) async {
    // A real process that answers a moment after the page has gone.
    Sdk.instance.flutterBin = '/bin/echo';
    addTearDown(() => Sdk.instance.flutterBin = null);
    final errors = <Object>[];
    await t.runAsync(() async {
      await runZonedGuarded(() async {
        await t.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.dark),
            home: const Scaffold(body: DoctorPage()),
          ),
        );
        await t.pumpWidget(const SizedBox());
        await Future.delayed(const Duration(milliseconds: 500));
      }, (e, _) => errors.add(e));
    });
    await t.pump();
    expect(errors, isEmpty);
    expect(t.takeException(), isNull);
  });
}
