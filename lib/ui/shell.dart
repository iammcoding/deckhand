import 'package:flutter/material.dart';

import '../core/devices.dart';
import '../core/projects.dart';
import 'pages/build_page.dart';
import 'pages/devices_page.dart';
import 'pages/doctor_page.dart';
import 'pages/projects_page.dart';
import 'pages/run_page.dart';
import 'pages/settings_page.dart';
import 'theme.dart';

class Shell extends StatefulWidget {
  final ValueNotifier<ThemeMode> themeMode;
  const Shell({super.key, required this.themeMode});

  @override
  State<Shell> createState() => _ShellState();
}

class _Nav {
  final IconData icon;
  final String label;
  final bool needsProject;
  const _Nav(this.icon, this.label, {this.needsProject = false});
}

class _ShellState extends State<Shell> {
  int _page = 0;

  static const _nav = [
    _Nav(Icons.folder_open_rounded, 'Projects'),
    _Nav(Icons.play_circle_outline_rounded, 'Run', needsProject: true),
    _Nav(Icons.inventory_2_outlined, 'Build', needsProject: true),
    _Nav(Icons.devices_rounded, 'Devices'),
    _Nav(Icons.health_and_safety_outlined, 'Doctor'),
    _Nav(Icons.tune_rounded, 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    Projects.instance.addListener(_changed);
    Devices.instance.addListener(_changed);
    // Start where there's something to do.
    if (Projects.instance.current != null) _page = 1;
  }

  @override
  void dispose() {
    Projects.instance.removeListener(_changed);
    Devices.instance.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void go(int i) => setState(() => _page = i);

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final project = Projects.instance.current;
    final pages = <Widget>[
      ProjectsPage(onOpened: () => go(1)),
      const RunPage(),
      const BuildPage(),
      const DevicesPage(),
      const DoctorPage(),
      SettingsPage(themeMode: widget.themeMode),
    ];
    return Scaffold(
      body: Row(children: [
        Container(
          width: 216,
          decoration: BoxDecoration(color: c.panel, border: Border(right: BorderSide(color: c.line))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 38),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Row(children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(6)),
                  child: const Icon(Icons.anchor_rounded, size: 14, color: Colors.white),
                ),
                const SizedBox(width: 8),
                Text('Deckhand', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.text)),
              ]),
            ),
            // The open project, always in view: everything else acts on it.
            InkWell(
              onTap: () => go(0),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: c.raised,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: c.line),
                ),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(project?.name ?? 'No project open',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text)),
                      const SizedBox(height: 2),
                      Text(project == null ? 'Open one to start' : 'v${project.version.isEmpty ? '—' : project.version}',
                          style: TextStyle(fontSize: 11.5, color: c.muted)),
                    ]),
                  ),
                  Icon(Icons.unfold_more_rounded, size: 16, color: c.muted),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < _nav.length; i++) _navItem(i, c, enabled: !_nav[i].needsProject || project != null),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                Devices.instance.selected == null ? 'No device' : Devices.instance.selected!.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: c.muted),
              ),
            ),
          ]),
        ),
        Expanded(child: IndexedStack(index: _page, children: pages)),
      ]),
    );
  }

  Widget _navItem(int i, C c, {required bool enabled}) {
    final n = _nav[i];
    final on = _page == i;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Material(
        color: on ? c.raised : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: enabled ? () => go(i) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(children: [
              Icon(n.icon, size: 17, color: !enabled ? c.muted.withValues(alpha: 0.4) : on ? c.accent : c.muted),
              const SizedBox(width: 10),
              Text(n.label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                      color: !enabled ? c.muted.withValues(alpha: 0.5) : c.text)),
            ]),
          ),
        ),
      ),
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
