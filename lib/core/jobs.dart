import 'package:flutter/foundation.dart';

import 'bench.dart';
import 'sessions.dart';

/// The latest build and the latest task (pub get, clean, upgrade…), shared by
/// the panels that start them and the console that shows them.
final currentBuild = ValueNotifier<Job?>(null);
final currentTask = ValueNotifier<Job?>(null);

/// A device's log (`flutter logs`), which runs until stopped.
final currentLogs = ValueNotifier<Job?>(null);

/// The widget previewer (`flutter widget-preview start`), until stopped.
final currentPreview = ValueNotifier<Job?>(null);

/// Where the last successful build put its output, for Show.
final lastBuildOutput = ValueNotifier<String?>(null);

/// Bumped when the SDK changes (channel, upgrade, downgrade), so whatever
/// shows the version reads it again.
final sdkChanged = ValueNotifier<int>(0);

/// Starts [job] as the current build or task, and returns when it ends.
Future<int> startJob(ValueNotifier<Job?> slot, Job job) {
  slot.value = job;
  return job.start();
}

/// Runs `flutter <args>` as the current task and shows it in the console.
/// Returns its exit code, or null if another task is still running.
Future<int?> runTask(String title, List<String> args, {String? cwd}) async {
  if (currentTask.value?.running ?? false) return null;
  Bench.instance.showBottom(BottomTab.tasks);
  return startJob(currentTask, Job(title, args, cwd: cwd));
}
