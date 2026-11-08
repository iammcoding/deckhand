import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/devices.dart';
import 'core/projects.dart';
import 'core/sdk.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

/// Deckhand: a desktop app for Flutter work. Open a project, run it on a
/// device with hot reload and its log, build it, check your setup.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Sdk.instance.init();
  await Projects.instance.load();
  Devices.instance.watch();
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('theme');
  final mode = ThemeMode.values.where((m) => m.name == saved).firstOrNull ?? ThemeMode.system;
  runApp(Deckhand(themeMode: ValueNotifier(mode)));
}

class Deckhand extends StatelessWidget {
  final ValueNotifier<ThemeMode> themeMode;
  const Deckhand({super.key, required this.themeMode});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeMode,
      builder: (_, mode, __) => MaterialApp(
        title: 'Deckhand',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: mode,
        home: Shell(themeMode: themeMode),
      ),
    );
  }
}
