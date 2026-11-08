import 'package:flutter/material.dart';

import '../../core/devices.dart';
import '../shell.dart';
import '../theme.dart';

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});

  static IconData _icon(Device d) => switch (d.family) {
        'android' => Icons.android_rounded,
        'ios' => Icons.phone_iphone_rounded,
        'macos' => Icons.laptop_mac_rounded,
        'windows' => Icons.desktop_windows_rounded,
        'linux' => Icons.terminal_rounded,
        'web' => Icons.public_rounded,
        _ => Icons.devices_other_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return ListenableBuilder(
      listenable: Devices.instance,
      builder: (context, _) {
        final d = Devices.instance;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          PageHeader(
            title: 'Devices',
            subtitle: 'Phones, simulators and this computer, as Flutter sees them.',
            actions: [
              OutlinedButton.icon(
                onPressed: d.refresh,
                icon: d.loading
                    ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: c.muted))
                    : const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Refresh'),
              ),
            ],
          ),
          if (d.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(d.error!, style: TextStyle(color: c.bad, fontSize: 12.5)),
            ),
          Expanded(
            child: d.list.isEmpty
                ? Center(
                    child: Text(d.loading ? 'Looking for devices…' : 'No devices. Plug in a phone or start a simulator.',
                        style: TextStyle(color: c.muted)),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    itemCount: d.list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final dev = d.list[i];
                      final on = d.selected?.id == dev.id;
                      return Material(
                        color: c.panel,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(color: on ? c.accent.withValues(alpha: 0.6) : c.line),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => d.select(dev.id),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(children: [
                              Icon(_icon(dev), size: 22, color: on ? c.accent : c.muted),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(dev.name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.text)),
                                  const SizedBox(height: 2),
                                  Text('${dev.sdk}${dev.emulator ? ' · simulator' : ''}',
                                      style: TextStyle(fontSize: 12, color: c.muted)),
                                ]),
                              ),
                              Text(dev.id, style: mono.copyWith(fontSize: 11, color: c.muted)),
                              if (on) ...[
                                const SizedBox(width: 12),
                                Icon(Icons.check_circle_rounded, size: 18, color: c.accent),
                              ],
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ]);
      },
    );
  }
}
