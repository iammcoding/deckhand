import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/bench.dart';
import '../../core/fvm.dart';
import '../../core/jobs.dart';
import '../../core/projects.dart';
import '../../core/sdk.dart';
import '../theme.dart';
import '../widgets/page_header.dart';

/// The Flutter SDK itself: version and channel, updates, downloaded tools,
/// the tool's settings, and shell completion. Long commands run in the
/// console's Tasks tab; settings apply at once.
class SdkPage extends StatefulWidget {
  const SdkPage({super.key});

  @override
  State<SdkPage> createState() => _SdkPageState();
}

class _Channel {
  final String name;
  final String about;
  final bool current;
  const _Channel(this.name, this.about, this.current);
}

class _SdkPageState extends State<SdkPage> {
  Map<String, dynamic>? _version;
  List<_Channel> _channels = const [];
  String? _pick;
  bool _cacheArtifacts = true;
  bool _forceUpgrade = false;

  // precache
  final Set<String> _precache = {
    if (Platform.isMacOS) ...{'ios', 'macos'},
    if (Platform.isWindows) 'windows',
    'web',
  };
  bool _precacheAll = false, _precacheForce = false;

  // config
  Map<String, String> _config = {};
  final Set<String> _unavailable = {};
  final Map<String, TextEditingController> _paths = {
    'android-sdk': TextEditingController(),
    'jdk-dir': TextEditingController(),
    'android-studio-dir': TextEditingController(),
    'build-dir': TextEditingController(),
  };
  bool? _analytics;
  bool _loading = true;
  String? _completionPath;

  static const _pathLabels = {
    'android-sdk': 'Android SDK',
    'jdk-dir': 'Java (JDK)',
    'android-studio-dir': 'Android Studio',
    'build-dir': 'Build folder (relative)',
  };

  @override
  void initState() {
    super.initState();
    _load();
    sdkChanged.addListener(_load);
  }

  @override
  void dispose() {
    sdkChanged.removeListener(_load);
    for (final c in _paths.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      Sdk.instance.version(),
      _run(['channel']),
      _run(['config', '--list']),
    ]);
    if (!mounted) return;
    final channels = <_Channel>[];
    for (final l in '${results[1] ?? ''}'.split('\n')) {
      final m = RegExp(r'^(\*?)\s*([a-z]+)\s*\((.+)\)\s*$').firstMatch(l.trim());
      if (m != null) channels.add(_Channel(m.group(2)!, m.group(3)!, m.group(1) == '*'));
    }
    final config = <String, String>{};
    _unavailable.clear();
    for (final l in '${results[2] ?? ''}'.split('\n')) {
      final m = RegExp(r'^\s+([a-z0-9-]+):\s*(.*)$').firstMatch(l);
      if (m == null) continue;
      var v = m.group(2)!.trim();
      if (v.contains('(Unavailable)')) {
        _unavailable.add(m.group(1)!);
        v = v.replaceAll('(Unavailable)', '').trim();
      }
      config[m.group(1)!] = v;
    }
    for (final e in _paths.entries) {
      final v = config[e.key];
      e.value.text = v == null || v == '(Not set)' ? '' : v;
    }
    setState(() {
      _version = results[0] as Map<String, dynamic>?;
      _channels = channels;
      _pick = channels.where((c) => c.current).firstOrNull?.name;
      _config = config;
      _analytics = _readAnalytics();
      _loading = false;
    });
  }

  Future<String?> _run(List<String> args) async {
    try {
      final r = await Sdk.instance.run(args, timeout: const Duration(minutes: 2));
      return '${r.stdout}\n${r.stderr}';
    } catch (_) {
      return null;
    }
  }

  /// Whether Flutter sends usage stats, from the shared Dart/Flutter
  /// telemetry file. Null when the file isn't there.
  bool? _readAnalytics() {
    final home = Platform.environment['HOME'] ?? Platform.environment['APPDATA'] ?? '';
    for (final dir in [p.join(home, '.dart-tool'), p.join(Platform.environment['APPDATA'] ?? '', '.dart-tool')]) {
      try {
        final f = File(p.join(dir, 'dart-flutter-telemetry.config'));
        if (!f.existsSync()) continue;
        final m = RegExp(r'^reporting=(\d)', multiLine: true).firstMatch(f.readAsStringSync());
        if (m != null) return m.group(1) == '1';
      } catch (_) {}
    }
    return null;
  }

  Future<bool> _confirm(String title, String body, String action, {bool danger = false}) async {
    final c = C.of(context);
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: c.panel,
            title: Text(title, style: TextStyle(fontSize: 16, color: c.text)),
            content: SizedBox(
              width: 420,
              child: Text(body, style: TextStyle(fontSize: 13, height: 1.45, color: c.muted)),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(
                style: danger ? FilledButton.styleFrom(backgroundColor: c.bad, foregroundColor: Colors.white) : null,
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(action),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// A task that changes the SDK: when it works, everything reads the
  /// version again.
  Future<void> _sdkTask(String title, List<String> args) async {
    final code = await runTask(title, args);
    if (code == null) {
      if (mounted) _say('Another task is still running. Wait for it or cancel it in the console.');
      return;
    }
    if (code == 0) sdkChanged.value++;
  }

  Future<void> _setConfig(List<String> args, String done) async {
    final out = await _run(['config', ...args]);
    if (!mounted) return;
    if (out == null) {
      _say("Couldn't change the setting.");
    } else {
      _say(done);
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final v = _version;
    return ListView(
      padding: const EdgeInsets.only(bottom: 40),
      children: [
        PageHeader(
          title: 'Flutter SDK',
          subtitle: Sdk.instance.flutterBin == null ? 'Flutter was not found.' : p.dirname(p.dirname(Sdk.instance.flutterBin!)),
          actions: [
            OutlinedButton.icon(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Refresh'),
            ),
          ],
        ),
        if (Projects.instance.current != null && Fvm.pinFor(Projects.instance.current!.path) != null)
          _body(c, [
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                children: [
                  Icon(Icons.layers_outlined, size: 15, color: c.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This page changes your default Flutter. ${Projects.instance.current!.name} uses '
                      'Flutter ${Fvm.pinFor(Projects.instance.current!.path)!.version} from FVM, which is managed in Flutter versions.',
                      style: TextStyle(fontSize: 12.5, color: c.muted),
                    ),
                  ),
                  TextButton(onPressed: () => Bench.instance.open(const EditorTab(TabKind.fvm)), child: const Text('Open')),
                ],
              ),
            ),
          ]),
        _body(c, [
          // Version facts.
          _fact(c, 'Flutter', v == null ? (_loading ? '…' : 'unknown') : '${v['frameworkVersion']}'),
          _fact(c, 'Channel', v == null ? '…' : '${v['channel']}'),
          _fact(c, 'Dart', v == null ? '…' : '${v['dartSdkVersion']}'),
          _fact(c, 'Revision', v == null ? '…' : '${v['frameworkRevisionShort'] ?? v['frameworkRevision'] ?? ''}', mono: true),

          _section(c, 'Updates', 'Check first; upgrading changes Flutter for every project on this computer.'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                onPressed: () => runTask('Check for updates', ['upgrade', '--verify-only']),
                child: const Text('Check for updates'),
              ),
              FilledButton(
                onPressed: () async {
                  if (await _confirm(
                    'Upgrade Flutter?',
                    'This downloads the newest Flutter on the ${v?['channel'] ?? 'current'} channel. Every project on this computer uses it afterwards. You can downgrade back if something breaks.',
                    'Upgrade',
                  )) {
                    _sdkTask('Upgrade Flutter', ['upgrade', if (_forceUpgrade) '--force']);
                  }
                },
                child: const Text('Upgrade'),
              ),
              _check(c, 'Force (discards local changes to the SDK)', _forceUpgrade, (x) => setState(() => _forceUpgrade = x)),
              TextButton(
                onPressed: () async {
                  if (await _confirm(
                    'Go back to the previous Flutter?',
                    'This returns Flutter to the version you had on this channel before the last upgrade.',
                    'Downgrade',
                    danger: true,
                  )) {
                    // We asked already; the tool's own y/n prompt can't be answered here.
                    _sdkTask('Downgrade Flutter', ['downgrade', '--no-prompt']);
                  }
                },
                child: Text('Downgrade', style: TextStyle(color: c.bad)),
              ),
            ],
          ),

          _section(c, 'Channel', 'Stable is right for apps you ship. Beta and main get features earlier and break more often.'),
          if (_channels.isEmpty)
            Text(_loading ? '…' : 'Couldn\'t read the channels.', style: TextStyle(fontSize: 12.5, color: c.muted)),
          for (final ch in _channels)
            InkWell(
              onTap: () => setState(() => _pick = ch.name),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      _pick == ch.name ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                      size: 17,
                      color: _pick == ch.name ? c.accent : c.muted,
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 70,
                      child: Text(
                        ch.name,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text),
                      ),
                    ),
                    Expanded(
                      child: Text(ch.about, style: TextStyle(fontSize: 12.5, color: c.muted)),
                    ),
                    if (ch.current) Text('current', style: TextStyle(fontSize: 11.5, color: c.good)),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton(
                onPressed: _pick == null || _channels.any((ch) => ch.current && ch.name == _pick)
                    ? null
                    : () async {
                        if (await _confirm(
                          'Switch to $_pick?',
                          'Flutter switches channel for every project on this computer and downloads what it needs. This can take a few minutes.',
                          'Switch',
                        )) {
                          _sdkTask('Switch to $_pick', ['channel', _pick!, if (!_cacheArtifacts) '--no-cache-artifacts']);
                        }
                      },
                child: const Text('Switch channel'),
              ),
              _check(
                c,
                'Download tools for every platform after switching',
                _cacheArtifacts,
                (x) => setState(() => _cacheArtifacts = x),
              ),
            ],
          ),

          _section(
            c,
            'Download tools',
            'Fetch the engine files a platform needs now, so the first build or run doesn\'t wait for them.',
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (id, label) in const [
                ('ios', 'iOS'),
                ('macos', 'macOS'),
                ('web', 'Web'),
                ('windows', 'Windows'),
                ('linux', 'Linux'),
              ])
                FilterChip(
                  label: Text(label, style: const TextStyle(fontSize: 12.5)),
                  selected: _precache.contains(id),
                  showCheckmark: false,
                  onSelected: _precacheAll ? null : (x) => setState(() => x ? _precache.add(id) : _precache.remove(id)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton(
                onPressed: () => runTask('Download tools', [
                  'precache',
                  if (_precacheAll) '--all-platforms',
                  if (_precacheForce) '--force',
                  if (!_precacheAll)
                    for (final x in const ['ios', 'macos', 'web', 'windows', 'linux']) _precache.contains(x) ? '--$x' : '--no-$x',
                ]),
                child: const Text('Download'),
              ),
              _check(c, 'Every host platform', _precacheAll, (x) => setState(() => _precacheAll = x)),
              _check(c, 'Download again', _precacheForce, (x) => setState(() => _precacheForce = x)),
            ],
          ),

          _section(c, 'Features', 'Turn platforms and experiments on or off for the Flutter tool. Changes apply at once.'),
          for (final e in _config.entries.where((e) => !_paths.containsKey(e.key) && !_unavailable.contains(e.key)))
            _feature(c, e.key, e.value),
          if (_unavailable.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Only on the main channel: ${_unavailable.join(', ')}',
                style: TextStyle(fontSize: 11.5, color: c.muted.withValues(alpha: 0.8)),
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: () async {
                  if (await _confirm('Reset every feature?', 'All the switches above go back to Flutter\'s defaults.', 'Reset')) {
                    _setConfig(['--clear-features'], 'Features reset to the defaults.');
                  }
                },
                child: const Text('Reset to defaults'),
              ),
              if (Platform.isMacOS)
                OutlinedButton(
                  onPressed: () => _setConfig(['--clear-ios-signing-settings'], 'The saved iOS signing choice is cleared.'),
                  child: const Text('Forget iOS signing choice'),
                ),
            ],
          ),

          _section(c, 'Locations', 'Where Flutter finds Android tools and Java. Leave empty to let Flutter look for them.'),
          for (final e in _paths.entries) _pathRow(c, e.key, e.value),

          _section(
            c,
            'Usage statistics',
            'Flutter and Dart send anonymous usage and crash reports to Google unless this is off.',
          ),
          Row(
            children: [
              Text(
                _analytics == null ? 'Unknown' : (_analytics! ? 'On' : 'Off'),
                style: TextStyle(fontSize: 13, color: c.text, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: _analytics == false
                    ? null
                    : () async {
                        await _run(['--disable-analytics']);
                        _load();
                      },
                child: const Text('Turn off'),
              ),
              const SizedBox(width: 6),
              TextButton(
                onPressed: _analytics == true
                    ? null
                    : () async {
                        await _run(['--enable-analytics']);
                        _load();
                      },
                child: const Text('Turn on'),
              ),
            ],
          ),

          _section(c, 'Shell completion', 'Tab-completion for flutter commands in your terminal (bash and zsh).'),
          Row(
            children: [
              OutlinedButton(
                onPressed: () async {
                  final home = Platform.environment['HOME'] ?? '';
                  final loc = await getSaveLocation(suggestedName: 'flutter-completion.sh', initialDirectory: home);
                  if (loc == null) return;
                  final out = await _run(['bash-completion', '--overwrite', loc.path]);
                  if (!mounted) return;
                  if (out != null && File(loc.path).existsSync()) {
                    setState(() => _completionPath = loc.path);
                  } else {
                    _say("Couldn't write the completion script.");
                  }
                },
                child: const Text('Save completion script…'),
              ),
            ],
          ),
          if (_completionPath != null) ...[
            const SizedBox(height: 8),
            Text(
              'Add this line to ~/.zshrc or ~/.bashrc, then open a new terminal:',
              style: TextStyle(fontSize: 12.5, color: c.muted),
            ),
            const SizedBox(height: 6),
            _copyLine(c, 'source "$_completionPath"'),
          ],
        ]),
      ],
    );
  }

  Widget _body(C c, List<Widget> children) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    ),
  );

  Widget _section(C c, String title, String about) => Padding(
    padding: const EdgeInsets.only(top: 30, bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.text),
        ),
        const SizedBox(height: 3),
        Text(about, style: TextStyle(fontSize: 12.5, color: c.muted)),
      ],
    ),
  );

  Widget _fact(C c, String k, String v, {bool mono = false}) => Container(
    padding: const EdgeInsets.symmetric(vertical: 8),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: c.line)),
    ),
    child: Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(k, style: TextStyle(fontSize: 13, color: c.muted)),
        ),
        Expanded(
          child: SelectableText(
            v,
            style: mono ? monoStyle.copyWith(fontSize: 12, color: c.text) : TextStyle(fontSize: 13, color: c.text),
          ),
        ),
      ],
    ),
  );

  Widget _check(C c, String label, bool value, ValueChanged<bool> set) => InkWell(
    onTap: () => set(!value),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(value: value, onChanged: (x) => set(x ?? false), visualDensity: VisualDensity.compact),
        Text(label, style: TextStyle(fontSize: 12.5, color: c.text)),
        const SizedBox(width: 6),
      ],
    ),
  );

  /// A feature switch. "Not set" means Flutter's own default applies.
  Widget _feature(C c, String key, String value) {
    final on = value == 'true';
    final off = value == 'false';
    final label = key.replaceFirst('enable-', '').replaceAll('-', ' ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: label[0].toUpperCase() + label.substring(1),
                    style: TextStyle(color: c.text),
                  ),
                  if (!on && !off)
                    TextSpan(
                      text: '   default',
                      style: TextStyle(color: c.muted, fontSize: 11.5),
                    ),
                ],
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('On', style: TextStyle(fontSize: 12))),
              ButtonSegment(value: false, label: Text('Off', style: TextStyle(fontSize: 12))),
            ],
            emptySelectionAllowed: true,
            showSelectedIcon: false,
            selected: {if (on) true, if (off) false},
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onSelectionChanged: (s) {
              if (s.isEmpty) return;
              final want = s.first;
              _setConfig([
                want ? '--$key' : '--no-$key',
              ], '${label[0].toUpperCase()}${label.substring(1)}: ${want ? 'on' : 'off'}');
            },
          ),
        ],
      ),
    );
  }

  Widget _pathRow(C c, String key, TextEditingController ctl) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        SizedBox(
          width: 160,
          child: Text(_pathLabels[key]!, style: TextStyle(fontSize: 13, color: c.text)),
        ),
        Expanded(
          child: TextField(
            controller: ctl,
            style: monoStyle.copyWith(fontSize: 12, color: c.text),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Not set',
              hintStyle: TextStyle(fontSize: 12.5, color: c.muted),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(5),
                borderSide: BorderSide(color: c.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(5),
                borderSide: BorderSide(color: c.line),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            ),
          ),
        ),
        if (key != 'build-dir')
          IconButton(
            tooltip: 'Choose folder',
            icon: const Icon(Icons.folder_open_rounded, size: 17),
            onPressed: () async {
              final dir = await getDirectoryPath(initialDirectory: ctl.text.isEmpty ? null : ctl.text);
              if (dir != null) ctl.text = dir;
            },
          ),
        TextButton(
          onPressed: () {
            final val = ctl.text.trim();
            if (val.isNotEmpty && key != 'build-dir' && !Directory(val).existsSync()) {
              _say("That folder doesn't exist.");
              return;
            }
            if (key == 'build-dir' && p.isAbsolute(val)) {
              _say('The build folder must be a relative path, like out/.');
              return;
            }
            _setConfig(['--$key', val], val.isEmpty ? '${_pathLabels[key]} cleared.' : '${_pathLabels[key]} saved.');
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );

  Widget _copyLine(C c, String text) => Container(
    padding: const EdgeInsets.only(left: 10),
    decoration: BoxDecoration(
      color: c.bg,
      border: Border.all(color: c.line),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Row(
      children: [
        Expanded(
          child: SelectableText(text, style: monoStyle.copyWith(fontSize: 12, color: c.text)),
        ),
        IconButton(
          tooltip: 'Copy',
          icon: const Icon(Icons.copy_rounded, size: 15),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            _say('Copied');
          },
        ),
      ],
    ),
  );
}
