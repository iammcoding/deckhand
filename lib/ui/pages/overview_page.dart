import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/devices.dart';
import '../../core/projects.dart';
import '../../core/sdk.dart';
import '../../core/sessions.dart';
import '../theme.dart';
import '../widgets/log_view.dart';

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

  static const _platformIcons = {
    'android': Icons.android_rounded,
    'ios': Icons.phone_iphone_rounded,
    'macos': Icons.laptop_mac_rounded,
    'windows': Icons.desktop_windows_rounded,
    'linux': Icons.terminal_rounded,
    'web': Icons.public_rounded,
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
        return ListView(padding: const EdgeInsets.fromLTRB(28, 34, 28, 28), children: [
          // Who this project is.
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.accent.withValues(alpha: 0.3)),
              ),
              child: Text(pr.name.isEmpty ? '?' : pr.name[0].toUpperCase(),
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: c.accent)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(pr.name, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: c.text)),
                const SizedBox(height: 4),
                if (pr.description.isNotEmpty)
                  Text(pr.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: c.muted)),
                const SizedBox(height: 6),
                SelectableText(pr.path, style: mono.copyWith(fontSize: 11.5, color: c.muted)),
              ]),
            ),
          ]),
          const SizedBox(height: 22),

          // The numbers.
          Row(children: [
            _stat(c, 'Version', pr.version.isEmpty ? '—' : pr.version),
            _stat(c, 'Platforms', '${pr.platforms.length}'),
            _stat(c, 'Packages', '$deps'),
            _stat(c, 'Dev packages', '$dev'),
          ]),
          const SizedBox(height: 22),

          // Platforms.
          _label(c, 'TARGETS'),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final pl in _platformNames.keys)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                decoration: BoxDecoration(
                  color: pr.platforms.contains(pl) ? c.panel : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: pr.platforms.contains(pl) ? c.line : c.line.withValues(alpha: 0.5)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_platformIcons[pl], size: 15, color: pr.platforms.contains(pl) ? c.text : c.muted.withValues(alpha: 0.5)),
                  const SizedBox(width: 7),
                  Text(_platformNames[pl]!,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: pr.platforms.contains(pl) ? c.text : c.muted.withValues(alpha: 0.5))),
                ]),
              ),
          ]),
          const SizedBox(height: 26),

          // What you do most.
          _label(c, 'QUICK ACTIONS'),
          const SizedBox(height: 10),
          LayoutBuilder(builder: (context, box) {
            final cols = box.maxWidth > 900 ? 4 : (box.maxWidth > 600 ? 3 : 2);
            final w = (box.maxWidth - (cols - 1) * 10) / cols;
            final actions = [
              _Action(Icons.play_arrow_rounded, 'Run',
                  Devices.instance.selected == null ? 'No device' : 'on ${Devices.instance.selected!.name}', c.good, () => widget.go(2)),
              _Action(Icons.construction_rounded, 'Build', 'APK, App Bundle, IPA, desktop', c.accent, () => widget.go(3)),
              _Action(Icons.download_rounded, 'Get packages', 'flutter pub get', c.text,
                  busy ? null : () => _runJob('Get packages', ['pub', 'get'], pr.path)),
              _Action(Icons.upgrade_rounded, 'Upgrade packages', 'flutter pub upgrade', c.text,
                  busy ? null : () => _runJob('Upgrade packages', ['pub', 'upgrade'], pr.path)),
              _Action(Icons.cleaning_services_rounded, 'Clean', 'flutter clean', c.warn,
                  busy ? null : () => _runJob('Clean', ['clean'], pr.path)),
              _Action(Icons.rule_rounded, 'Analyze', 'flutter analyze', c.text,
                  busy ? null : () => _runJob('Analyze', ['analyze'], pr.path)),
              _Action(Icons.science_outlined, 'Test', 'flutter test', c.text,
                  busy ? null : () => _runJob('Test', ['test'], pr.path)),
              _Action(Icons.update_rounded, 'Outdated', 'flutter pub outdated', c.text,
                  busy ? null : () => _runJob('Outdated packages', ['pub', 'outdated'], pr.path)),
            ];
            return Wrap(spacing: 10, runSpacing: 10, children: [
              for (final a in actions) SizedBox(width: w, child: _actionTile(c, a)),
            ]);
          }),

          if (job != null) ...[
            const SizedBox(height: 22),
            Row(children: [
              _label(c, job.title.toUpperCase()),
              const SizedBox(width: 10),
              if (busy)
                SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: c.muted))
              else
                Icon(job.exitCode == 0 ? Icons.check_circle_rounded : Icons.cancel_rounded,
                    size: 15, color: job.exitCode == 0 ? c.good : c.bad),
              const Spacer(),
              if (busy) TextButton(onPressed: job.cancel, child: Text('Cancel', style: TextStyle(color: c.bad))),
            ]),
            const SizedBox(height: 8),
            SizedBox(height: 300, child: LogView(lines: job.log)),
          ],
          const SizedBox(height: 18),
          Text(Sdk.instance.flutterBin ?? '', style: mono.copyWith(fontSize: 11, color: c.muted.withValues(alpha: 0.6))),
        ]);
      },
    );
  }

  Widget _label(C c, String t) =>
      Text(t, style: TextStyle(fontSize: 11, letterSpacing: 1.1, fontWeight: FontWeight.w700, color: c.muted));

  Widget _stat(C c, String label, String value) => Expanded(
        child: Container(
          margin: const EdgeInsets.only(right: 10),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(color: c.panel, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.line)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 11.5, color: c.muted)),
            const SizedBox(height: 4),
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.text)),
          ]),
        ),
      );

  Widget _actionTile(C c, _Action a) => Material(
        color: c.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: c.line)),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: a.onTap,
          child: Opacity(
            opacity: a.onTap == null ? 0.5 : 1,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(color: a.tint.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                  child: Icon(a.icon, size: 18, color: a.tint),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(a.title, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.text)),
                    const SizedBox(height: 2),
                    Text(a.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: c.muted)),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      );
}

class _Action {
  final IconData icon;
  final String title;
  final String sub;
  final Color tint;
  final VoidCallback? onTap;
  const _Action(this.icon, this.title, this.sub, this.tint, this.onTap);
}
