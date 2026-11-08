import 'package:flutter/material.dart';

import '../../core/bench.dart';
import '../../core/devices.dart';
import '../../core/projects.dart';
import '../../core/sessions.dart';
import '../theme.dart';

/// Start a run on the chosen device. Its log goes to the console.
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

/// The middle of the top bar: device, Run, and once running, its state with
/// reload, restart and stop. Always in reach, whatever the panels show.
class RunBar extends StatelessWidget {
  const RunBar({super.key});

  static IconData deviceIcon(String family) => switch (family) {
    'android' => Icons.android_rounded,
    'ios' => Icons.phone_iphone_rounded,
    'web' => Icons.public_rounded,
    _ => Icons.laptop_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return ValueListenableBuilder<RunSession?>(
      valueListenable: currentRun,
      builder: (context, s, _) => ListenableBuilder(
        listenable: Listenable.merge([Devices.instance, Projects.instance, if (s != null) s]),
        builder: (context, _) {
          final live = s != null && !s.stopped;
          final sel = Devices.instance.selected;
          final hasProject = Projects.instance.current != null;
          return Container(
            height: 30,
            padding: const EdgeInsets.only(left: 4, right: 3),
            decoration: BoxDecoration(
              color: c.panel,
              border: Border.all(color: c.line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _device(c, sel, enabled: !live),
                Container(width: 1, height: 16, color: c.line, margin: const EdgeInsets.symmetric(horizontal: 4)),
                if (!live) ...[
                  if (s != null) ...[
                    Text(s.stopped ? 'Stopped' : '', style: TextStyle(fontSize: 12, color: c.muted)),
                    const SizedBox(width: 8),
                  ],
                  SizedBox(
                    height: 24,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 24),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                      onPressed: sel == null || !hasProject ? null : startRun,
                      icon: const Icon(Icons.play_arrow_rounded, size: 16),
                      label: const Text('Run'),
                    ),
                  ),
                ] else ...[
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(color: s.started ? c.good : c.warn, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 7),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      !s.started ? (s.progress ?? 'Starting…') : (s.lastReload ?? 'Running'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: c.muted),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _icon(c, Icons.bolt_rounded, 'Hot reload  ⌘R', c.warn, s.canReload ? () => s.reload() : null),
                  _icon(
                    c,
                    Icons.restart_alt_rounded,
                    'Hot restart  ⇧⌘R',
                    c.good,
                    s.canReload ? () => s.reload(full: true) : null,
                  ),
                  _icon(c, Icons.stop_rounded, 'Stop', c.bad, s.stop),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _icon(C c, IconData icon, String tip, Color color, VoidCallback? onTap) => IconButton(
    tooltip: tip,
    iconSize: 17,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 28, minHeight: 24),
    onPressed: onTap,
    icon: Icon(icon, color: onTap == null ? c.muted.withValues(alpha: 0.4) : color),
  );

  Widget _device(C c, Device? sel, {required bool enabled}) {
    final devices = Devices.instance.list;
    return PopupMenuButton<String>(
      tooltip: 'Device',
      enabled: enabled,
      color: c.panel,
      position: PopupMenuPosition.under,
      onSelected: (v) => v == '_refresh' ? Devices.instance.refresh() : Devices.instance.select(v),
      itemBuilder: (_) => [
        for (final d in devices)
          PopupMenuItem(
            value: d.id,
            height: 32,
            child: Row(
              children: [
                Icon(deviceIcon(d.family), size: 15, color: d.id == sel?.id ? c.accent : c.muted),
                const SizedBox(width: 9),
                Text(d.name, style: TextStyle(fontSize: 13, color: c.text)),
                if (d.emulator) Text('  simulator', style: TextStyle(fontSize: 11.5, color: c.muted)),
              ],
            ),
          ),
        if (devices.isNotEmpty) const PopupMenuDivider(),
        PopupMenuItem(
          value: '_refresh',
          height: 32,
          child: Text(
            Devices.instance.loading ? 'Looking for devices…' : 'Look for devices again',
            style: TextStyle(fontSize: 13, color: c.text),
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(sel == null ? Icons.devices_other_rounded : deviceIcon(sel.family), size: 15, color: c.muted),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                sel?.name ?? (Devices.instance.loading ? 'Looking…' : 'No device'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: c.text),
              ),
            ),
            Icon(Icons.expand_more_rounded, size: 15, color: c.muted),
          ],
        ),
      ),
    );
  }
}
