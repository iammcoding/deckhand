import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/projects.dart';
import '../../core/sessions.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets/log_view.dart';
import '../widgets/smart_bar.dart';

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
  _Target('apk', 'Android APK', 'android', Icons.android_rounded,
      (pr, m) => p.join(pr, 'build', 'app', 'outputs', 'flutter-apk', 'app-$m.apk')),
  _Target('appbundle', 'Android App Bundle', 'android', Icons.shop_rounded,
      (pr, m) => p.join(pr, 'build', 'app', 'outputs', 'bundle', m, 'app-$m.aab')),
  _Target('ipa', 'iOS (IPA)', 'ios', Icons.phone_iphone_rounded, (pr, m) => p.join(pr, 'build', 'ios', 'ipa'), macOnly: true),
  _Target('macos', 'macOS app', 'macos', Icons.laptop_mac_rounded,
      (pr, m) => p.join(pr, 'build', 'macos', 'Build', 'Products', _cap(m)), macOnly: true),
  _Target('windows', 'Windows app', 'windows', Icons.desktop_windows_rounded,
      (pr, m) => p.join(pr, 'build', 'windows', 'x64', 'runner', _cap(m)), windowsOnly: true),
  _Target('web', 'Web', 'web', Icons.public_rounded, (pr, m) => p.join(pr, 'build', 'web')),
];

/// Builds: pick a target and mode, watch it, open what it made.
class BuildPage extends StatefulWidget {
  const BuildPage({super.key});

  @override
  State<BuildPage> createState() => _BuildPageState();
}

class _BuildPageState extends State<BuildPage> {
  static Job? _job;
  static _Target? _jobTarget;
  static String _jobMode = 'release';
  String _target = 'apk';
  String _mode = 'release';
  bool _noTreeShake = false;

  List<_Target> _available(Project pr) => [
        for (final t in _targets)
          if (pr.platforms.contains(t.platform) && (!t.macOnly || Platform.isMacOS) && (!t.windowsOnly || Platform.isWindows)) t,
      ];

  Future<void> _build(Project pr, _Target t) async {
    final args = [
      'build',
      t.id,
      if (t.id != 'web') '--$_mode' else if (_mode != 'release') '--$_mode',
      if (_noTreeShake) '--no-tree-shake-icons',
    ];
    final job = Job('${t.label} · $_mode', args, cwd: pr.path);
    setState(() {
      _job = job;
      _jobTarget = t;
      _jobMode = _mode;
    });
    await job.start();
    if (mounted) setState(() {});
  }

  void _reveal(String path) {
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

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final pr = Projects.instance.current;
    if (pr == null) return const SizedBox.shrink();
    final available = _available(pr);
    if (available.isNotEmpty && available.every((t) => t.id != _target)) _target = available.first.id;
    final job = _job;
    return ListenableBuilder(
      listenable: Listenable.merge([Projects.instance, if (job != null) job]),
      builder: (context, _) {
        final busy = job?.running ?? false;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          PageHeader(
            title: 'Build',
            subtitle: '${pr.name} ${pr.version}',
            actions: [
              if (busy)
                OutlinedButton.icon(
                  onPressed: job!.cancel,
                  icon: Icon(Icons.stop_rounded, size: 17, color: c.bad),
                  label: const Text('Cancel'),
                )
              else
                FilledButton.icon(
                  onPressed: available.isEmpty ? null : () => _build(pr, available.firstWhere((t) => t.id == _target)),
                  icon: const Icon(Icons.construction_rounded, size: 16),
                  label: const Text('Build'),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
            child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final t in available)
                ChoiceChip(
                  avatar: Icon(t.icon, size: 15),
                  label: Text(t.label, style: const TextStyle(fontSize: 12.5)),
                  selected: _target == t.id,
                  showCheckmark: false,
                  onSelected: busy ? null : (_) => setState(() => _target = t.id),
                ),
              if (available.isEmpty)
                Text("This project has no platform this computer can build.", style: TextStyle(color: c.muted)),
              const SizedBox(width: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'debug', label: Text('Debug')),
                  ButtonSegment(value: 'profile', label: Text('Profile')),
                  ButtonSegment(value: 'release', label: Text('Release')),
                ],
                selected: {_mode},
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                onSelectionChanged: busy ? null : (v) => setState(() => _mode = v.first),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: 'Skip icon-font subsetting (a workaround when the build hangs on it)',
                child: FilterChip(
                  label: const Text('No icon tree-shaking', style: TextStyle(fontSize: 12.5)),
                  selected: _noTreeShake,
                  showCheckmark: false,
                  onSelected: busy ? null : (v) => setState(() => _noTreeShake = v),
                ),
              ),
            ]),
          ),
          if (job != null && !busy && job.exitCode == 0 && _jobTarget != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: c.good.withValues(alpha: 0.08),
                  border: Border.all(color: c.good.withValues(alpha: 0.4)),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Row(children: [
                  Icon(Icons.check_circle_rounded, color: c.good, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_jobTarget!.output(pr.path, _jobMode),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: mono.copyWith(color: c.text)),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _reveal(_jobTarget!.output(pr.path, _jobMode)),
                    icon: const Icon(Icons.folder_open_rounded, size: 16),
                    label: const Text('Show'),
                  ),
                ]),
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(children: [
                if (job != null) SmartBar(lines: job.log, projectPath: pr.path),
                Expanded(child: LogView(lines: job?.log ?? const [])),
              ]),
            ),
          ),
        ]);
      },
    );
  }
}
