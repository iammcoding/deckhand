import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/projects.dart';
import '../../core/sdk.dart';
import '../create_project.dart';
import '../widgets/page_header.dart';
import '../theme.dart';

class ProjectsPage extends StatelessWidget {
  final VoidCallback onOpened;
  const ProjectsPage({super.key, required this.onOpened});

  Future<void> _open(BuildContext context) async {
    final dir = await getDirectoryPath(confirmButtonText: 'Open project');
    if (dir == null || !context.mounted) return;
    final err = await Projects.instance.open(dir);
    if (!context.mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    } else {
      onOpened();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return ListenableBuilder(
      listenable: Projects.instance,
      builder: (context, _) {
        final recent = Projects.instance.recent;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PageHeader(
              title: 'Projects',
              subtitle: 'Open a Flutter project to run, build and ship it.',
              actions: [
                OutlinedButton.icon(
                  onPressed: () => showCreateProject(context),
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('New project'),
                ),
                FilledButton.icon(
                  onPressed: () => _open(context),
                  icon: const Icon(Icons.folder_open_rounded, size: 16),
                  label: const Text('Open folder'),
                ),
              ],
            ),
            Expanded(
              child: recent.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.folder_off_outlined, size: 40, color: c.muted),
                          const SizedBox(height: 10),
                          Text(
                            'No projects yet',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.text),
                          ),
                          const SizedBox(height: 4),
                          Text('Open the folder that has your pubspec.yaml in it.', style: TextStyle(color: c.muted)),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                      itemCount: recent.length,
                      separatorBuilder: (_, __) => Divider(height: 1, color: C.of(context).line),
                      itemBuilder: (_, i) => _ProjectRow(project: recent[i], onOpened: onOpened),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _ProjectRow extends StatelessWidget {
  final Project project;
  final VoidCallback onOpened;
  const _ProjectRow({required this.project, required this.onOpened});

  static const _icons = {
    'android': Icons.android_rounded,
    'ios': Icons.phone_iphone_rounded,
    'macos': Icons.laptop_mac_rounded,
    'windows': Icons.desktop_windows_rounded,
    'linux': Icons.terminal_rounded,
    'web': Icons.public_rounded,
  };

  void _reveal() {
    if (Platform.isMacOS) {
      Process.run('open', [project.path]);
    } else if (Platform.isWindows) {
      Process.run('explorer', [project.path]);
    } else {
      Process.run('xdg-open', [project.path]);
    }
  }

  Future<void> _code(BuildContext context) async {
    try {
      final r = await Process.run('code', [project.path], environment: Sdk.instance.env, runInShell: true);
      if (r.exitCode != 0 && context.mounted) throw 'x';
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("VS Code's 'code' command wasn't found. In VS Code: Cmd+Shift+P → Shell Command: Install 'code'."),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final on = Projects.instance.current?.path == project.path;
    return Material(
      color: on ? c.raised : Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () async {
          await Projects.instance.open(project.path);
          onOpened();
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          project.name,
                          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: c.text),
                        ),
                        if (project.version.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(project.version, style: TextStyle(fontSize: 12, color: c.muted)),
                        ],
                        if (on) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: c.accent.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'OPEN',
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: c.accent),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      project.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono.copyWith(fontSize: 11.5, color: c.muted),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (final pl in project.platforms)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Tooltip(
                              message: pl,
                              child: Icon(_icons[pl] ?? Icons.devices_other_rounded, size: 15, color: c.muted),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(tooltip: 'Show in folder', icon: const Icon(Icons.folder_outlined), onPressed: _reveal),
              IconButton(tooltip: 'Open in VS Code', icon: const Icon(Icons.code_rounded), onPressed: () => _code(context)),
              IconButton(
                tooltip: 'Remove from list',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Projects.instance.forget(project.path),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
