import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/bench.dart';
import '../../core/devices.dart';
import '../../core/fvm.dart';
import '../../core/jobs.dart';
import '../../core/problems.dart';
import '../../core/projects.dart';
import '../side/run_side.dart';
import '../side/tasks_side.dart';
import '../theme.dart';

/// The open project at a glance: what it is, what it targets, and the things
/// you do most, one click each.
class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key});

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
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

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final pr = Projects.instance.current;
    if (pr == null) return const SizedBox.shrink();
    final (deps, dev) = _deps(pr);
    return ListenableBuilder(
      listenable: Listenable.merge([Projects.instance, Devices.instance, currentTask, Fvm.instance, sdkChanged]),
      builder: (context, _) {
        final busy = currentTask.value?.running ?? false;
        final dev0 = Devices.instance.selected;
        final actions = [
          _Action(
            Icons.play_arrow_rounded,
            'Run',
            dev0 == null ? 'No device' : dev0.name,
            null,
            dev0 == null
                ? null
                : () {
                    startRun();
                  },
          ),
          _Action(
            Icons.construction_rounded,
            'Build',
            'APK · App Bundle · IPA · desktop',
            null,
            () => Bench.instance.showActivity(Activity.build),
          ),
          _Action(
            Icons.download_rounded,
            'Get packages',
            'pub get',
            null,
            busy ? null : () => TasksSide.run('Get packages', ['pub', 'get']),
          ),
          _Action(
            Icons.upgrade_rounded,
            'Upgrade packages',
            'pub upgrade',
            null,
            busy ? null : () => TasksSide.run('Upgrade packages', ['pub', 'upgrade']),
          ),
          _Action(
            Icons.update_rounded,
            'Outdated packages',
            'pub outdated',
            null,
            busy ? null : () => TasksSide.run('Outdated packages', ['pub', 'outdated']),
          ),
          _Action(Icons.rule_rounded, 'Analyze', 'problems in the bottom panel', null, () {
            Bench.instance.showBottom(BottomTab.problems);
            Problems.instance.run(pr.path);
          }),
          _Action(Icons.science_outlined, 'Test', 'flutter test', null, busy ? null : () => TasksSide.run('Test', ['test'])),
          _Action(
            Icons.cleaning_services_outlined,
            'Clean',
            'flutter clean',
            null,
            busy ? null : () => TasksSide.run('Clean', ['clean']),
          ),
        ];
        return ListView(
          padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
          children: [
            // The name, as a heading. No badge, no tile: the name is the identity.
            Text(
              pr.name,
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: c.text),
            ),
            if (pr.description.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(pr.description, style: TextStyle(fontSize: 14, color: c.muted)),
            ],
            const SizedBox(height: 28),

            // Facts, as a two-column table with hairlines.
            _rule(c),
            _fact(c, 'Version', pr.version.isEmpty ? '—' : pr.version),
            if (Fvm.pinFor(pr.path) != null) _pinRow(c, Fvm.pinFor(pr.path)!),
            _fact(c, 'Targets', pr.platforms.isEmpty ? '—' : pr.platforms.map((x) => _platformNames[x] ?? x).join(', ')),
            _fact(c, 'Packages', '$deps, plus $dev for development'),
            _fact(c, 'Location', pr.path, mono: true),
            const SizedBox(height: 34),

            Text(
              'Actions',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text),
            ),
            const SizedBox(height: 8),
            _rule(c),
            for (final a in actions) _actionRow(c, a),
          ],
        );
      },
    );
  }

  /// The pinned Flutter, and a way to get it when it isn't here.
  Widget _pinRow(C c, FvmPin pin) {
    final here = Fvm.instance.sdkDirFor(pin) != null;
    return InkWell(
      onTap: () => Bench.instance.open(const EditorTab(TabKind.fvm)),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.line)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 130,
              child: Text('Flutter', style: TextStyle(fontSize: 13, color: c.muted)),
            ),
            Expanded(
              child: Text(
                here ? '${pin.version}, pinned with FVM' : '${pin.version}, pinned with FVM but not installed',
                style: TextStyle(fontSize: 13, color: here ? c.text : c.warn),
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 16, color: c.muted),
          ],
        ),
      ),
    );
  }

  Widget _rule(C c) => Container(height: 1, color: c.line);

  Widget _fact(C c, String k, String v, {bool mono = false}) => Container(
    padding: const EdgeInsets.symmetric(vertical: 10),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: c.line)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 130,
          child: Text(k, style: TextStyle(fontSize: 13, color: c.muted)),
        ),
        Expanded(
          child: SelectableText(
            v,
            style: mono ? monoStyle.copyWith(fontSize: 12, color: c.text) : TextStyle(fontSize: 13, color: c.text),
          ),
        ),
      ],
    ),
  );

  Widget _actionRow(C c, _Action a) => InkWell(
    onTap: a.onTap,
    hoverColor: c.raised,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Opacity(
        opacity: a.onTap == null ? 0.45 : 1,
        child: Row(
          children: [
            Icon(a.icon, size: 16, color: c.muted),
            const SizedBox(width: 12),
            SizedBox(
              width: 170,
              child: Text(
                a.title,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.text),
              ),
            ),
            Expanded(
              child: Text(
                a.sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: c.muted),
              ),
            ),
            if (a.keys != null) _Kbd(a.keys!),
          ],
        ),
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
      decoration: BoxDecoration(
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(4),
      ),
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
