import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/devices.dart';
import '../../core/projects.dart';
import '../../core/sessions.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets/log_view.dart';
import '../widgets/smart_bar.dart';

/// The app on a device: run, hot reload, hot restart, stop, and its log.
/// One session at a time; it keeps going while you're on other pages.
class RunPage extends StatefulWidget {
  const RunPage({super.key});

  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> {
  RunSession? get _session => currentRun.value;

  bool get _running => _session != null && !_session!.stopped;

  Future<void> _run() async {
    final project = Projects.instance.current;
    final device = Devices.instance.selected;
    if (project == null || device == null) return;
    currentRun.value?.dispose();
    final s = RunSession(projectPath: project.path, deviceId: device.id, deviceName: device.name);
    currentRun.value = s;
    setState(() {});
    s.start();
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true): () => _session?.reload(),
        const SingleActivator(LogicalKeyboardKey.keyR, control: true): () => _session?.reload(),
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true, shift: true): () => _session?.reload(full: true),
        const SingleActivator(LogicalKeyboardKey.keyR, control: true, shift: true): () => _session?.reload(full: true),
      },
      child: Focus(
        autofocus: true,
        child: ListenableBuilder(
          listenable: Listenable.merge([Devices.instance, Projects.instance, currentRun, if (_session != null) _session!]),
          builder: (context, _) {
            final s = _session;
            final devices = Devices.instance.list;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              PageHeader(
                title: 'Run',
                subtitle: Projects.instance.current?.path,
                actions: [
                  // Device picker.
                  Container(
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(border: Border.all(color: c.line), borderRadius: BorderRadius.circular(5)),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: Devices.instance.selected?.id,
                        hint: Text(Devices.instance.loading ? 'Finding devices…' : 'No devices', style: TextStyle(fontSize: 13, color: c.muted)),
                        isDense: true,
                        style: TextStyle(fontSize: 13, color: c.text),
                        dropdownColor: c.panel,
                        items: [
                          for (final d in devices)
                            DropdownMenuItem(value: d.id, child: Text('${d.name}${d.emulator ? '  (simulator)' : ''}')),
                        ],
                        onChanged: _running ? null : (v) => v == null ? null : Devices.instance.select(v),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh devices',
                    onPressed: Devices.instance.refresh,
                    icon: Devices.instance.loading
                        ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: c.muted))
                        : const Icon(Icons.refresh_rounded),
                  ),
                  if (!_running)
                    FilledButton.icon(
                      onPressed: Devices.instance.selected == null ? null : _run,
                      icon: const Icon(Icons.play_arrow_rounded, size: 18),
                      label: const Text('Run'),
                    )
                  else ...[
                    OutlinedButton.icon(
                      onPressed: s!.canReload ? () => s.reload() : null,
                      icon: Icon(Icons.bolt_rounded, size: 17, color: c.warn),
                      label: const Text('Hot reload'),
                    ),
                    OutlinedButton.icon(
                      onPressed: s.canReload ? () => s.reload(full: true) : null,
                      icon: Icon(Icons.restart_alt_rounded, size: 17, color: c.good),
                      label: const Text('Restart'),
                    ),
                    OutlinedButton.icon(
                      onPressed: s.stop,
                      icon: Icon(Icons.stop_rounded, size: 17, color: c.bad),
                      label: const Text('Stop'),
                    ),
                  ],
                ],
              ),
              // Status line.
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
                child: Row(children: [
                  _dot(c, s),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      s == null
                          ? 'Pick a device and press Run.  ⌘R hot reload · ⇧⌘R restart'
                          : s.stopped
                              ? 'Stopped'
                              : !s.started
                                  ? (s.progress ?? 'Starting on ${s.deviceName}…')
                                  : 'Running on ${s.deviceName}${s.lastReload != null ? ' · ${s.lastReload}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: c.muted),
                    ),
                  ),
                  if (s != null)
                    TextButton(onPressed: s.clear, child: Text('Clear log', style: TextStyle(fontSize: 12, color: c.muted))),
                ]),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Column(children: [
                    if (s != null && Projects.instance.current != null)
                      SmartBar(lines: s.log, projectPath: Projects.instance.current!.path),
                    Expanded(child: LogView(lines: s?.log ?? const [])),
                  ]),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _dot(C c, RunSession? s) {
    final color = s == null
        ? c.muted
        : s.stopped
            ? c.bad
            : s.started
                ? c.good
                : c.warn;
    return Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }
}
