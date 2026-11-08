import 'package:flutter/material.dart';

import '../../core/bench.dart';
import '../../core/jobs.dart';
import '../../core/problems.dart';
import '../../core/projects.dart';
import '../../core/sessions.dart';
import '../theme.dart';
import 'side_kit.dart';

/// The everyday commands, one click each. Output is in the bottom panel.
class TasksSide extends StatelessWidget {
  const TasksSide({super.key});

  static const tasks = [
    (Icons.download_rounded, 'Get packages', ['pub', 'get']),
    (Icons.upgrade_rounded, 'Upgrade packages', ['pub', 'upgrade']),
    (Icons.update_rounded, 'Outdated packages', ['pub', 'outdated']),
    (Icons.science_outlined, 'Test', ['test']),
    (Icons.auto_fix_high_rounded, 'Apply fixes', ['dart', 'fix', '--apply']),
    (Icons.format_align_left_rounded, 'Format', ['dart', 'format', '.']),
    (Icons.cleaning_services_outlined, 'Clean', ['clean']),
  ];

  /// Runs `flutter <args>` as the current task and shows its output.
  static Future<void> run(String title, List<String> args) async {
    final pr = Projects.instance.current;
    if (pr == null || (currentTask.value?.running ?? false)) return;
    Bench.instance.showBottom(BottomTab.tasks);
    await startJob(currentTask, Job(title, args, cwd: pr.path));
    // Code may have changed: look for problems again.
    if (args.first == 'dart' || args.first == 'pub') Problems.instance.run(pr.path);
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return ValueListenableBuilder<Job?>(
      valueListenable: currentTask,
      builder: (context, job, _) => ListenableBuilder(
        listenable: Listenable.merge([Problems.instance, if (job != null) job]),
        builder: (context, _) {
          final busy = job?.running ?? false;
          final pb = Problems.instance;
          return ListView(
            children: [
              const SideTitle('Tasks'),
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
                onTap: pb.running
                    ? null
                    : () {
                        final pr = Projects.instance.current;
                        if (pr == null) return;
                        Bench.instance.showBottom(BottomTab.problems);
                        pb.run(pr.path);
                      },
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
            ],
          );
        },
      ),
    );
  }
}
