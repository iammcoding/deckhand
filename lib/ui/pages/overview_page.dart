import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/devices.dart';
import '../../core/projects.dart';
import '../../core/sessions.dart';
import '../theme.dart';
import '../widgets/log_view.dart';
import '../widgets/smart_bar.dart';

/// The open project at a glance: what it is, what it targets, and the things
/// you do most, one click each.
class OverviewPage extends StatefulWidget {
  final void Function(int page) go;
  const OverviewPage({super.key, required this.go});

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  static Job? _job;

  static const _platformNames = {
    'android': 'Android',
    'ios': 'iOS',
    'macos': 'macOS',
    'windows': 'Windows',
    'linux': 'Linux',
    'web': 'Web',
  };


  /// Direct dependencies in the pubspec (dependencies + dev_dependencies).
  (int, int) _deps(Project pr) {
    try {
      final lines = File(p.join(pr.path, 'pubspec.yaml')).readAsLinesSync();
      var deps = 0, dev = 0;
      String? section;
      for (final l in lines) {
        if (RegExp(r'^\S').hasMatch(l)) {
          section = l.startsWith('dependencies:')
              ? 'deps'
              : l.startsWith('dev_dependencies:')
                  ? 'dev'
                  : null;
          continue;
        }
        // A package is a key indented by exactly two spaces.
        if (section != null && RegExp(r'^  [a-zA-Z0-9_]+:').hasMatch(l)) {
          if (section == 'deps') deps++;
          if (section == 'dev') dev++;
        }
      }
      return (deps, dev);
    } catch (_) {
      return (0, 0);
    }
  }

  Future<void> _runJob(String title, List<String> args, String cwd) async {
    final job = Job(title, args, cwd: cwd);
    setState(() => _job = job);
    await job.start();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final pr = Projects.instance.current;
    if (pr == null) return const SizedBox.shrink();
    final (deps, dev) = _deps(pr);
    final job = _job;
    return ListenableBuilder(
      listenable: Listenable.merge([Projects.instance, Devices.instance, if (job != null) job]),
      builder: (context, _) {
        final busy = job?.running ?? false;
        final dev0 = Devices.instance.selected;
        final actions = [
          _Action(Icons.play_arrow_rounded, 'Run', dev0 == null ? 'No device' : dev0.name, '⌘2', () => widget.go(2)),
          _Action(Icons.construction_rounded, 'Build', 'APK · App Bundle · IPA · desktop', '⌘3', () => widget.go(3)),
          _Action(Icons.download_rounded, 'Get packages', 'pub get', null,
              busy ? null : () => _runJob('Get packages', ['pub', 'get'], pr.path)),
          _Action(Icons.upgrade_rounded, 'Upgrade packages', 'pub upgrade', null,
              busy ? null : () => _runJob('Upgrade packages', ['pub', 'upgrade'], pr.path)),
          _Action(Icons.update_rounded, 'Outdated packages', 'pub outdated', null,
              busy ? null : () => _runJob('Outdated packages', ['pub', 'outdated'], pr.path)),
          _Action(Icons.rule_rounded, 'Analyze', 'flutter analyze', null,
              busy ? null : () => _runJob('Analyze', ['analyze'], pr.path)),
          _Action(Icons.science_outlined, 'Test', 'flutter test', null, busy ? null : () => _runJob('Test', ['test'], pr.path)),
          _Action(Icons.cleaning_services_outlined, 'Clean', 'flutter clean', null,
              busy ? null : () => _runJob('Clean', ['clean'], pr.path)),
        ];
        return ListView(padding: const EdgeInsets.fromLTRB(32, 40, 32, 32), children: [
          // The name, as a heading. No badge, no tile: the name is the identity.
          Text(pr.name, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: c.text)),
          if (pr.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(pr.description, style: TextStyle(fontSize: 14, color: c.muted)),
          ],
          const SizedBox(height: 28),

          // Facts, as a two-column table with hairlines.
          _rule(c),
          _fact(c, 'Version', pr.version.isEmpty ? '—' : pr.version),
          _fact(c, 'Targets', pr.platforms.isEmpty ? '—' : pr.platforms.map((x) => _platformNames[x] ?? x).join(', ')),
          _fact(c, 'Packages', '$deps, plus $dev for development'),
          _fact(c, 'Location', pr.path, mono: true),
          const SizedBox(height: 34),

          Text('Actions', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text)),
          const SizedBox(height: 8),
          _rule(c),
          for (final a in actions) _actionRow(c, a),

          if (job != null) ...[
            const SizedBox(height: 30),
            Row(children: [
              Text(job.title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text)),
              const SizedBox(width: 8),
              Text(
                busy ? 'running' : (job.exitCode == 0 ? 'done' : 'failed'),
                style: TextStyle(fontSize: 12, color: busy ? c.muted : (job.exitCode == 0 ? c.good : c.bad)),
              ),
              const Spacer(),
              if (busy) TextButton(onPressed: job.cancel, child: Text('Cancel', style: TextStyle(fontSize: 12, color: c.bad))),
            ]),
            const SizedBox(height: 8),
            SmartBar(lines: job.log, projectPath: pr.path),
            SizedBox(height: 300, child: LogView(lines: job.log)),
          ],
        ]);
      },
    );
  }

  Widget _rule(C c) => Container(height: 1, color: c.line);

  Widget _fact(C c, String k, String v, {bool mono = false}) => Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 130, child: Text(k, style: TextStyle(fontSize: 13, color: c.muted))),
          Expanded(
            child: SelectableText(v,
                style: mono ? monoStyle.copyWith(fontSize: 12, color: c.text) : TextStyle(fontSize: 13, color: c.text)),
          ),
        ]),
      );

  Widget _actionRow(C c, _Action a) => InkWell(
        onTap: a.onTap,
        hoverColor: c.raised,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
          child: Opacity(
            opacity: a.onTap == null ? 0.45 : 1,
            child: Row(children: [
              Icon(a.icon, size: 16, color: c.muted),
              const SizedBox(width: 12),
              SizedBox(width: 170, child: Text(a.title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.text))),
              Expanded(child: Text(a.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: c.muted))),
              if (a.keys != null) _Kbd(a.keys!),
            ]),
          ),
        ),
      );
}

/// A keyboard shortcut, drawn like a key.
class _Kbd extends StatelessWidget {
  final String keys;
  const _Kbd(this.keys);

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(border: Border.all(color: c.line), borderRadius: BorderRadius.circular(4)),
      child: Text(keys, style: TextStyle(fontSize: 11, color: c.muted)),
    );
  }
}

class _Action {
  final IconData icon;
  final String title;
  final String sub;
  final String? keys;
  final VoidCallback? onTap;
  const _Action(this.icon, this.title, this.sub, this.keys, this.onTap);
}
