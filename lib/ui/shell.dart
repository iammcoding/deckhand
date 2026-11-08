import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/devices.dart';
import '../core/projects.dart';
import '../core/sdk.dart';
import '../core/sessions.dart';
import 'pages/build_page.dart';
import 'pages/devices_page.dart';
import 'pages/doctor_page.dart';
import 'pages/overview_page.dart';
import 'pages/projects_page.dart';
import 'pages/run_page.dart';
import 'pages/settings_page.dart';
import 'theme.dart';
import 'widgets/palette.dart';

class Shell extends StatefulWidget {
  final ValueNotifier<ThemeMode> themeMode;

  /// Open on this page (Settings, from the welcome screen's Connect).
  final int? initialPage;
  const Shell({super.key, required this.themeMode, this.initialPage});

  @override
  State<Shell> createState() => _ShellState();
}

class _Nav {
  final IconData icon;
  final String label;
  final int page;
  final bool needsProject;
  final String? keys;
  const _Nav(this.icon, this.label, this.page, {this.needsProject = false, this.keys});
}

class _ShellState extends State<Shell> {
  int _page = 0;
  String _flutter = '';

  // Pages: 0 Projects, 1 Overview, 2 Run, 3 Build, 4 Devices, 5 Doctor, 6 Settings.
  static const _project = [
    _Nav(Icons.space_dashboard_outlined, 'Overview', 1, needsProject: true, keys: '⌘1'),
    _Nav(Icons.play_circle_outline_rounded, 'Run', 2, needsProject: true, keys: '⌘2'),
    _Nav(Icons.construction_rounded, 'Build', 3, needsProject: true, keys: '⌘3'),
  ];
  static const _tools = [
    _Nav(Icons.folder_open_rounded, 'Projects', 0, keys: '⌘O'),
    _Nav(Icons.devices_rounded, 'Devices', 4),
    _Nav(Icons.health_and_safety_outlined, 'Doctor', 5),
  ];

  @override
  void initState() {
    super.initState();
    Projects.instance.addListener(_changed);
    Devices.instance.addListener(_changed);
    currentRun.addListener(_runChanged);
    // Start where there's something to do.
    if (Projects.instance.current != null) _page = 1;
    if (widget.initialPage != null) _page = widget.initialPage!;
    Sdk.instance.version().then((v) {
      if (mounted && v != null) setState(() => _flutter = 'Flutter ${v['frameworkVersion']} · ${v['channel']}');
    });
  }

  @override
  void dispose() {
    Projects.instance.removeListener(_changed);
    Devices.instance.removeListener(_changed);
    currentRun.removeListener(_runChanged);
    currentRun.value?.removeListener(_changed);
    super.dispose();
  }

  RunSession? _watched;
  void _runChanged() {
    _watched?.removeListener(_changed);
    _watched = currentRun.value?..addListener(_changed);
    _changed();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void go(int i) => setState(() => _page = i);

  /// What ⌘K can do: go anywhere, drive the running app, open a recent
  /// project, change the look.
  List<Command> _commands() {
    final project = Projects.instance.current;
    final run = currentRun.value;
    final live = run != null && !run.stopped;
    return [
      if (project != null) ...[
        Command('Overview', 'Go to', () => go(1), keys: '⌘1'),
        Command('Run', 'Go to', () => go(2), keys: '⌘2'),
        Command('Build', 'Go to', () => go(3), keys: '⌘3'),
      ],
      Command('Projects', 'Go to', () => go(0), keys: '⌘O'),
      Command('Devices', 'Go to', () => go(4)),
      Command('Doctor', 'Go to', () => go(5)),
      Command('Settings', 'Go to', () => go(6), keys: '⌘,'),
      if (live && run.canReload) ...[
        Command('Hot reload', 'App', () => run.reload(), keys: '⌘R'),
        Command('Hot restart', 'App', () => run.reload(full: true), keys: '⇧⌘R'),
      ],
      if (live) Command('Stop the app', 'App', run.stop),
      Command('Refresh devices', 'Devices', Devices.instance.refresh),
      for (final d in Devices.instance.list) Command('Use ${d.name}', 'Devices', () => Devices.instance.select(d.id)),
      for (final r in Projects.instance.recent.where((r) => r.path != project?.path).take(8))
        Command('Open ${r.name}', 'Projects', () async {
          await Projects.instance.open(r.path);
          go(1);
        }),
      Command('Dark appearance', 'Look', () => widget.themeMode.value = ThemeMode.dark),
      Command('Light appearance', 'Look', () => widget.themeMode.value = ThemeMode.light),
      Command('Match the system', 'Look', () => widget.themeMode.value = ThemeMode.system),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final project = Projects.instance.current;
    final pages = <Widget>[
      ProjectsPage(onOpened: () => go(1)),
      OverviewPage(go: go),
      const RunPage(),
      const BuildPage(),
      const DevicesPage(),
      const DoctorPage(),
      SettingsPage(themeMode: widget.themeMode),
    ];
    final meta = Platform.isMacOS;
    SingleActivator key(LogicalKeyboardKey k) => SingleActivator(k, meta: meta, control: !meta);
    return CallbackShortcuts(
      bindings: {
        key(LogicalKeyboardKey.digit1): () => project != null ? go(1) : null,
        key(LogicalKeyboardKey.digit2): () => project != null ? go(2) : null,
        key(LogicalKeyboardKey.digit3): () => project != null ? go(3) : null,
        key(LogicalKeyboardKey.keyO): () => go(0),
        key(LogicalKeyboardKey.comma): () => go(6),
        key(LogicalKeyboardKey.keyK): () => showPalette(context, _commands()),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(children: [
            Expanded(
              child: Row(children: [
                _sidebar(c, project),
                Expanded(child: IndexedStack(index: _page, children: pages)),
              ]),
            ),
            _statusBar(c),
          ]),
        ),
      ),
    );
  }

  Widget _sidebar(C c, Project? project) => Container(
        width: 228,
        decoration: BoxDecoration(color: c.panel, border: Border(right: BorderSide(color: c.line))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Room for the window's traffic lights, which sit over this.
          SizedBox(height: Platform.isMacOS ? 46 : 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Row(children: [
              Icon(Icons.anchor_rounded, size: 18, color: c.text),
              const SizedBox(width: 9),
              Text('Deckhand', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.text, letterSpacing: -0.2)),
            ]),
          ),
          // The open project, always in view: everything else acts on it.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(5),
              child: InkWell(
                borderRadius: BorderRadius.circular(5),
                onTap: () => go(0),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(project?.name ?? 'Open a project',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text)),
                        Text(project == null ? 'No project open' : (project.version.isEmpty ? project.folder : 'v${project.version}'),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: c.muted)),
                      ]),
                    ),
                    Icon(Icons.unfold_more_rounded, size: 16, color: c.muted),
                  ]),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          _section(c, 'PROJECT'),
          for (final n in _project) _navItem(n, c, enabled: project != null),
          const SizedBox(height: 14),
          _section(c, 'TOOLS'),
          for (final n in _tools) _navItem(n, c, enabled: true),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: InkWell(
              borderRadius: BorderRadius.circular(5),
              onTap: () => showPalette(context, _commands()),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(border: Border.all(color: c.line), borderRadius: BorderRadius.circular(5)),
                child: Row(children: [
                  Icon(Icons.search_rounded, size: 15, color: c.muted),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Commands', style: TextStyle(fontSize: 12.5, color: c.muted))),
                  Text(Platform.isMacOS ? '⌘K' : 'Ctrl K', style: TextStyle(fontSize: 11, color: c.muted.withValues(alpha: 0.7))),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 6),
          _navItem(const _Nav(Icons.tune_rounded, 'Settings', 6, keys: '⌘,'), c, enabled: true),
          const SizedBox(height: 10),
        ]),
      );

  Widget _section(C c, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 16, 6),
        child: Text(t, style: TextStyle(fontSize: 10.5, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: c.muted.withValues(alpha: 0.8))),
      );

  Widget _navItem(_Nav n, C c, {required bool enabled}) {
    final on = _page == n.page;
    final running = n.page == 2 && currentRun.value != null && !currentRun.value!.stopped;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Material(
        color: on ? c.raised : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          borderRadius: BorderRadius.circular(5),
          onTap: enabled ? () => go(n.page) : null,
          child: Stack(children: [
            // The page you're on: a short accent bar at the left edge.
            if (on)
              Positioned(
                left: 0,
                top: 8,
                bottom: 8,
                child: Container(width: 3, decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(2))),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                Icon(n.icon, size: 17, color: !enabled ? c.muted.withValues(alpha: 0.35) : on ? c.accent : c.muted),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(n.label,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                          color: !enabled ? c.muted.withValues(alpha: 0.45) : c.text)),
                ),
                if (running)
                  Container(width: 7, height: 7, decoration: BoxDecoration(color: c.good, shape: BoxShape.circle))
                else if (n.keys != null && enabled)
                  Text(n.keys!, style: TextStyle(fontSize: 11, color: c.muted.withValues(alpha: 0.6))),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  /// Along the bottom, always: the Flutter in use, the device, and the app if
  /// one is running. Click the app to go to it.
  Widget _statusBar(C c) {
    final run = currentRun.value;
    final dev = Devices.instance.selected;
    Widget item(IconData icon, String text, {Color? color, VoidCallback? onTap}) => InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 13, color: color ?? c.muted),
              const SizedBox(width: 6),
              Text(text, style: TextStyle(fontSize: 11.5, color: color ?? c.muted)),
            ]),
          ),
        );
    return Container(
      height: 26,
      decoration: BoxDecoration(color: c.panel, border: Border(top: BorderSide(color: c.line))),
      child: Row(children: [
        const SizedBox(width: 6),
        item(Icons.flutter_dash_rounded, _flutter.isEmpty ? (Sdk.instance.ready ? 'Flutter' : 'Flutter not found') : _flutter,
            color: Sdk.instance.ready ? null : c.bad, onTap: () => go(6)),
        item(Icons.smartphone_rounded, dev?.name ?? 'No device', onTap: () => go(4)),
        const Spacer(),
        if (run != null)
          item(
            run.stopped ? Icons.stop_circle_outlined : Icons.circle,
            run.stopped
                ? 'Stopped'
                : run.started
                    ? 'Running on ${run.deviceName}${run.lastReload != null ? ' · ${run.lastReload}' : ''}'
                    : (run.progress ?? 'Starting…'),
            color: run.stopped ? c.muted : (run.started ? c.good : c.warn),
            onTap: () => go(2),
          ),
        const SizedBox(width: 6),
      ]),
    );
  }
}

/// A page's header: its title, a line under it, and actions on the right.
class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  const PageHeader({super.key, required this.title, this.subtitle, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: c.text)),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!, style: TextStyle(fontSize: 13, color: c.muted)),
            ],
          ]),
        ),
        ...[for (final a in actions) Padding(padding: const EdgeInsets.only(left: 8), child: a)],
      ]),
    );
  }
}
