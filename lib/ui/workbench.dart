import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/ai.dart';
import '../core/bench.dart';
import '../core/devices.dart';
import '../core/problems.dart';
import '../core/projects.dart';
import '../core/sdk.dart';
import '../core/sessions.dart';
import 'editor.dart';
import 'explorer.dart';
import 'panels/ai_chat.dart';
import 'panels/bottom_panel.dart';
import 'side/build_side.dart';
import 'side/run_side.dart';
import 'side/side_kit.dart';
import 'side/tasks_side.dart';
import 'theme.dart';
import 'widgets/palette.dart';
import 'widgets/splitter.dart';

const _window = MethodChannel('deckhand/window');

/// The main window, laid out like a code editor: activity bar, side panel,
/// tabs in the middle, a panel for logs below, chat on the right, and a
/// status bar.
class Workbench extends StatefulWidget {
  final ValueNotifier<ThemeMode> themeMode;
  const Workbench({super.key, required this.themeMode});

  @override
  State<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<Workbench> {
  String _flutter = '';
  String? _branch;
  RunSession? _watched;

  @override
  void initState() {
    super.initState();
    Bench.instance.addListener(_changed);
    Projects.instance.addListener(_projectChanged);
    Devices.instance.addListener(_changed);
    Problems.instance.addListener(_changed);
    currentRun.addListener(_runChanged);
    _projectChanged();
    Sdk.instance.version().then((v) {
      if (mounted && v != null) setState(() => _flutter = 'Flutter ${v['frameworkVersion']}');
    });
  }

  @override
  void dispose() {
    Bench.instance.removeListener(_changed);
    Projects.instance.removeListener(_projectChanged);
    Devices.instance.removeListener(_changed);
    Problems.instance.removeListener(_changed);
    currentRun.removeListener(_runChanged);
    _watched?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _runChanged() {
    _watched?.removeListener(_changed);
    _watched = currentRun.value?..addListener(_changed);
    _changed();
  }

  /// The git branch, read from .git/HEAD: no git process needed.
  void _projectChanged() {
    final pr = Projects.instance.current;
    String? branch;
    if (pr != null) {
      try {
        final head = File(p.join(pr.path, '.git', 'HEAD')).readAsStringSync().trim();
        branch = head.startsWith('ref: refs/heads/') ? head.substring(16) : head.substring(0, 7);
      } catch (_) {}
    }
    _branch = branch;
    _changed();
  }

  Future<void> _openFolder() async {
    final dir = await getDirectoryPath(confirmButtonText: 'Open project');
    if (dir == null || !mounted) return;
    final err = await Projects.instance.open(dir);
    if (err != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
  }

  void _tab(TabKind k) => Bench.instance.open(EditorTab(k));

  /// ⌘K: every action, found by typing.
  List<Command> _commands() {
    final b = Bench.instance;
    final pr = Projects.instance.current;
    final run = currentRun.value;
    final live = run != null && !run.stopped;
    return [
      if (pr != null) ...[
        Command('Run on ${Devices.instance.selected?.name ?? 'a device'}', 'Run', startRun),
        Command('Explorer', 'Show', () => b.showActivity(Activity.explorer), keys: '⇧⌘E'),
        Command('Run panel', 'Show', () => b.showActivity(Activity.run)),
        Command('Build panel', 'Show', () => b.showActivity(Activity.build)),
        Command('Tasks', 'Show', () => b.showActivity(Activity.tasks)),
        Command('Overview', 'Show', () => _tab(TabKind.overview)),
        Command('Problems', 'Show', () => b.showBottom(BottomTab.problems)),
        Command('Go to file', 'Show', _quickOpen, keys: '⌘P'),
        Command('Analyze', 'Tasks', () {
          b.showBottom(BottomTab.problems);
          Problems.instance.run(pr.path);
        }),
        for (final (_, title, args) in TasksSide.tasks) Command(title, 'Tasks', () => TasksSide.run(title, args)),
      ],
      if (live && run.canReload) ...[
        Command('Hot reload', 'App', () => run.reload(), keys: '⌘R'),
        Command('Hot restart', 'App', () => run.reload(full: true), keys: '⇧⌘R'),
      ],
      if (live) Command('Stop the app', 'App', run.stop),
      Command('Toggle side panel', 'Layout', b.toggleSide, keys: '⌘B'),
      Command('Toggle bottom panel', 'Layout', b.toggleBottom, keys: '⌘J'),
      Command('Toggle chat', 'Layout', b.toggleAi, keys: '⌘L'),
      Command('Open a project folder', 'Projects', _openFolder, keys: '⌘O'),
      Command('All projects', 'Projects', () => _tab(TabKind.projects)),
      for (final r in Projects.instance.recent.where((r) => r.path != pr?.path).take(8))
        Command('Open ${r.name}', 'Projects', () => Projects.instance.open(r.path)),
      Command('Devices', 'Show', () => _tab(TabKind.devices)),
      Command('Doctor', 'Show', () => _tab(TabKind.doctor)),
      Command('Settings', 'Show', () => _tab(TabKind.settings), keys: '⌘,'),
      Command('Refresh devices', 'Devices', Devices.instance.refresh),
      for (final d in Devices.instance.list) Command('Use ${d.name}', 'Devices', () => Devices.instance.select(d.id)),
      Command('Dark appearance', 'Look', () => widget.themeMode.value = ThemeMode.dark),
      Command('Light appearance', 'Look', () => widget.themeMode.value = ThemeMode.light),
      Command('Match the system', 'Look', () => widget.themeMode.value = ThemeMode.system),
    ];
  }

  static const _skip = {
    '.dart_tool',
    'build',
    '.git',
    '.idea',
    '.gradle',
    'Pods',
    '.symlinks',
    'ephemeral',
    'node_modules',
    '.fvm',
  };

  /// ⌘P: every file in the project, by name.
  void _quickOpen() {
    final pr = Projects.instance.current;
    if (pr == null) return;
    final files = <String>[];
    void walk(Directory d, int depth) {
      if (depth > 12 || files.length > 5000) return;
      try {
        for (final e in d.listSync()) {
          final name = p.basename(e.path);
          if (_skip.contains(name) || name.startsWith('.')) continue;
          if (e is Directory) {
            walk(e, depth + 1);
          } else {
            files.add(e.path);
          }
        }
      } catch (_) {}
    }

    walk(Directory(pr.path), 0);
    files.sort((a, b) => a.length.compareTo(b.length));
    showPalette(context, [
      for (final f in files) Command(p.basename(f), p.dirname(p.relative(f, from: pr.path)), () => Bench.instance.openFile(f)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final b = Bench.instance;
    final meta = Platform.isMacOS;
    SingleActivator key(LogicalKeyboardKey k, {bool shift = false}) =>
        SingleActivator(k, meta: meta, control: !meta, shift: shift);
    final run = currentRun.value;
    return CallbackShortcuts(
      bindings: {
        key(LogicalKeyboardKey.keyK): () => showPalette(context, _commands()),
        key(LogicalKeyboardKey.keyP): _quickOpen,
        key(LogicalKeyboardKey.keyB): b.toggleSide,
        key(LogicalKeyboardKey.keyJ): b.toggleBottom,
        key(LogicalKeyboardKey.keyL): b.toggleAi,
        key(LogicalKeyboardKey.keyO): _openFolder,
        key(LogicalKeyboardKey.comma): () => _tab(TabKind.settings),
        key(LogicalKeyboardKey.keyW): () => b.close(b.active),
        key(LogicalKeyboardKey.keyE, shift: true): () => b.showActivity(Activity.explorer),
        key(LogicalKeyboardKey.keyR): () => run?.reload(),
        key(LogicalKeyboardKey.keyR, shift: true): () => run?.reload(full: true),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              _titleBar(c),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _activityBar(c),
                    if (b.sideOpen) ...[
                      Container(width: b.sideW, color: c.panel, child: _side(c)),
                      Splitter(axis: Axis.vertical, onDrag: b.resizeSide, onEnd: b.saveLayout),
                    ] else
                      Container(width: 1, color: c.line),
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(child: EditorArea(themeMode: widget.themeMode)),
                          if (b.bottomOpen) ...[
                            Splitter(axis: Axis.horizontal, onDrag: b.resizeBottom, onEnd: b.saveLayout),
                            SizedBox(height: b.bottomH, child: const BottomPanel()),
                          ],
                        ],
                      ),
                    ),
                    if (b.aiOpen) ...[
                      Splitter(axis: Axis.vertical, onDrag: b.resizeAi, onEnd: b.saveLayout),
                      SizedBox(width: b.aiW, child: const AiChat()),
                    ],
                  ],
                ),
              ),
              _statusBar(c),
            ],
          ),
        ),
      ),
    );
  }

  Widget _side(C c) {
    final pr = Projects.instance.current;
    if (pr == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SideTitle('Explorer'),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text('No project open.', style: TextStyle(fontSize: 12.5, color: c.muted)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FilledButton(onPressed: _openFolder, child: const Text('Open a project')),
          ),
        ],
      );
    }
    final b = Bench.instance;
    final cur = b.current;
    return switch (b.activity) {
      Activity.explorer => Explorer(
        root: pr.path,
        selected: cur?.kind == TabKind.file ? cur!.path : null,
        onOpen: (f) => b.openFile(f),
      ),
      Activity.run => const RunSide(),
      Activity.build => const BuildSide(),
      Activity.tasks => const TasksSide(),
    };
  }

  // ---- Title bar -----------------------------------------------------------

  Widget _titleBar(C c) {
    final b = Bench.instance;
    final pr = Projects.instance.current;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // The window moves when you drag the title bar, and zooms on a double click.
      onPanStart: Platform.isMacOS ? (_) => _window.invokeMethod('drag').catchError((_) {}) : null,
      onDoubleTap: Platform.isMacOS ? () => _window.invokeMethod('zoom').catchError((_) {}) : null,
      child: Container(
        height: 38,
        decoration: BoxDecoration(
          color: c.panel,
          border: Border(bottom: BorderSide(color: c.line)),
        ),
        child: Row(
          children: [
            // Room for the traffic lights.
            SizedBox(width: Platform.isMacOS ? 80 : 10),
            _projectMenu(c, pr),
            if (_branch != null) ...[
              const SizedBox(width: 2),
              Icon(Icons.call_split_rounded, size: 13, color: c.muted),
              const SizedBox(width: 4),
              Text(_branch!, style: TextStyle(fontSize: 12, color: c.muted)),
            ],
            Expanded(
              child: Center(
                child: InkWell(
                  borderRadius: BorderRadius.circular(5),
                  onTap: () => showPalette(context, _commands()),
                  child: Container(
                    width: 380,
                    height: 24,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: c.bg,
                      border: Border.all(color: c.line),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.search_rounded, size: 14, color: c.muted),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            pr == null ? 'Deckhand' : 'Search commands and files',
                            style: TextStyle(fontSize: 12, color: c.muted),
                          ),
                        ),
                        Text(
                          Platform.isMacOS ? '⌘K' : 'Ctrl K',
                          style: TextStyle(fontSize: 11, color: c.muted.withValues(alpha: 0.7)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            _toggle(c, Icons.view_sidebar_outlined, 'Side panel  ⌘B', b.sideOpen, b.toggleSide, flip: true),
            _toggle(c, Icons.call_to_action_outlined, 'Bottom panel  ⌘J', b.bottomOpen, b.toggleBottom),
            _toggle(c, Icons.forum_outlined, 'Chat  ⌘L', b.aiOpen, b.toggleAi),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  Widget _projectMenu(C c, Project? pr) {
    return PopupMenuButton<String>(
      tooltip: 'Switch project',
      color: c.panel,
      position: PopupMenuPosition.under,
      onSelected: (v) {
        if (v == '_open') {
          _openFolder();
        } else if (v == '_all') {
          _tab(TabKind.projects);
        } else {
          Projects.instance.open(v);
        }
      },
      itemBuilder: (_) => [
        for (final r in Projects.instance.recent.take(10))
          PopupMenuItem(
            value: r.path,
            height: 32,
            child: Text(
              r.name,
              style: TextStyle(fontSize: 13, color: c.text, fontWeight: r.path == pr?.path ? FontWeight.w700 : FontWeight.w400),
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: '_open',
          height: 32,
          child: Text('Open folder…', style: TextStyle(fontSize: 13, color: c.text)),
        ),
        PopupMenuItem(
          value: '_all',
          height: 32,
          child: Text('All projects', style: TextStyle(fontSize: 13, color: c.text)),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              pr?.name ?? 'No project',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.text),
            ),
            Icon(Icons.expand_more_rounded, size: 15, color: c.muted),
          ],
        ),
      ),
    );
  }

  Widget _toggle(C c, IconData icon, String tip, bool on, VoidCallback onTap, {bool flip = false}) => IconButton(
    tooltip: tip,
    iconSize: 16,
    visualDensity: VisualDensity.compact,
    onPressed: onTap,
    icon: Transform.flip(
      flipX: flip,
      child: Icon(icon, color: on ? c.text : c.muted.withValues(alpha: 0.6)),
    ),
  );

  // ---- Activity bar --------------------------------------------------------

  Widget _activityBar(C c) {
    final b = Bench.instance;
    final hasProject = Projects.instance.current != null;
    final run = currentRun.value;
    final live = run != null && !run.stopped;
    final cur = b.current?.kind;
    return Container(
      width: 46,
      color: c.panel,
      child: Column(
        children: [
          const SizedBox(height: 4),
          _activity(
            c,
            Icons.description_outlined,
            'Explorer  ⇧⌘E',
            b.sideOpen && b.activity == Activity.explorer,
            () => b.pick(Activity.explorer),
          ),
          _activity(
            c,
            Icons.play_circle_outline_rounded,
            'Run',
            b.sideOpen && b.activity == Activity.run,
            hasProject ? () => b.pick(Activity.run) : null,
            badge: live ? (run.started ? c.good : c.warn) : null,
          ),
          _activity(
            c,
            Icons.construction_rounded,
            'Build',
            b.sideOpen && b.activity == Activity.build,
            hasProject ? () => b.pick(Activity.build) : null,
          ),
          _activity(
            c,
            Icons.checklist_rounded,
            'Tasks',
            b.sideOpen && b.activity == Activity.tasks,
            hasProject ? () => b.pick(Activity.tasks) : null,
          ),
          const Spacer(),
          _activity(c, Icons.devices_rounded, 'Devices', cur == TabKind.devices, () => _tab(TabKind.devices)),
          _activity(c, Icons.health_and_safety_outlined, 'Doctor', cur == TabKind.doctor, () => _tab(TabKind.doctor)),
          _activity(c, Icons.settings_outlined, 'Settings  ⌘,', cur == TabKind.settings, () => _tab(TabKind.settings)),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _activity(C c, IconData icon, String tip, bool on, VoidCallback? onTap, {Color? badge}) => Tooltip(
    message: tip,
    preferBelow: false,
    child: InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 46,
        child: Stack(
          children: [
            if (on) Positioned(left: 0, top: 8, bottom: 8, child: Container(width: 2, color: c.accent)),
            Center(
              child: Icon(
                icon,
                size: 21,
                color: onTap == null ? c.muted.withValues(alpha: 0.3) : (on ? c.text : c.muted.withValues(alpha: 0.8)),
              ),
            ),
            if (badge != null)
              Positioned(
                right: 10,
                bottom: 11,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: badge,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.panel, width: 1.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  // ---- Status bar ----------------------------------------------------------

  Widget _statusBar(C c) {
    final run = currentRun.value;
    final dev = Devices.instance.selected;
    final pb = Problems.instance;
    final live = run != null && !run.stopped;
    // Blue while the app runs, like an editor in a debug session.
    final on = live && run.started;
    final fg = on ? Colors.white : c.muted;
    Widget item(IconData? icon, String text, {Color? color, VoidCallback? onTap, String? tip}) {
      final w = InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 13, color: color ?? fg), const SizedBox(width: 5)],
              Text(text, style: TextStyle(fontSize: 11.5, color: color ?? fg)),
            ],
          ),
        ),
      );
      return tip == null ? w : Tooltip(message: tip, child: w);
    }

    return Container(
      height: 24,
      decoration: BoxDecoration(
        color: on ? c.accent : c.panel,
        border: Border(top: BorderSide(color: on ? c.accent : c.line)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 4),
          if (Projects.instance.current != null)
            item(
              null,
              pb.running ? 'Analyzing…' : '${pb.errors} errors  ${pb.warnings} warnings',
              onTap: () => Bench.instance.showBottom(BottomTab.problems),
              tip: 'Problems',
            ),
          if (run != null)
            item(
              run.stopped ? Icons.stop_circle_outlined : Icons.circle,
              run.stopped
                  ? 'Stopped'
                  : run.started
                  ? 'Running on ${run.deviceName}${run.lastReload != null ? ' · ${run.lastReload}' : ''}'
                  : (run.progress ?? 'Starting…'),
              color: on ? Colors.white : (run.stopped ? c.muted : c.warn),
              onTap: () => Bench.instance.showBottom(BottomTab.run),
            ),
          const Spacer(),
          item(Icons.smartphone_rounded, dev?.name ?? 'No device', onTap: () => Bench.instance.showActivity(Activity.run)),
          item(Icons.auto_awesome_outlined, Ai.instance.connected ? Ai.instance.model : 'No AI', onTap: Bench.instance.toggleAi),
          item(
            null,
            _flutter.isEmpty ? (Sdk.instance.ready ? 'Flutter' : 'Flutter not found') : _flutter,
            color: Sdk.instance.ready ? null : c.bad,
            onTap: () => _tab(TabKind.settings),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}
