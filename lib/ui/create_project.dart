import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/bench.dart';
import '../core/jobs.dart';
import '../core/projects.dart';
import 'theme.dart';

/// `flutter create`, as a form: name, where, what kind, which platforms.
/// The name is checked before anything runs; when it's done, the project
/// opens.
Future<void> showCreateProject(BuildContext context) =>
    showDialog(context: context, barrierColor: Colors.black.withValues(alpha: 0.4), builder: (_) => const _CreateProject());

class _CreateProject extends StatefulWidget {
  const _CreateProject();

  @override
  State<_CreateProject> createState() => _CreateProjectState();
}

class _CreateProjectState extends State<_CreateProject> {
  final _name = TextEditingController();
  final _org = TextEditingController(text: 'com.example');
  final _desc = TextEditingController();
  String? _parent;
  String _template = 'app';
  final Set<String> _platforms = {
    'android',
    'ios',
    'web',
    if (Platform.isMacOS) 'macos',
    if (Platform.isWindows) 'windows',
    if (Platform.isLinux) 'linux',
  };
  String _androidLang = 'kotlin';
  bool _empty = false, _pub = true, _offline = false, _overwrite = false;
  bool _busy = false;

  static const _templates = {
    'app': 'App',
    'package': 'Package (Dart code to share)',
    'plugin': 'Plugin (Dart API with platform code)',
    'package_ffi': 'FFI package (Dart API over native code)',
    'module': 'Module (add Flutter to an existing app)',
  };

  // Dart keywords and built-ins a package can't be named.
  static const _reserved = {
    'abstract',
    'as',
    'assert',
    'async',
    'await',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'covariant',
    'default',
    'deferred',
    'do',
    'dynamic',
    'else',
    'enum',
    'export',
    'extends',
    'extension',
    'external',
    'factory',
    'false',
    'final',
    'finally',
    'for',
    'function',
    'get',
    'hide',
    'if',
    'implements',
    'import',
    'in',
    'interface',
    'is',
    'late',
    'library',
    'mixin',
    'new',
    'null',
    'on',
    'operator',
    'part',
    'required',
    'rethrow',
    'return',
    'set',
    'show',
    'static',
    'super',
    'switch',
    'sync',
    'this',
    'throw',
    'true',
    'try',
    'typedef',
    'var',
    'void',
    'while',
    'with',
    'yield',
    'flutter',
    'flutter_test',
    'test',
  };

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _org.text = prefs.getString('create_org') ?? 'com.example';
        _parent = prefs.getString('create_parent') ?? _guessParent();
      });
    });
  }

  /// Where your other projects live, as a starting point.
  String? _guessParent() {
    final recent = Projects.instance.recent;
    if (recent.isNotEmpty) return p.dirname(recent.first.path);
    return Platform.environment['HOME'];
  }

  @override
  void dispose() {
    _name.dispose();
    _org.dispose();
    _desc.dispose();
    super.dispose();
  }

  bool get _hasPlatforms => _template == 'app' || _template == 'plugin' || _template == 'package_ffi';

  String? get _nameError {
    final n = _name.text.trim();
    if (n.isEmpty) return null;
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(n)) return 'Lowercase letters, digits and _ only, starting with a letter.';
    if (_reserved.contains(n)) return '"$n" is a reserved word in Dart.';
    return null;
  }

  String? get _orgError {
    final o = _org.text.trim();
    if (o.isEmpty) return 'Needed, like com.yourname.';
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$').hasMatch(o)) return 'Reverse domain, like com.yourname.';
    return null;
  }

  String? get _target => _parent == null || _name.text.trim().isEmpty ? null : p.join(_parent!, _name.text.trim());

  bool get _targetNotEmpty {
    final t = _target;
    if (t == null) return false;
    final d = Directory(t);
    return d.existsSync() && d.listSync().isNotEmpty;
  }

  bool get _ready =>
      !_busy &&
      _name.text.trim().isNotEmpty &&
      _nameError == null &&
      _orgError == null &&
      _parent != null &&
      (!_hasPlatforms || _platforms.isNotEmpty) &&
      (!_targetNotEmpty || _overwrite);

  Future<void> _create() async {
    final target = _target!;
    setState(() => _busy = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('create_org', _org.text.trim());
    await prefs.setString('create_parent', _parent!);
    final args = [
      'create',
      '--project-name',
      _name.text.trim(),
      '--org',
      _org.text.trim(),
      if (_desc.text.trim().isNotEmpty) ...['--description', _desc.text.trim()],
      '--template',
      _template,
      if (_hasPlatforms) '--platforms=${_platforms.join(',')}',
      if (_template == 'app' || _template == 'plugin') ...['--android-language', _androidLang],
      if (_template == 'app' && _empty) '--empty',
      if (!_pub) '--no-pub',
      if (_offline) '--offline',
      if (_overwrite) '--overwrite',
      target,
    ];
    if (!mounted) return;
    Navigator.pop(context);
    final code = await runTask('Create ${_name.text.trim()}', args, cwd: _parent);
    if (code == 0 && File(p.join(target, 'pubspec.yaml')).existsSync()) {
      final err = await Projects.instance.open(target);
      if (err == null) Bench.instance.open(const EditorTab(TabKind.overview));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    InputDecoration deco(String hint, {String? error}) => InputDecoration(
      isDense: true,
      hintText: hint,
      errorText: error,
      errorMaxLines: 2,
      hintStyle: TextStyle(fontSize: 13, color: c.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: c.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: c.line),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    );
    Widget label(String t) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Text(
        t,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.muted),
      ),
    );
    Widget check(String t, bool v, ValueChanged<bool> set) => InkWell(
      onTap: () => set(!v),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(value: v, onChanged: (x) => set(x ?? false), visualDensity: VisualDensity.compact),
          Text(t, style: TextStyle(fontSize: 12.5, color: c.text)),
          const SizedBox(width: 8),
        ],
      ),
    );

    return Dialog(
      backgroundColor: c.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 4),
              child: Text(
                'New project',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.text),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    label('Name'),
                    TextField(
                      controller: _name,
                      autofocus: true,
                      onChanged: (_) => setState(() {}),
                      style: TextStyle(fontSize: 13, color: c.text),
                      decoration: deco('my_app', error: _nameError),
                    ),
                    label('Folder'),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _target ?? (_parent ?? 'Choose a folder'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: monoStyle.copyWith(fontSize: 12, color: c.text),
                          ),
                        ),
                        TextButton(
                          onPressed: () async {
                            final d = await getDirectoryPath(initialDirectory: _parent, confirmButtonText: 'Create it here');
                            if (d != null) setState(() => _parent = d);
                          },
                          child: const Text('Change…'),
                        ),
                      ],
                    ),
                    if (_targetNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber_rounded, size: 15, color: c.warn),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text('That folder already has files.', style: TextStyle(fontSize: 12, color: c.warn)),
                            ),
                            check('Overwrite', _overwrite, (x) => setState(() => _overwrite = x)),
                          ],
                        ),
                      ),
                    label('Kind'),
                    DropdownButtonFormField<String>(
                      initialValue: _template,
                      isDense: true,
                      dropdownColor: c.panel,
                      style: TextStyle(fontSize: 13, color: c.text),
                      decoration: deco(''),
                      items: [for (final e in _templates.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                      onChanged: (v) => setState(() => _template = v ?? 'app'),
                    ),
                    if (_hasPlatforms) ...[
                      label('Platforms'),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final (id, name) in const [
                            ('android', 'Android'),
                            ('ios', 'iOS'),
                            ('web', 'Web'),
                            ('macos', 'macOS'),
                            ('windows', 'Windows'),
                            ('linux', 'Linux'),
                          ])
                            FilterChip(
                              label: Text(name, style: const TextStyle(fontSize: 12.5)),
                              selected: _platforms.contains(id),
                              showCheckmark: false,
                              onSelected: (x) => setState(() => x ? _platforms.add(id) : _platforms.remove(id)),
                            ),
                        ],
                      ),
                      if (_platforms.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text('Pick at least one.', style: TextStyle(fontSize: 12, color: c.bad)),
                        ),
                    ],
                    label('Organisation'),
                    TextField(
                      controller: _org,
                      onChanged: (_) => setState(() {}),
                      style: TextStyle(fontSize: 13, color: c.text),
                      decoration: deco('com.yourname', error: _orgError),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Used for the app ID: ${_org.text.trim().isEmpty ? 'com.yourname' : _org.text.trim()}.${_name.text.trim().isEmpty ? 'my_app' : _name.text.trim()}',
                        style: TextStyle(fontSize: 11.5, color: c.muted),
                      ),
                    ),
                    label('Description'),
                    TextField(
                      controller: _desc,
                      style: TextStyle(fontSize: 13, color: c.text),
                      decoration: deco('A new Flutter project.'),
                    ),
                    label('Options'),
                    if (_template == 'app' || _template == 'plugin')
                      Row(
                        children: [
                          Text('Android code in', style: TextStyle(fontSize: 12.5, color: c.text)),
                          const SizedBox(width: 10),
                          SegmentedButton<String>(
                            segments: const [
                              ButtonSegment(
                                value: 'kotlin',
                                label: Text('Kotlin', style: TextStyle(fontSize: 12)),
                              ),
                              ButtonSegment(
                                value: 'java',
                                label: Text('Java', style: TextStyle(fontSize: 12)),
                              ),
                            ],
                            selected: {_androidLang},
                            showSelectedIcon: false,
                            style: const ButtonStyle(visualDensity: VisualDensity.compact),
                            onSelectionChanged: (s) => setState(() => _androidLang = s.first),
                          ),
                        ],
                      ),
                    Wrap(
                      children: [
                        if (_template == 'app') check('Minimal main.dart, no sample', _empty, (x) => setState(() => _empty = x)),
                        check('Get packages afterwards', _pub, (x) => setState(() => _pub = x)),
                        if (_pub) check('Offline', _offline, (x) => setState(() => _offline = x)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
              child: Row(
                children: [
                  const Spacer(),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _ready ? _create : null, child: const Text('Create')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
