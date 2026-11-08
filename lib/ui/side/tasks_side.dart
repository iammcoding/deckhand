import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/bench.dart';
import '../../core/devices.dart';
import '../../core/jobs.dart';
import '../../core/problems.dart';
import '../../core/projects.dart';
import '../../core/sessions.dart';
import '../theme.dart';
import 'side_kit.dart';

/// The everyday commands, one click each, and the occasional ones with a
/// short form first. Output is in the console.
class TasksSide extends StatelessWidget {
  const TasksSide({super.key});

  static const tasks = [
    (Icons.download_rounded, 'Get packages', ['pub', 'get']),
    (Icons.upgrade_rounded, 'Upgrade packages', ['pub', 'upgrade']),
    (Icons.update_rounded, 'Outdated packages', ['pub', 'outdated']),
    (Icons.science_outlined, 'Test', ['test']),
    (Icons.translate_rounded, 'Generate translations', ['gen-l10n']),
    (Icons.auto_fix_high_rounded, 'Apply fixes', ['dart', 'fix', '--apply']),
    (Icons.format_align_left_rounded, 'Format', ['dart', 'format', '.']),
    (Icons.cleaning_services_outlined, 'Clean', ['clean']),
  ];

  /// Runs `flutter <args>` in the project as the current task.
  static Future<void> run(String title, List<String> args) async {
    final pr = Projects.instance.current;
    if (pr == null) return;
    final code = await runTask(title, args, cwd: pr.path);
    // Code may have changed: look for problems again.
    if (code != null && const {'dart', 'pub', 'gen-l10n'}.contains(args.first)) Problems.instance.run(pr.path);
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final pr = Projects.instance.current;
    return ListenableBuilder(
      listenable: Listenable.merge([currentTask, currentPreview, Problems.instance, Devices.instance]),
      builder: (context, _) {
        final job = currentTask.value;
        return ListenableBuilder(
          listenable: Listenable.merge([if (job != null) job, if (currentPreview.value != null) currentPreview.value!]),
          builder: (context, _) {
            final busy = job?.running ?? false;
            final pb = Problems.instance;
            final preview = currentPreview.value;
            final previewing = preview?.running ?? false;
            final hasIntegration = pr != null && Directory(p.join(pr.path, 'integration_test')).existsSync();
            final dev = Devices.instance.selected;
            return ListView(
              children: [
                const SideTitle('Everyday'),
                for (final (icon, title, args) in tasks)
                  SideRow(
                    icon: icon,
                    label: title,
                    detail: args.first == 'dart' ? args.join(' ') : 'flutter ${args.join(' ')}',
                    trailing: busy && job?.title == title ? stateDot(c.warn) : null,
                    onTap: busy ? null : () => run(title, args),
                  ),
                SideRow(
                  icon: Icons.rule_rounded,
                  label: 'Analyze',
                  detail: pb.running ? 'running…' : '${pb.errors} errors · ${pb.warnings} warnings',
                  trailing: pb.running ? stateDot(c.warn) : null,
                  onTap: pb.running || pr == null
                      ? null
                      : () {
                          Bench.instance.showBottom(BottomTab.problems);
                          pb.run(pr.path);
                        },
                ),
                const SizedBox(height: 10),
                const SideTitle('Testing on a device'),
                SideRow(
                  icon: Icons.integration_instructions_outlined,
                  label: 'Integration tests',
                  detail: !hasIntegration ? 'no integration_test folder' : (dev == null ? 'no device' : 'on ${dev.name}'),
                  onTap: busy || !hasIntegration || dev == null
                      ? null
                      : () => run('Integration tests', ['test', 'integration_test', '-d', dev.id]),
                ),
                SideRow(
                  icon: Icons.drive_eta_outlined,
                  label: 'Drive…',
                  detail: 'flutter drive',
                  onTap: busy || pr == null ? null : () => _drive(context, pr.path),
                ),
                const SizedBox(height: 10),
                const SideTitle('Tools'),
                SideRow(
                  icon: Icons.view_quilt_outlined,
                  label: previewing ? 'Stop widget previews' : 'Widget previews',
                  detail: previewing ? 'running' : 'flutter widget-preview',
                  trailing: previewing ? stateDot(c.good) : null,
                  onTap: pr == null
                      ? null
                      : () {
                          if (previewing) {
                            preview!.cancel();
                          } else {
                            Bench.instance.showBottom(BottomTab.preview);
                            startJob(currentPreview, Job('Widget previews', ['widget-preview', 'start'], cwd: pr.path));
                          }
                        },
                ),
                SideRow(
                  icon: Icons.delete_sweep_outlined,
                  label: 'Clear widget previews',
                  detail: 'widget-preview clean',
                  onTap: busy || previewing ? null : () => run('Clear widget previews', ['widget-preview', 'clean']),
                ),
                SideRow(
                  icon: Icons.bug_report_outlined,
                  label: 'Read a crash…',
                  detail: 'flutter symbolize',
                  onTap: busy ? null : () => _symbolize(context),
                ),
                if (busy)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 12, 0),
                    child: TextButton.icon(
                      onPressed: job!.cancel,
                      icon: Icon(Icons.stop_rounded, size: 16, color: c.bad),
                      label: Text('Cancel ${job.title.toLowerCase()}', style: TextStyle(fontSize: 12, color: c.bad)),
                    ),
                  ),
                const SizedBox(height: 12),
              ],
            );
          },
        );
      },
    );
  }

  /// `flutter drive`: an app entry point and a driver script, on a device.
  static Future<void> _drive(BuildContext context, String root) async {
    List<String> dartIn(String dir) {
      final d = Directory(p.join(root, dir));
      if (!d.existsSync()) return const [];
      return [
        for (final f in d.listSync(recursive: true))
          if (f is File && f.path.endsWith('.dart')) p.relative(f.path, from: root),
      ]..sort();
    }

    final drivers = dartIn('test_driver');
    final targets = {
      'lib/main.dart',
      ...dartIn('integration_test'),
      ...dartIn('test_driver').where((f) => !f.endsWith('_test.dart')),
    }.where((f) => File(p.join(root, f)).existsSync()).toList();
    final devices = Devices.instance.list;
    final c = C.of(context);
    if (drivers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('flutter drive needs a driver script in test_driver/. For integration_test, use Integration tests.'),
        ),
      );
      return;
    }
    var driver = drivers.first;
    var target = targets.firstWhere((t) => t.startsWith('integration_test'), orElse: () => targets.first);
    var device = Devices.instance.selected?.id ?? devices.firstOrNull?.id;
    var mode = 'debug';
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) {
              Widget pick(
                String label,
                String? value,
                List<String> items,
                ValueChanged<String> set, {
                Map<String, String>? names,
              }) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    SizedBox(
                      width: 80,
                      child: Text(label, style: TextStyle(fontSize: 13, color: c.muted)),
                    ),
                    Expanded(
                      child: DropdownButton<String>(
                        value: value,
                        isExpanded: true,
                        isDense: true,
                        dropdownColor: c.panel,
                        style: TextStyle(fontSize: 13, color: c.text),
                        items: [for (final i in items) DropdownMenuItem(value: i, child: Text(names?[i] ?? i))],
                        onChanged: (v) => v == null ? null : setD(() => set(v)),
                      ),
                    ),
                  ],
                ),
              );
              return AlertDialog(
                backgroundColor: c.panel,
                title: Text('Drive', style: TextStyle(fontSize: 16, color: c.text)),
                content: SizedBox(
                  width: 460,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      pick('App', target, targets, (v) => target = v),
                      pick('Driver', driver, drivers, (v) => driver = v),
                      pick(
                        'Device',
                        device,
                        [for (final d in devices) d.id],
                        (v) => device = v,
                        names: {for (final d in devices) d.id: d.name},
                      ),
                      pick('Mode', mode, const ['debug', 'profile', 'release'], (v) => mode = v),
                    ],
                  ),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                  FilledButton(onPressed: device == null ? null : () => Navigator.pop(ctx, true), child: const Text('Drive')),
                ],
              );
            },
          ),
        ) ??
        false;
    if (!ok || device == null) return;
    run('Drive', ['drive', '--target=$target', '--driver=$driver', '-d', device!, '--$mode']);
  }

  /// `flutter symbolize`: turn an obfuscated release stack trace back into
  /// file and line, with the symbols saved by --split-debug-info.
  static Future<void> _symbolize(BuildContext context) async {
    final c = C.of(context);
    final trace = TextEditingController();
    String? symbols;
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
              backgroundColor: c.panel,
              title: Text('Read a crash', style: TextStyle(fontSize: 16, color: c.text)),
              content: SizedBox(
                width: 560,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'For release builds made with --split-debug-info. Paste the stack trace from the crash report and pick '
                      'the matching .symbols file (for example app.android-arm64.symbols).',
                      style: TextStyle(fontSize: 12.5, height: 1.4, color: c.muted),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 220,
                      child: TextField(
                        controller: trace,
                        onChanged: (_) => setD(() {}),
                        maxLines: null,
                        expands: true,
                        style: monoStyle.copyWith(fontSize: 11.5, color: c.text),
                        decoration: InputDecoration(
                          hintText: 'Paste the stack trace',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                          contentPadding: const EdgeInsets.all(10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            symbols ?? 'No symbols file chosen',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: monoStyle.copyWith(fontSize: 11.5, color: c.muted),
                          ),
                        ),
                        TextButton(
                          onPressed: () async {
                            final f = await openFile(
                              acceptedTypeGroups: const [
                                XTypeGroup(label: 'Symbols', extensions: ['symbols']),
                                XTypeGroup(label: 'Any file'),
                              ],
                            );
                            if (f != null) setD(() => symbols = f.path);
                          },
                          child: const Text('Choose…'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(
                  onPressed: symbols == null || trace.text.trim().isEmpty ? null : () => Navigator.pop(ctx, true),
                  child: const Text('Read it'),
                ),
              ],
            ),
          ),
        ) ??
        false;
    final text = trace.text;
    trace.dispose();
    if (!ok || symbols == null) return;
    final input = File(p.join(Directory.systemTemp.path, 'deckhand-trace-${DateTime.now().millisecondsSinceEpoch}.txt'));
    await input.writeAsString(text);
    await runTask('Read a crash', ['symbolize', '-d', symbols!, '-i', input.path]);
    try {
      await input.delete();
    } catch (_) {}
  }
}
