import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/bench.dart';
import '../../core/jobs.dart';
import '../../core/problems.dart';
import '../../core/projects.dart';
import '../../core/sessions.dart';
import '../theme.dart';
import '../widgets/log_view.dart';
import '../widgets/smart_bar.dart';

/// Under the editor: the run log, the build log, the last task, and the
/// analyzer's problems. Each log keeps its Fix and Ask AI bar.
class BottomPanel extends StatelessWidget {
  const BottomPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final b = Bench.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([currentRun, currentBuild, currentTask, currentLogs, currentPreview, Problems.instance]),
      builder: (context, _) {
        final pb = Problems.instance;
        return Container(
          color: c.panel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 36,
                child: Row(
                  children: [
                    const SizedBox(width: 6),
                    _tab(c, BottomTab.run, 'Console', dot: _runDot(c)),
                    _tab(c, BottomTab.build, 'Build', dot: _jobDot(c, currentBuild.value)),
                    _tab(c, BottomTab.tasks, 'Tasks', dot: _jobDot(c, currentTask.value)),
                    _tab(
                      c,
                      BottomTab.problems,
                      'Problems',
                      count: pb.errors + pb.warnings,
                      countColor: pb.errors > 0 ? c.bad : c.warn,
                    ),
                    // Long-running ones get a tab only while they exist.
                    if (currentLogs.value != null) _tab(c, BottomTab.logs, 'Device log', dot: _jobDot(c, currentLogs.value)),
                    if (currentPreview.value != null)
                      _tab(c, BottomTab.preview, 'Previews', dot: _jobDot(c, currentPreview.value)),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Hide console  ⌘J',
                      iconSize: 15,
                      visualDensity: VisualDensity.compact,
                      onPressed: b.toggleBottom,
                      icon: const Icon(Icons.close_rounded),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: switch (b.bottom) {
                    BottomTab.run => _RunLog(currentRun.value),
                    BottomTab.build => _JobLog(currentBuild.value, empty: 'Builds show here. Pick a target in Build.'),
                    BottomTab.tasks => _JobLog(currentTask.value, empty: 'Tasks show here: pub get, test, clean.'),
                    BottomTab.problems => const _ProblemList(),
                    BottomTab.logs => _JobLog(currentLogs.value, empty: 'Open a device\'s log from Devices.', live: currentLogs),
                    BottomTab.preview => _JobLog(
                      currentPreview.value,
                      empty: 'Start widget previews from Tasks.',
                      live: currentPreview,
                    ),
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget? _runDot(C c) {
    final s = currentRun.value;
    if (s == null) return null;
    return _dot(s.stopped ? c.muted : (s.started ? c.good : c.warn));
  }

  Widget? _jobDot(C c, Job? j) {
    if (j == null) return null;
    return _dot(j.running ? c.warn : (j.exitCode == 0 ? c.good : c.bad));
  }

  Widget _dot(Color color) => Container(
    width: 6,
    height: 6,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );

  Widget _tab(C c, BottomTab t, String label, {Widget? dot, int count = 0, Color? countColor}) {
    final on = Bench.instance.bottom == t;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => Bench.instance.showBottom(t),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 1),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(color: on ? c.raised : null, borderRadius: BorderRadius.circular(6)),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 12, fontWeight: on ? FontWeight.w600 : FontWeight.w500, color: on ? c.text : c.muted),
            ),
            if (dot != null) ...[const SizedBox(width: 6), dot],
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(color: countColor?.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(8)),
                child: Text(
                  '$count',
                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: countColor),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RunLog extends StatelessWidget {
  final RunSession? s;
  const _RunLog(this.s);

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final s = this.s;
    final pr = Projects.instance.current;
    if (s == null) return _empty(c, 'Press Run at the top. The app\'s log shows here.');
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Column(
        children: [
          if (pr != null) _limited(SmartBar(lines: s.log, projectPath: pr.path)),
          Expanded(child: LogView(lines: s.log)),
        ],
      ),
    );
  }
}

class _JobLog extends StatelessWidget {
  final Job? job;
  final String empty;

  /// For a job that runs until stopped: a Stop button, and Close to drop
  /// its tab.
  final ValueNotifier<Job?>? live;
  const _JobLog(this.job, {required this.empty, this.live});

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final j = job;
    final pr = Projects.instance.current;
    if (j == null) return _empty(c, empty);
    return ListenableBuilder(
      listenable: j,
      builder: (context, _) => Column(
        children: [
          if (live != null)
            SizedBox(
              height: 30,
              child: Row(
                children: [
                  Text(j.title, style: TextStyle(fontSize: 12, color: c.muted)),
                  const Spacer(),
                  if (j.running)
                    TextButton(
                      onPressed: j.cancel,
                      child: Text('Stop', style: TextStyle(fontSize: 12, color: c.bad)),
                    )
                  else
                    TextButton(
                      onPressed: () {
                        live!.value = null;
                        Bench.instance.showBottom(BottomTab.run);
                      },
                      child: const Text('Close', style: TextStyle(fontSize: 12)),
                    ),
                ],
              ),
            ),
          if (pr != null && live == null) _limited(SmartBar(lines: j.log, projectPath: pr.path)),
          Expanded(child: LogView(lines: j.log)),
        ],
      ),
    );
  }
}

/// The fix bar can grow (an answer, a command's output); in a short panel it
/// scrolls rather than pushing the log out.
Widget _limited(Widget child) => ConstrainedBox(
  constraints: const BoxConstraints(maxHeight: 260),
  child: SingleChildScrollView(child: child),
);

Widget _empty(C c, String text) => Center(
  child: Text(text, style: TextStyle(color: c.muted, fontSize: 12.5)),
);

class _ProblemList extends StatelessWidget {
  const _ProblemList();

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final pb = Problems.instance;
    final pr = Projects.instance.current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              pb.running
                  ? 'Analyzing…'
                  : pb.error != null
                  ? pb.error!
                  : pb.at == null
                  ? 'Not analyzed yet'
                  : '${pb.errors} errors, ${pb.warnings} warnings, ${pb.list.length - pb.errors - pb.warnings} infos',
              style: TextStyle(fontSize: 12, color: pb.error != null ? c.bad : c.muted),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: pb.running || pr == null ? null : () => pb.run(pr.path),
              icon: const Icon(Icons.refresh_rounded, size: 15),
              label: const Text('Analyze', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        Expanded(
          child: pb.list.isEmpty
              ? _empty(c, pb.at == null ? '' : 'No problems.')
              : ListView.builder(
                  itemCount: pb.list.length,
                  itemExtent: 24,
                  itemBuilder: (_, i) {
                    final x = pb.list[i];
                    final color = switch (x.severity) {
                      'ERROR' => c.bad,
                      'WARNING' => c.warn,
                      _ => c.accent,
                    };
                    final rel = pr != null && p.isWithin(pr.path, x.file) ? p.relative(x.file, from: pr.path) : x.file;
                    return InkWell(
                      onTap: () => Bench.instance.openFile(x.file, line: x.line),
                      child: Row(
                        children: [
                          Icon(
                            x.severity == 'ERROR'
                                ? Icons.error_outline_rounded
                                : x.severity == 'WARNING'
                                ? Icons.warning_amber_rounded
                                : Icons.info_outline_rounded,
                            size: 14,
                            color: color,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: x.message,
                                    style: TextStyle(color: c.text),
                                  ),
                                  TextSpan(
                                    text: '  ${x.code}',
                                    style: TextStyle(color: c.muted),
                                  ),
                                  TextSpan(
                                    text: '  $rel:${x.line}:${x.column}',
                                    style: TextStyle(color: c.muted),
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
