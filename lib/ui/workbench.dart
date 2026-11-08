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

import 'side/tasks_side.dart';
import 'theme.dart';
import 'widgets/palette.dart';
import 'widgets/splitter.dart';

const _window = MethodChannel('deckhand/window');

/// The main window: a run bar on top, then floating panels: the sidebar
/// (files, build, tasks), tabs in the middle, the console below, chat on
/// the right.
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
          backgroundColor: c.bg,
          body: Column(
            children: [
              _topBar(c),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (b.sideOpen) ...[
                        SizedBox(width: b.sideW, child: _card(c, _sidebar(c))),
                        Splitter(axis: Axis.vertical, onDrag: b.resizeSide, onEnd: b.saveLayout),
                      ],
                      Expanded(
                        child: Column(
                          children: [
                            Expanded(child: _card(c, EditorArea(themeMode: widget.themeMode))),
                            if (b.bottomOpen) ...[
                              Splitter(axis: Axis.horizontal, onDrag: b.resizeBottom, onEnd: b.saveLayout),
                              SizedBox(height: b.bottomH, child: _card(c, const BottomPanel())),
                            ],
                          ],
                        ),
                      ),
                      if (b.aiOpen) ...[
                        Splitter(axis: Axis.vertical, onDrag: b.resizeAi, onEnd: b.saveLayout),
                        SizedBox(width: b.aiW, child: _card(c, const AiChat())),
                      ],
                    ],
                  ),
                ),
              ),
              _statusBar(c),
            ],
          ),
        ),
      ),
    );
  }

  /// A floating panel: rounded, on the darker window background.
  Widget _card(C c, Widget child) => Container(
    decoration: BoxDecoration(
      color: c.panel,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: c.line),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );

  // ---- Sidebar ---------------------------------------------------------------

  Widget _sidebar(C c) {
    final b = Bench.instance;
    final pr = Projects.instance.current;
    final cur = b.current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Files · Build · Tasks, as a segmented switch.
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Container(
            height: 28,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(7)),
            child: Row(
              children: [
                for (final (a, label) in const [
                  (Activity.explorer, 'Files'),
                  (Activity.build, 'Build'),
                  (Activity.tasks, 'Tasks'),
                ])
                  Expanded(
                    child: GestureDetector(
                      onTap: pr == null ? null : () => b.showActivity(a),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: b.activity == a ? c.raised : Colors.transparent,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: b.activity == a ? FontWeight.w600 : FontWeight.w500,
                            color: b.activity == a ? c.text : c.muted,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: pr == null
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('No project open.', style: TextStyle(fontSize: 12.5, color: c.muted)),
                      const SizedBox(height: 10),
                      FilledButton(onPressed: _openFolder, child: const Text('Open a project')),
                    ],
                  ),
                )
              : switch (b.activity) {
                  Activity.explorer => Explorer(
                    root: pr.path,
                    selected: cur?.kind == TabKind.file ? cur!.path : null,
                    onOpen: (f) => b.openFile(f),
                  ),
                  Activity.build => const BuildSide(),
                  Activity.tasks => const TasksSide(),
                },
        ),
        // The rest of the app, at the foot of the sidebar.
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: c.line)),
          ),
          child: Row(
            children: [
              _foot(c, Icons.space_dashboard_outlined, 'Overview', TabKind.overview, enabled: pr != null),
              _foot(c, Icons.devices_rounded, 'Devices', TabKind.devices),
              _foot(c, Icons.health_and_safety_outlined, 'Doctor', TabKind.doctor),
              const Spacer(),
              _foot(c, Icons.settings_outlined, 'Settings  ⌘,', TabKind.settings),
            ],
          ),
        ),
      ],
    );
  }

  Widget _foot(C c, IconData icon, String tip, TabKind k, {bool enabled = true}) {
    final on = Bench.instance.current?.kind == k;
    return IconButton(
      tooltip: tip,
      iconSize: 17,
      visualDensity: VisualDensity.compact,
      onPressed: enabled ? () => _tab(k) : null,
      icon: Icon(icon, color: on ? c.accent : c.muted),
    );
  }

  // ---- Top bar -----------------------------------------------------------------

  Widget _topBar(C c) {
    final b = Bench.instance;
    final pr = Projects.instance.current;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // The window moves when you drag the bar, and zooms on a double click.
      onPanStart: Platform.isMacOS ? (_) => _window.invokeMethod('drag').catchError((_) {}) : null,
      onDoubleTap: Platform.isMacOS ? () => _window.invokeMethod('zoom').catchError((_) {}) : null,
      child: SizedBox(
        height: 46,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Row(
              children: [
                // Room for the traffic lights.
                SizedBox(width: Platform.isMacOS ? 84 : 12),
                _projectMenu(c, pr),
                if (_branch != null) ...[
                  Icon(Icons.call_split_rounded, size: 13, color: c.muted),
                  const SizedBox(width: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Text(
                      _branch!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: c.muted),
                    ),
                  ),
                ],
                const Spacer(),
                _toggle(c, Icons.search_rounded, 'Commands and files  ⌘K', false, () => showPalette(context, _commands())),
                const SizedBox(width: 4),
                _toggle(c, Icons.view_sidebar_outlined, 'Sidebar  ⌘B', b.sideOpen, b.toggleSide, flip: true),
                _toggle(c, Icons.call_to_action_outlined, 'Console  ⌘J', b.bottomOpen, b.toggleBottom),
                _toggle(c, Icons.forum_outlined, 'Chat  ⌘L', b.aiOpen, b.toggleAi),
                const SizedBox(width: 10),
              ],
            ),
            const RunBar(),
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
            Icon(Icons.anchor_rounded, size: 15, color: c.accent),
            const SizedBox(width: 7),
            Text(
              pr?.name ?? 'No project',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text),
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
      child: Icon(icon, color: on ? c.text : c.muted.withValues(alpha: 0.7)),
    ),
  );

  // ---- Status line -------------------------------------------------------------

  Widget _statusBar(C c) {
    final pb = Problems.instance;
    Widget item(IconData? icon, String text, {Color? color, VoidCallback? onTap}) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 12, color: color ?? c.muted), const SizedBox(width: 5)],
            Text(text, style: TextStyle(fontSize: 11.5, color: color ?? c.muted)),
          ],
        ),
      ),
    );
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          const SizedBox(width: 8),
          if (Projects.instance.current != null) ...[
            item(
              Icons.error_outline_rounded,
              pb.running ? '…' : '${pb.errors}',
              color: pb.errors > 0 ? c.bad : null,
              onTap: () => Bench.instance.showBottom(BottomTab.problems),
            ),
            item(
              Icons.warning_amber_rounded,
              pb.running ? '…' : '${pb.warnings}',
              color: pb.warnings > 0 ? c.warn : null,
              onTap: () => Bench.instance.showBottom(BottomTab.problems),
            ),
          ],
          const Spacer(),
          item(
            Icons.auto_awesome_outlined,
            Ai.instance.connected ? Ai.instance.model : 'No AI connected',
            onTap: Bench.instance.toggleAi,
          ),
          item(
            null,
            _flutter.isEmpty ? (Sdk.instance.ready ? 'Flutter' : 'Flutter not found') : _flutter,
            color: Sdk.instance.ready ? null : c.bad,
            onTap: () => _tab(TabKind.settings),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}
