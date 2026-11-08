import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/agents.dart';
import 'core/ai.dart';
import 'core/bench.dart';
import 'core/devices.dart';
import 'core/fvm.dart';
import 'core/projects.dart';
import 'core/sdk.dart';
import 'ui/theme.dart';
import 'ui/welcome.dart';
import 'ui/workbench.dart';

/// Deckhand: a desktop app for Flutter work. Open a project, run it on a
/// device with hot reload and its log, build it, check your setup.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('theme');
  final mode = ThemeMode.values.where((m) => m.name == saved).firstOrNull ?? ThemeMode.system;
  runApp(Deckhand(themeMode: ValueNotifier(mode)));
}

class Deckhand extends StatefulWidget {
  final ValueNotifier<ThemeMode> themeMode;
  const Deckhand({super.key, required this.themeMode});

  @override
  State<Deckhand> createState() => _DeckhandState();
}

class _DeckhandState extends State<Deckhand> {
  /// Finding Flutter can take a few seconds (it asks a login shell), so the
  /// window opens on a splash instead of staying blank.
  late final Future<void> _boot = _start();
  bool _welcome = false;

  Future<void> _start() async {
    await Sdk.instance.init();
    await Projects.instance.load();
    await Ai.instance.load();
    await Agents.instance.load();
    Devices.instance.watch();
    await Bench.instance.load();
    // Pins work without this; it finds the fvm command and its cache.
    Fvm.instance.detect();
    final prefs = await SharedPreferences.getInstance();
    // First launch, or nothing to open yet: the welcome screen.
    _welcome = prefs.getBool('welcome_done') != true || Projects.instance.recent.isEmpty;
  }

  Future<void> _finishWelcome() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('welcome_done', true);
    if (mounted) setState(() => _welcome = false);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: widget.themeMode,
      builder: (_, mode, __) => MaterialApp(
        title: 'Deckhand',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: mode,
        home: FutureBuilder<void>(
          future: _boot,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const Splash();
            if (_welcome) {
              return Welcome(
                onDone: _finishWelcome,
                onOpenSettings: () {
                  Bench.instance.open(const EditorTab(TabKind.settings));
                  _finishWelcome();
                },
              );
            }
            return Workbench(themeMode: widget.themeMode);
          },
        ),
      ),
    );
  }
}
