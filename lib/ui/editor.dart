import 'package:flutter/material.dart';

import '../core/bench.dart';
import 'code_view.dart';
import 'pages/devices_page.dart';
import 'pages/doctor_page.dart';
import 'pages/fvm_page.dart';
import 'pages/overview_page.dart';
import 'pages/projects_page.dart';
import 'pages/sdk_page.dart';
import 'pages/settings_page.dart';
import 'theme.dart';

/// The middle of the workbench: tabs along the top, the tab in front below.
class EditorArea extends StatelessWidget {
  final ValueNotifier<ThemeMode> themeMode;
  const EditorArea({super.key, required this.themeMode});

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final b = Bench.instance;
    final tab = b.current;
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.line)),
            ),
            // Drag a tab to move it; a click still selects it.
            child: ReorderableListView(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              onReorder: b.move,
              proxyDecorator: (child, _, _) =>
                  Material(color: Colors.transparent, elevation: 6, borderRadius: BorderRadius.circular(6), child: child),
              children: [
                for (var i = 0; i < b.tabs.length; i++)
                  ReorderableDragStartListener(key: ValueKey(b.tabs[i].id), index: i, child: _Tab(i)),
              ],
            ),
          ),
          Expanded(
            child: tab == null
                ? Center(
                    child: Text('Open a file from the explorer', style: TextStyle(color: c.muted, fontSize: 13)),
                  )
                : switch (tab.kind) {
                    TabKind.file => CodeView(key: ValueKey(tab.path), path: tab.path!),
                    TabKind.overview => const OverviewPage(),
                    TabKind.projects => ProjectsPage(onOpened: () => b.open(const EditorTab(TabKind.overview))),
                    TabKind.devices => const DevicesPage(),
                    TabKind.doctor => const DoctorPage(),
                    TabKind.settings => SettingsPage(themeMode: themeMode),
                    TabKind.sdk => const SdkPage(),
                    TabKind.fvm => const FvmPage(),
                  },
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatefulWidget {
  final int index;
  const _Tab(this.index);

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  bool _hover = false;

  static IconData _icon(EditorTab t) => switch (t.kind) {
    TabKind.file => t.path!.endsWith('.dart') ? Icons.code_rounded : Icons.insert_drive_file_outlined,
    TabKind.overview => Icons.space_dashboard_outlined,
    TabKind.projects => Icons.folder_open_rounded,
    TabKind.devices => Icons.devices_rounded,
    TabKind.doctor => Icons.health_and_safety_outlined,
    TabKind.settings => Icons.tune_rounded,
    TabKind.sdk => Icons.flutter_dash_rounded,
    TabKind.fvm => Icons.layers_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final b = Bench.instance;
    final t = b.tabs[widget.index];
    final on = b.active == widget.index;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => b.select(widget.index),
        // Middle click closes, as in a browser or editor.
        onTertiaryTapUp: (_) => b.close(widget.index),
        onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
        child: Container(
          margin: const EdgeInsets.only(right: 2),
          padding: const EdgeInsets.only(left: 10, right: 2),
          decoration: BoxDecoration(
            color: on ? c.raised : (_hover ? c.raised.withValues(alpha: 0.5) : null),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(_icon(t), size: 14, color: on ? c.accent : c.muted),
              const SizedBox(width: 7),
              Text(t.title, style: TextStyle(fontSize: 12.5, color: on ? c.text : c.muted)),
              const SizedBox(width: 4),
              SizedBox(
                width: 22,
                child: (on || _hover)
                    ? IconButton(
                        tooltip: 'Close',
                        padding: EdgeInsets.zero,
                        iconSize: 14,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => b.close(widget.index),
                        icon: Icon(Icons.close_rounded, color: c.muted),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context, Offset at) async {
    final c = C.of(context);
    final b = Bench.instance;
    final i = widget.index;
    final pick = await showMenu<String>(
      context: context,
      color: c.panel,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        PopupMenuItem(
          value: 'close',
          height: 32,
          child: Text('Close', style: TextStyle(fontSize: 13, color: c.text)),
        ),
        PopupMenuItem(
          value: 'others',
          height: 32,
          child: Text('Close others', style: TextStyle(fontSize: 13, color: c.text)),
        ),
      ],
    );
    if (pick == 'close') b.close(i);
    if (pick == 'others') b.closeOthers(i);
  }
}
