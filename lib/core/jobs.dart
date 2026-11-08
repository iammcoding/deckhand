import 'package:flutter/foundation.dart';

import 'sessions.dart';

/// The latest build and the latest task (pub get, clean, analyze…), shared by
/// the side panels that start them and the bottom panel that shows them.
final currentBuild = ValueNotifier<Job?>(null);
final currentTask = ValueNotifier<Job?>(null);

/// Where the last successful build put its output, for Show.
final lastBuildOutput = ValueNotifier<String?>(null);

/// Starts [job] as the current build or task, and returns when it ends.
Future<int> startJob(ValueNotifier<Job?> slot, Job job) {
  slot.value = job;
  return job.start();
}
