import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// A Flutter project on disk: its folder, and what its pubspec says.
class Project {
  final String path;
  final String name;
  final String version;
  final String description;
  final List<String> platforms;
  final DateTime openedAt;
  const Project({
    required this.path,
    required this.name,
    this.version = '',
    this.description = '',
    this.platforms = const [],
    required this.openedAt,
  });

  String get folder => p.basename(path);

  Map<String, dynamic> toJson() => {'path': path, 'openedAt': openedAt.toIso8601String()};

  /// Reads the pubspec. Null when the folder isn't a Flutter project.
  static Project? read(String path, {DateTime? openedAt}) {
    final pubspec = File(p.join(path, 'pubspec.yaml'));
    if (!pubspec.existsSync()) return null;
    final text = pubspec.readAsStringSync();
    if (!text.contains(RegExp(r'^\s*flutter\s*:', multiLine: true))) return null;
    String field(String key) {
      final m = RegExp('^$key:\\s*(.+)\$', multiLine: true).firstMatch(text);
      return (m?.group(1) ?? '').trim().replaceAll(RegExp(r'''^["']|["']$'''), '');
    }

    const known = ['android', 'ios', 'macos', 'windows', 'linux', 'web'];
    return Project(
      path: path,
      name: field('name').isEmpty ? p.basename(path) : field('name'),
      version: field('version'),
      description: field('description'),
      platforms: [
        for (final k in known)
          if (Directory(p.join(path, k)).existsSync()) k,
      ],
      openedAt: openedAt ?? DateTime.now(),
    );
  }
}

/// Recent projects, newest first, and the one that's open.
class Projects extends ChangeNotifier {
  Projects._();
  static final Projects instance = Projects._();

  static const _key = 'recent_projects';
  final List<Project> recent = [];
  Project? current;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      for (final e in (jsonDecode(raw) as List).whereType<Map>()) {
        final pr = Project.read('${e['path']}', openedAt: DateTime.tryParse('${e['openedAt']}'));
        if (pr != null) recent.add(pr);
      }
    } catch (_) {}
    if (recent.isNotEmpty) current = recent.first;
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final r in recent.take(30)) r.toJson()]));
  }

  /// Opens [path]. Returns an error to show, or null.
  Future<String?> open(String path) async {
    final pr = Project.read(path);
    if (pr == null) return "That folder isn't a Flutter project (no pubspec.yaml with flutter in it).";
    recent.removeWhere((r) => r.path == path);
    recent.insert(0, pr);
    current = pr;
    notifyListeners();
    await _save();
    return null;
  }

  Future<void> forget(String path) async {
    recent.removeWhere((r) => r.path == path);
    if (current?.path == path) current = recent.isEmpty ? null : recent.first;
    notifyListeners();
    await _save();
  }

  /// Re-reads the open project's pubspec (after a version bump, say).
  void refreshCurrent() {
    final c = current;
    if (c == null) return;
    final pr = Project.read(c.path, openedAt: c.openedAt);
    if (pr == null) return;
    current = pr;
    final i = recent.indexWhere((r) => r.path == c.path);
    if (i >= 0) recent[i] = pr;
    notifyListeners();
  }
}
