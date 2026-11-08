import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'problems.dart';
import 'projects.dart';

/// What the left side panel shows. Picked from the activity bar.
enum Activity { explorer, run, build, tasks }

/// What an editor tab holds.
enum TabKind { file, overview, projects, devices, doctor, settings }

/// The tabs along the bottom panel.
enum BottomTab { run, build, tasks, problems }

class EditorTab {
  final TabKind kind;
  final String? path; // for a file
  const EditorTab(this.kind, [this.path]);

  String get id => kind == TabKind.file ? path! : kind.name;

  String get title => switch (kind) {
    TabKind.file => path!.split(Platform.pathSeparator).last,
    TabKind.overview => 'Overview',
    TabKind.projects => 'Projects',
    TabKind.devices => 'Devices',
    TabKind.doctor => 'Doctor',
    TabKind.settings => 'Settings',
  };
}

/// The workbench's layout and open tabs: which panels show, how big they
/// are, and which tab is in front. Sizes and panels are kept between
/// launches; open files are kept per project.
class Bench extends ChangeNotifier {
  Bench._();
  static final Bench instance = Bench._();

  Activity activity = Activity.explorer;
  bool sideOpen = true;
  double sideW = 260;
  bool bottomOpen = true;
  double bottomH = 230;
  BottomTab bottom = BottomTab.run;
  bool aiOpen = false;
  double aiW = 380;

  List<EditorTab> tabs = [];
  int active = 0;

  /// Where to scroll a file tab to, set when a problem is clicked. The file
  /// view reads it once and clears it.
  ({String path, int line})? reveal;

  String? _project;

  EditorTab? get current => active < tabs.length ? tabs[active] : null;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    sideOpen = prefs.getBool('bench_side') ?? true;
    sideW = prefs.getDouble('bench_side_w') ?? 260;
    bottomOpen = prefs.getBool('bench_bottom') ?? true;
    bottomH = prefs.getDouble('bench_bottom_h') ?? 230;
    aiOpen = prefs.getBool('bench_ai') ?? false;
    aiW = prefs.getDouble('bench_ai_w') ?? 380;
    activity = Activity.values.where((a) => a.name == prefs.getString('bench_activity')).firstOrNull ?? Activity.explorer;
    Projects.instance.addListener(_projectChanged);
    await _projectChanged();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('bench_side', sideOpen);
    await prefs.setDouble('bench_side_w', sideW);
    await prefs.setBool('bench_bottom', bottomOpen);
    await prefs.setDouble('bench_bottom_h', bottomH);
    await prefs.setBool('bench_ai', aiOpen);
    await prefs.setDouble('bench_ai_w', aiW);
    await prefs.setString('bench_activity', activity.name);
    if (_project != null) {
      await prefs.setString(
        'bench_tabs_$_project',
        jsonEncode({
          'tabs': [
            for (final t in tabs)
              if (t.kind == TabKind.file) t.path else t.kind.name,
          ],
          'active': active,
        }),
      );
    }
  }

  /// A different project: its own tabs, as you left them.
  Future<void> _projectChanged() async {
    final path = Projects.instance.current?.path;
    if (path == _project) return;
    _project = path;
    reveal = null;
    if (path == null) {
      tabs = [const EditorTab(TabKind.projects)];
      active = 0;
      notifyListeners();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('bench_tabs_$path');
    final restored = <EditorTab>[];
    var at = 0;
    if (saved != null) {
      try {
        final j = jsonDecode(saved) as Map;
        for (final t in (j['tabs'] as List)) {
          final kind = TabKind.values.where((k) => k.name == t).firstOrNull;
          if (kind != null && kind != TabKind.file) {
            restored.add(EditorTab(kind));
          } else if (File('$t').existsSync()) {
            restored.add(EditorTab(TabKind.file, '$t'));
          }
        }
        at = (j['active'] as int?) ?? 0;
      } catch (_) {}
    }
    tabs = restored.isEmpty ? [const EditorTab(TabKind.overview)] : restored;
    active = at.clamp(0, tabs.length - 1);
    notifyListeners();
    // Problems for the new project, in the background.
    Problems.instance.run(path);
  }

  void open(EditorTab t) {
    final i = tabs.indexWhere((x) => x.id == t.id);
    if (i >= 0) {
      active = i;
    } else {
      // Next to the tab in front, like an editor.
      final at = tabs.isEmpty ? 0 : active + 1;
      tabs.insert(at, t);
      active = at;
    }
    notifyListeners();
    _save();
  }

  void openFile(String path, {int? line}) {
    if (line != null) reveal = (path: path, line: line);
    open(EditorTab(TabKind.file, path));
  }

  void close(int i) {
    if (i < 0 || i >= tabs.length) return;
    tabs.removeAt(i);
    if (active >= tabs.length) active = tabs.length - 1;
    if (i < active) active--;
    if (active < 0) active = 0;
    notifyListeners();
    _save();
  }

  void closeOthers(int i) {
    final keep = tabs[i];
    tabs = [keep];
    active = 0;
    notifyListeners();
    _save();
  }

  void select(int i) {
    if (i < 0 || i >= tabs.length) return;
    active = i;
    notifyListeners();
    _save();
  }

  /// The activity bar: a second click on the one showing hides the panel.
  void pick(Activity a) {
    if (activity == a && sideOpen) {
      sideOpen = false;
    } else {
      activity = a;
      sideOpen = true;
    }
    notifyListeners();
    _save();
  }

  void showActivity(Activity a) {
    activity = a;
    sideOpen = true;
    notifyListeners();
    _save();
  }

  void showBottom(BottomTab t) {
    bottom = t;
    bottomOpen = true;
    notifyListeners();
    _save();
  }

  void toggleSide() {
    sideOpen = !sideOpen;
    notifyListeners();
    _save();
  }

  void toggleBottom() {
    bottomOpen = !bottomOpen;
    notifyListeners();
    _save();
  }

  void toggleAi() {
    aiOpen = !aiOpen;
    notifyListeners();
    _save();
  }

  void resizeSide(double dx) {
    sideW = (sideW + dx).clamp(180, 520);
    notifyListeners();
  }

  void resizeBottom(double dy) {
    bottomH = (bottomH - dy).clamp(110, 700);
    notifyListeners();
  }

  void resizeAi(double dx) {
    aiW = (aiW - dx).clamp(280, 640);
    notifyListeners();
  }

  /// Called when a drag ends, so a resize is written once, not per frame.
  void saveLayout() => _save();
}
