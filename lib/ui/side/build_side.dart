import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/bench.dart';
import '../../core/jobs.dart';
import '../../core/projects.dart';
import '../../core/sessions.dart';
import '../theme.dart';
import 'side_kit.dart';

class _Target {
  final String id; // the flutter build subcommand
  final String label;
  final String platform; // folder the project needs
  final IconData icon;
  final bool macOnly;
  final bool windowsOnly;
  final String Function(String project, String mode) output;
  const _Target(this.id, this.label, this.platform, this.icon, this.output, {this.macOnly = false, this.windowsOnly = false});
}

String _cap(String s) => s[0].toUpperCase() + s.substring(1);

final _targets = <_Target>[
  _Target(
    'apk',
    'Android APK',
    'android',
    Icons.android_rounded,
    (pr, m) => p.join(pr, 'build', 'app', 'outputs', 'flutter-apk', 'app-$m.apk'),
  ),
  _Target(
    'appbundle',
    'Android App Bundle',
    'android',
    Icons.shop_rounded,
    (pr, m) => p.join(pr, 'build', 'app', 'outputs', 'bundle', m, 'app-$m.aab'),
  ),
  _Target('ipa', 'iOS (IPA)', 'ios', Icons.phone_iphone_rounded, (pr, m) => p.join(pr, 'build', 'ios', 'ipa'), macOnly: true),
  _Target(
    'macos',
    'macOS app',
    'macos',
    Icons.laptop_mac_rounded,
    (pr, m) => p.join(pr, 'build', 'macos', 'Build', 'Products', _cap(m)),
    macOnly: true,
  ),
  _Target(
    'windows',
    'Windows app',
    'windows',
    Icons.desktop_windows_rounded,
    (pr, m) => p.join(pr, 'build', 'windows', 'x64', 'runner', _cap(m)),
    windowsOnly: true,
  ),
  _Target('web', 'Web', 'web', Icons.public_rounded, (pr, m) => p.join(pr, 'build', 'web')),
];

/// Opens [path] in Finder or Explorer, selected when it's a file.
void reveal(String path) {
  final exists = File(path).existsSync() || Directory(path).existsSync();
  final target = exists ? path : p.dirname(path);
  if (Platform.isMacOS) {
    Process.run('open', [if (File(target).existsSync()) '-R', target]);
  } else if (Platform.isWindows) {
    Process.run('explorer', [if (File(target).existsSync()) '/select,$target' else target]);
  } else {
    Process.run('xdg-open', [Directory(target).existsSync() ? target : p.dirname(target)]);
  }
}

/// Pick a target and mode and build. The log is in the bottom panel.
class BuildSide extends StatefulWidget {
  const BuildSide({super.key});

  @override
  State<BuildSide> createState() => _BuildSideState();
}

class _BuildSideState extends State<BuildSide> {
  // Kept for the session, so switching panels doesn't reset them.
  static String _target = 'apk';
  static String _mode = 'release';
  static bool _noTreeShake = false;

  List<_Target> _available(Project pr) => [
    for (final t in _targets)
      if (pr.platforms.contains(t.platform) && (!t.macOnly || Platform.isMacOS) && (!t.windowsOnly || Platform.isWindows)) t,
  ];

  Future<void> _build(Project pr, _Target t) async {
    final mode = _mode;
    final args = [
      'build',
      t.id,
      if (t.id != 'web') '--$mode' else if (mode != 'release') '--$mode',
      if (_noTreeShake) '--no-tree-shake-icons',
    ];
    lastBuildOutput.value = null;
    Bench.instance.showBottom(BottomTab.build);
    final code = await startJob(currentBuild, Job('${t.label} · $mode', args, cwd: pr.path));
    if (code == 0) lastBuildOutput.value = t.output(pr.path, mode);
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final pr = Projects.instance.current;
    if (pr == null) return const SizedBox.shrink();
    final available = _available(pr);
    if (available.isNotEmpty && available.every((t) => t.id != _target)) _target = available.first.id;
    return ValueListenableBuilder<Job?>(
      valueListenable: currentBuild,
      builder: (context, job, _) => ListenableBuilder(
        listenable: Listenable.merge([lastBuildOutput, if (job != null) job]),
        builder: (context, _) {
          final busy = job?.running ?? false;
          return ListView(
            children: [
              const SideTitle('Build'),
              const SideLabel('Target'),
              if (available.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'This project has no platform this computer can build.',
                    style: TextStyle(fontSize: 12, color: c.muted),
                  ),
                ),
              for (final t in available)
                SideRow(
                  icon: t.icon,
                  label: t.label,
                  selected: _target == t.id,
                  onTap: busy ? null : () => setState(() => _target = t.id),
                ),
              const SideLabel('Mode'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'debug',
                      label: Text('Debug', style: TextStyle(fontSize: 12)),
                    ),
                    ButtonSegment(
                      value: 'profile',
                      label: Text('Profile', style: TextStyle(fontSize: 12)),
                    ),
                    ButtonSegment(
                      value: 'release',
                      label: Text('Release', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                  selected: {_mode},
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  onSelectionChanged: busy ? null : (v) => setState(() => _mode = v.first),
                ),
              ),
              const SizedBox(height: 8),
              Tooltip(
                message: 'Skip icon-font subsetting (a workaround when the build hangs on it)',
                child: CheckboxListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  value: _noTreeShake,
                  onChanged: busy ? null : (v) => setState(() => _noTreeShake = v ?? false),
                  title: Text('No icon tree-shaking', style: TextStyle(fontSize: 12.5, color: c.text)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: busy
                    ? OutlinedButton.icon(
                        onPressed: job!.cancel,
                        icon: Icon(Icons.stop_rounded, size: 17, color: c.bad),
                        label: const Text('Cancel build'),
                      )
                    : FilledButton.icon(
                        onPressed: available.isEmpty ? null : () => _build(pr, available.firstWhere((t) => t.id == _target)),
                        icon: const Icon(Icons.construction_rounded, size: 16),
                        label: const Text('Build'),
                      ),
              ),
              if (job != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  child: Row(
                    children: [
                      stateDot(busy ? c.warn : (job.exitCode == 0 ? c.good : c.bad)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${job.title} · ${busy
                              ? 'building'
                              : job.exitCode == 0
                              ? 'done'
                              : 'failed'}',
                          maxLines: 2,
                          style: TextStyle(fontSize: 12, color: c.muted),
                        ),
                      ),
                    ],
                  ),
                ),
              if (lastBuildOutput.value != null && !busy)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
                  child: TextButton.icon(
                    onPressed: () => reveal(lastBuildOutput.value!),
                    icon: const Icon(Icons.folder_open_rounded, size: 15),
                    label: Text('Show ${p.basename(lastBuildOutput.value!)}', style: const TextStyle(fontSize: 12)),
                  ),
                ),
              const SizedBox(height: 12),
            ],
          );
        },
      ),
    );
  }
}
