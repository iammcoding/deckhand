import 'package:flutter/material.dart';

import '../../core/bench.dart';
import '../../core/devices.dart';
import '../../core/projects.dart';
import '../../core/sessions.dart';
import '../theme.dart';
import 'side_kit.dart';

/// Start a run, then control it. Its log is in the bottom panel.
Future<void> startRun() async {
  final project = Projects.instance.current;
  final device = Devices.instance.selected;
  if (project == null || device == null) return;
  final old = currentRun.value;
  if (old != null && !old.stopped) await old.stop();
  old?.dispose();
  final s = RunSession(projectPath: project.path, deviceId: device.id, deviceName: device.name);
  currentRun.value = s;
  Bench.instance.showBottom(BottomTab.run);
  s.start();
}

class RunSide extends StatelessWidget {
  const RunSide({super.key});

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return ValueListenableBuilder<RunSession?>(
      valueListenable: currentRun,
      builder: (context, s, _) => ListenableBuilder(
        listenable: Listenable.merge([Devices.instance, if (s != null) s]),
        builder: (context, _) {
          final live = s != null && !s.stopped;
          final devices = Devices.instance.list;
          final sel = Devices.instance.selected;
          return ListView(
            children: [
              SideTitle(
                'Run',
                actions: [
                  IconButton(
                    tooltip: 'Refresh devices',
                    iconSize: 15,
                    visualDensity: VisualDensity.compact,
                    onPressed: Devices.instance.refresh,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: live
                    ? Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: s.canReload ? () => s.reload() : null,
                              icon: Icon(Icons.bolt_rounded, size: 16, color: c.warn),
                              label: const Text('Reload'),
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton.outlined(
                            tooltip: 'Hot restart  ⇧⌘R',
                            onPressed: s.canReload ? () => s.reload(full: true) : null,
                            icon: Icon(Icons.restart_alt_rounded, size: 17, color: c.good),
                          ),
                          const SizedBox(width: 4),
                          IconButton.outlined(
                            tooltip: 'Stop',
                            onPressed: s.stop,
                            icon: Icon(Icons.stop_rounded, size: 17, color: c.bad),
                          ),
                        ],
                      )
                    : FilledButton.icon(
                        onPressed: sel == null ? null : startRun,
                        icon: const Icon(Icons.play_arrow_rounded, size: 18),
                        label: Text(sel == null ? 'No device' : 'Run on ${sel.name}', overflow: TextOverflow.ellipsis),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: Row(
                  children: [
                    stateDot(
                      s == null
                          ? c.muted
                          : s.stopped
                          ? c.bad
                          : s.started
                          ? c.good
                          : c.warn,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        s == null
                            ? 'Not running'
                            : s.stopped
                            ? 'Stopped'
                            : !s.started
                            ? (s.progress ?? 'Starting…')
                            : 'Running${s.lastReload != null ? ' · ${s.lastReload}' : ''}',
                        maxLines: 2,
                        style: TextStyle(fontSize: 12, color: c.muted),
                      ),
                    ),
                  ],
                ),
              ),
              if (s != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: () => Bench.instance.showBottom(BottomTab.run),
                        child: const Text('Show log', style: TextStyle(fontSize: 12)),
                      ),
                      TextButton(
                        onPressed: s.clear,
                        child: Text('Clear', style: TextStyle(fontSize: 12, color: c.muted)),
                      ),
                    ],
                  ),
                ),
              const SideLabel('Device'),
              if (devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    Devices.instance.loading ? 'Looking for devices…' : 'No devices. Plug in a phone or start a simulator.',
                    style: TextStyle(fontSize: 12, color: c.muted),
                  ),
                ),
              for (final d in devices)
                SideRow(
                  icon: switch (d.family) {
                    'android' => Icons.android_rounded,
                    'ios' => Icons.phone_iphone_rounded,
                    'web' => Icons.public_rounded,
                    _ => Icons.laptop_rounded,
                  },
                  label: d.name,
                  detail: d.emulator ? 'simulator' : null,
                  selected: d.id == sel?.id,
                  onTap: live ? null : () => Devices.instance.select(d.id),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 18, 12, 12),
                child: Text(
                  '⌘R hot reload   ⇧⌘R restart',
                  style: TextStyle(fontSize: 11.5, color: c.muted.withValues(alpha: 0.7)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
