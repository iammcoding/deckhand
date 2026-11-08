import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'theme.dart';

/// The project's files as a tree. Folders open on click and are read when
/// opened, so a big project costs nothing until you look. Build output and
/// tool folders are hidden.
class Explorer extends StatefulWidget {
  final String root;
  final String? selected;
  final ValueChanged<String> onOpen;
  const Explorer({super.key, required this.root, required this.onOpen, this.selected});

  @override
  State<Explorer> createState() => _ExplorerState();
}

class _ExplorerState extends State<Explorer> {
  static const _hidden = {
    '.dart_tool',
    'build',
    '.git',
    '.idea',
    '.gradle',
    'Pods',
    '.symlinks',
    'ephemeral',
    '.DS_Store',
    '.fvm',
    'node_modules',
  };
  final Set<String> _open = {};
  final Map<String, List<FileSystemEntity>> _cache = {};

  @override
  void initState() {
    super.initState();
    _open.add(widget.root);
    // lib/ is where people start.
    final lib = p.join(widget.root, 'lib');
    if (Directory(lib).existsSync()) _open.add(lib);
  }

  @override
  void didUpdateWidget(Explorer old) {
    super.didUpdateWidget(old);
    if (old.root != widget.root) {
      _open
        ..clear()
        ..add(widget.root);
      _cache.clear();
    }
  }

  List<FileSystemEntity> _children(String dir) => _cache.putIfAbsent(dir, () {
    try {
      final list = Directory(dir).listSync().where((e) => !_hidden.contains(p.basename(e.path))).toList();
      list.sort((a, b) {
        final ad = a is Directory, bd = b is Directory;
        if (ad != bd) return ad ? -1 : 1;
        return p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
      });
      return list;
    } catch (_) {
      return const [];
    }
  });

  void refresh() => setState(_cache.clear);

  static IconData _icon(String name, bool dir, bool open) {
    if (dir) return open ? Icons.folder_open_outlined : Icons.folder_outlined;
    final ext = p.extension(name).toLowerCase();
    return switch (ext) {
      '.dart' => Icons.code_rounded,
      '.yaml' || '.yml' || '.json' || '.plist' || '.xml' || '.gradle' || '.kts' || '.properties' => Icons.settings_outlined,
      '.png' || '.jpg' || '.jpeg' || '.gif' || '.webp' || '.svg' => Icons.image_outlined,
      '.md' || '.txt' => Icons.description_outlined,
      '.swift' || '.kt' || '.java' || '.m' || '.h' || '.cc' || '.cpp' => Icons.data_object_rounded,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  List<Widget> _rows(C c, String dir, int depth) {
    final out = <Widget>[];
    for (final e in _children(dir)) {
      final isDir = e is Directory;
      final name = p.basename(e.path);
      final open = _open.contains(e.path);
      final sel = widget.selected == e.path;
      out.add(
        InkWell(
          onTap: () {
            if (isDir) {
              setState(() => open ? _open.remove(e.path) : _open.add(e.path));
            } else {
              widget.onOpen(e.path);
            }
          },
          child: Container(
            height: 24,
            color: sel ? c.raised : null,
            padding: EdgeInsets.only(left: 8.0 + depth * 12, right: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  child: isDir
                      ? Icon(open ? Icons.expand_more_rounded : Icons.chevron_right_rounded, size: 14, color: c.muted)
                      : null,
                ),
                const SizedBox(width: 2),
                Icon(_icon(name, isDir, open), size: 14, color: isDir ? c.muted : c.muted.withValues(alpha: 0.85)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: sel ? c.text : c.text.withValues(alpha: 0.88)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (isDir && open) out.addAll(_rows(c, e.path, depth + 1));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 30,
          padding: const EdgeInsets.only(left: 12, right: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  p.basename(widget.root),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.text),
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                iconSize: 15,
                visualDensity: VisualDensity.compact,
                onPressed: refresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.only(bottom: 12), children: _rows(c, widget.root, 0)),
        ),
      ],
    );
  }
}
