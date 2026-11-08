import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/fvm.dart';
import '../../core/jobs.dart';
import '../../core/problems.dart';
import '../../core/projects.dart';
import '../../core/sdk.dart';
import '../../core/sessions.dart';
import '../theme.dart';
import '../widgets/page_header.dart';

/// FVM: which Flutter this project uses, the versions on this computer, and
/// the ones you can install. Downloads run in the console's Tasks tab.
class FvmPage extends StatefulWidget {
  const FvmPage({super.key});

  @override
  State<FvmPage> createState() => _FvmPageState();
}

class _FvmPageState extends State<FvmPage> {
  // Kept between visits, so the tab opens with what it knew, then updates.
  static List<FvmVersion>? _versions;
  static final Map<String, List<FvmRelease>> _releases = {};
  static String _size = '';
  static ({List<String> unused, List<String> removable, List<String> upgrades})? _cleanup;

  String? _error;
  String? _releaseError;
  String _channel = 'stable';
  final _search = TextEditingController();
  int _shown = 12;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    Fvm.instance.addListener(_fvmChanged);
    _load();
  }

  @override
  void dispose() {
    Fvm.instance.removeListener(_fvmChanged);
    _search.dispose();
    super.dispose();
  }

  void _fvmChanged() {
    if (!mounted) return;
    setState(() {});
    if (Fvm.instance.installed && _versions == null) _load();
  }

  void _say(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _load() async {
    final fvm = Fvm.instance;
    if (!fvm.installed) return;
    try {
      final r = await fvm.list();
      if (!mounted) return;
      setState(() {
        _versions = r.versions;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    _loadReleases();
    // Slower, and nothing waits for them.
    fvm.cleanup().then((x) {
      if (mounted) setState(() => _cleanup = x);
    });
    fvm
        .list(sizes: true)
        .then((r) {
          if (mounted) setState(() => _size = r.size);
        })
        .catchError((_) {});
  }

  Future<void> _loadReleases() async {
    final ch = _channel;
    try {
      final r = await Fvm.instance.releases(channel: ch);
      if (!mounted) return;
      setState(() {
        _releases[ch] = r;
        _releaseError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _releaseError = "Couldn't get the list of releases: $e");
    }
  }

  /// Something is using an SDK right now: switching or deleting it underneath
  /// would break that, so wait.
  bool get _sdkInUse {
    final run = currentRun.value;
    return (run != null && !run.stopped) || (currentBuild.value?.running ?? false);
  }

  bool _clear() {
    if (!_sdkInUse) return true;
    _say('Stop the running app or build first.');
    return false;
  }

  Future<void> _task(String title, List<String> args, {String? cwd, bool analyze = false}) async {
    final code = await runTask(title, ['fvm', ...args], cwd: cwd);
    if (code == null) {
      if (mounted) _say('Another task is still running. Wait for it or cancel it in the console.');
      return;
    }
    await Fvm.instance.detect();
    if (!mounted) return;
    sdkChanged.value++;
    if (code == 0 && analyze && cwd != null) Problems.instance.run(cwd);
    _load();
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

  // ---- Actions -----------------------------------------------------------------

  Future<void> _install(String version) => _task('Install Flutter $version', ['install', version]);

  Future<void> _use(String version, Project pr) async {
    if (!_clear()) return;
    await _task('Use Flutter $version in ${pr.name}', ['use', version, '--force'], cwd: pr.path, analyze: true);
  }

  Future<void> _remove(FvmVersion v, FvmPin? pin) async {
    if (!_clear()) return;
    final pinnedHere = pin?.version == v.name;
    final global = Fvm.instance.globalVersion == v.name;
    final ok = await _confirm(
      'Remove Flutter ${v.name}?',
      'This deletes it from this computer. Any project pinned to it needs it installed again.'
          '${pinnedHere ? ' This project is pinned to it.' : ''}'
          '${global ? ' It is also your global version.' : ''}',
      'Remove',
      danger: true,
    );
    if (ok) await _task('Remove Flutter ${v.name}', ['remove', v.name]);
  }

  Future<void> _makeDefault(FvmVersion v) async {
    final bin = p.join(v.directory, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter');
    if (!File(bin).existsSync()) {
      _say("Flutter isn't where FVM says it is: $bin");
      return;
    }
    await Sdk.instance.setFlutterBin(bin);
    sdkChanged.value++;
    if (mounted) {
      _say('Projects without a pin now use Flutter ${v.name} in Deckhand.');
      setState(() {});
    }
  }

  Future<void> _unpin(FvmPin pin) async {
    if (!_clear()) return;
    final ok = await _confirm(
      'Stop using FVM here?',
      'This deletes ${p.relative(pin.configPath, from: pin.root)} and the .fvm folder from ${pin.root}. '
          'The project goes back to your default Flutter. Installed versions stay. '
          'If those files are in git, your teammates will see them removed.',
      'Stop using FVM',
      danger: true,
    );
    if (!ok) return;
    try {
      await Fvm.unpin(pin);
    } catch (e) {
      if (mounted) _say("Couldn't remove it: $e");
      return;
    }
    sdkChanged.value++;
    Problems.instance.run(Projects.instance.current?.path ?? pin.root);
    if (mounted) setState(() {});
  }

  Future<void> _lookAgain() async {
    setState(() => _checking = true);
    await Fvm.instance.detect();
    if (!mounted) return;
    setState(() => _checking = false);
    if (Fvm.instance.installed) {
      _load();
    } else {
      _say("FVM still wasn't found.");
    }
  }

  Future<void> _installFvm() async {
    final code = await runTask('Install FVM', ['dart', 'pub', 'global', 'activate', 'fvm']);
    if (code == null) {
      if (mounted) _say('Another task is still running.');
      return;
    }
    if (code == 0) await _lookAgain();
  }

  // ---- UI ------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([Projects.instance, currentRun, currentBuild, currentTask, sdkChanged]),
      builder: (context, _) {
        final fvm = Fvm.instance;
        final pr = Projects.instance.current;
        final pin = Fvm.pinFor(pr?.path);
        return ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            PageHeader(
              title: 'Flutter versions',
              subtitle: fvm.installed
                  ? 'FVM ${fvm.version ?? ''} · ${fvm.versionsDir}'
                  : 'Keep several Flutter versions, and give each project its own.',
              actions: [
                if (fvm.installed) ...[
                  OutlinedButton(
                    onPressed: () => runTask('FVM doctor', ['fvm', 'doctor'], cwd: pr?.path),
                    child: const Text('Doctor'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Refresh'),
                  ),
                ],
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!fvm.installed) _notInstalled(c, pin),
                    if (fvm.installed) ...[
                      if (_error != null) Text(_error!, style: TextStyle(fontSize: 12.5, color: c.bad)),
                      if (pr != null) _thisProject(c, pr, pin),
                      _installed(c, pr, pin),
                      _available(c),
                      _cleanupSection(c),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _notInstalled(C c, FvmPin? pin) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (pin != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(
            Fvm.instance.sdkDirFor(pin) != null
                ? 'This project pins Flutter ${pin.version}, and Deckhand already uses it. Install FVM to change versions from here.'
                : 'This project pins Flutter ${pin.version}, which isn\'t on this computer. Install FVM to get it.',
            style: TextStyle(fontSize: 13, color: c.text),
          ),
        ),
      Text(
        'FVM isn\'t installed. Deckhand can install it with Dart\'s own package tool: dart pub global activate fvm.',
        style: TextStyle(fontSize: 13, height: 1.45, color: c.muted),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          FilledButton(onPressed: Sdk.instance.ready ? _installFvm : null, child: const Text('Install FVM')),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _checking ? null : _lookAgain,
            child: Text(_checking ? 'Looking…' : 'I installed it another way'),
          ),
        ],
      ),
    ],
  );

  Widget _thisProject(C c, Project pr, FvmPin? pin) {
    final here = pin != null && Fvm.instance.sdkDirFor(pin) != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _section(c, pr.name),
        if (pin == null)
          Text(
            'Not pinned, so it uses your default Flutter. Pick a version below and press Use here.',
            style: TextStyle(fontSize: 13, color: c.muted),
          )
        else ...[
          Row(
            children: [
              Icon(
                here ? Icons.check_circle_outline_rounded : Icons.warning_amber_rounded,
                size: 17,
                color: here ? c.good : c.warn,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  here
                      ? 'Uses Flutter ${pin.version}'
                      : 'Pins Flutter ${pin.version}, which isn\'t installed. It runs on your default Flutter until it is.',
                  style: TextStyle(fontSize: 13, color: c.text),
                ),
              ),
              if (!here) FilledButton(onPressed: () => _install(pin.version), child: Text('Install ${pin.version}')),
              TextButton(
                onPressed: () => _unpin(pin),
                child: Text('Stop using FVM', style: TextStyle(color: c.muted)),
              ),
            ],
          ),
          if (pin.root != pr.path)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 25),
              child: Text('From ${pin.configPath}', style: mono.copyWith(fontSize: 11.5, color: c.muted)),
            ),
          if (pin.flavors.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Flavors',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.muted),
            ),
            const SizedBox(height: 4),
            for (final f in pin.flavors.entries)
              Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(f.key, style: TextStyle(fontSize: 13, color: c.text)),
                  ),
                  Expanded(
                    child: Text(f.value, style: TextStyle(fontSize: 12.5, color: c.muted)),
                  ),
                  if (f.value == pin.version)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('active', style: TextStyle(fontSize: 11.5, color: c.good)),
                    )
                  else
                    TextButton(onPressed: () => _use(f.key, pr), child: const Text('Use')),
                ],
              ),
          ],
        ],
      ],
    );
  }

  Widget _installed(C c, Project? pr, FvmPin? pin) {
    final list = _versions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _section(c, 'On this computer', trailing: _size.isEmpty ? null : _size),
        if (list == null && _error == null) Text('Reading…', style: TextStyle(fontSize: 12.5, color: c.muted)),
        if (list != null && list.isEmpty) Text('None yet. Install one below.', style: TextStyle(fontSize: 13, color: c.muted)),
        for (final v in list ?? const <FvmVersion>[]) _versionRow(c, v, pr, pin),
      ],
    );
  }

  Widget _versionRow(C c, FvmVersion v, Project? pr, FvmPin? pin) {
    final fvm = Fvm.instance;
    final isPin = pin?.version == v.name;
    final isGlobal = fvm.globalVersion == v.name;
    final detail = [
      if (v.flutter.isNotEmpty && v.flutter != 'null' && v.flutter != v.name) 'Flutter ${v.flutter}',
      if (v.dart.isNotEmpty && v.dart != 'null') 'Dart ${v.dart}',
      if (v.channel.isNotEmpty && v.channel != 'null') v.channel,
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      v.name,
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.text),
                    ),
                    if (isPin) _tag(c, 'this project', c.good),
                    if (isGlobal) _tag(c, 'global', c.accent),
                    if (!v.isSetup) _tag(c, 'not set up', c.warn),
                    if (v.unused && !isPin && !isGlobal) _tag(c, 'unused', c.muted),
                  ],
                ),
                if (detail.isNotEmpty) Text(detail, style: TextStyle(fontSize: 12, color: c.muted)),
              ],
            ),
          ),
          if (pr != null && !isPin) OutlinedButton(onPressed: () => _use(v.name, pr), child: const Text('Use here')),
          PopupMenuButton<String>(
            tooltip: 'More',
            color: c.panel,
            icon: const Icon(Icons.more_horiz_rounded, size: 18),
            onSelected: (x) {
              switch (x) {
                case 'global':
                  _task('Set global Flutter to ${v.name}', ['global', v.name, '--force']);
                case 'unglobal':
                  _task('Unset global Flutter', ['global', '--unlink']);
                case 'default':
                  _makeDefault(v);
                case 'setup':
                  _task('Set up Flutter ${v.name}', ['install', v.name, '--setup']);
                case 'remove':
                  _remove(v, pin);
              }
            },
            itemBuilder: (_) => [
              if (!v.isSetup) _item(c, 'setup', 'Finish setup'),
              if (isGlobal) _item(c, 'unglobal', 'Unset global') else _item(c, 'global', 'Set as global'),
              _item(c, 'default', 'Make Deckhand\'s default'),
              _item(c, 'remove', 'Remove', color: c.bad),
            ],
          ),
        ],
      ),
    );
  }

  PopupMenuItem<String> _item(C c, String v, String t, {Color? color}) => PopupMenuItem(
    value: v,
    height: 32,
    child: Text(t, style: TextStyle(fontSize: 13, color: color ?? c.text)),
  );

  Widget _tag(C c, String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(4)),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
    ),
  );

  /// A version, channel or commit as typed. FVM gets it as one argument; a
  /// leading dash would read as an option.
  static bool _validName(String s) => RegExp(r'^[A-Za-z0-9][A-Za-z0-9._@+/-]*$').hasMatch(s);

  Widget _available(C c) {
    final q = _search.text.trim();
    final all = _releases[_channel];
    final hits = all?.where((r) => q.isEmpty || r.version.contains(q)).toList();
    final installed = {for (final v in _versions ?? const <FvmVersion>[]) v.name};
    final exact = hits?.any((r) => r.version == q) ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _section(c, 'Install a version'),
        Row(
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'stable',
                  label: Text('Stable', style: TextStyle(fontSize: 12)),
                ),
                ButtonSegment(
                  value: 'beta',
                  label: Text('Beta', style: TextStyle(fontSize: 12)),
                ),
              ],
              selected: {_channel},
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onSelectionChanged: (s) {
                setState(() {
                  _channel = s.first;
                  _shown = 12;
                });
                if (!_releases.containsKey(_channel)) _loadReleases();
              },
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() => _shown = 12),
                style: TextStyle(fontSize: 13, color: c.text),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Find a version, or type a channel like master',
                  hintStyle: TextStyle(fontSize: 12.5, color: c.muted),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: c.line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: c.line),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_releaseError != null) Text(_releaseError!, style: TextStyle(fontSize: 12.5, color: c.bad)),
        if (all == null && _releaseError == null) Text('Getting the list…', style: TextStyle(fontSize: 12.5, color: c.muted)),
        // Something the list doesn't have: a channel, a commit, an older version.
        if (q.isNotEmpty && !exact && _validName(q))
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    q,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text),
                  ),
                ),
                Text('As typed', style: TextStyle(fontSize: 12, color: c.muted)),
                const SizedBox(width: 10),
                OutlinedButton(onPressed: () => _install(q), child: const Text('Install')),
              ],
            ),
          ),
        for (final r in (hits ?? const <FvmRelease>[]).take(_shown))
          Container(
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 170,
                  child: Text(r.version, style: TextStyle(fontSize: 13, color: c.text)),
                ),
                Expanded(
                  child: Text(
                    [if (r.dart.isNotEmpty) 'Dart ${r.dart}', if (r.date != null) _date(r.date!)].join(' · '),
                    style: TextStyle(fontSize: 12, color: c.muted),
                  ),
                ),
                if (installed.contains(r.version))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Text('Installed', style: TextStyle(fontSize: 12, color: c.good)),
                  )
                else
                  TextButton(onPressed: () => _install(r.version), child: const Text('Install')),
              ],
            ),
          ),
        if ((hits?.length ?? 0) > _shown)
          TextButton(onPressed: () => setState(() => _shown += 30), child: const Text('Show more')),
      ],
    );
  }

  static String _date(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  Widget _cleanupSection(C c) {
    final x = _cleanup;
    if (x == null || (x.removable.isEmpty && x.upgrades.isEmpty)) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _section(c, 'Clean up'),
        for (final u in x.upgrades)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(u, style: TextStyle(fontSize: 12.5, color: c.muted)),
          ),
        if (x.removable.isNotEmpty) ...[
          Text('No project uses: ${x.removable.join(', ')}', style: TextStyle(fontSize: 13, color: c.text)),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () async {
              if (!_clear()) return;
              final ok = await _confirm(
                'Remove ${x.removable.length} unused ${x.removable.length == 1 ? 'version' : 'versions'}?',
                'FVM only knows the projects it has seen, so a project you haven\'t opened in a while could still need one: '
                    '${x.removable.join(', ')}.',
                'Remove',
                danger: true,
              );
              if (ok) await _task('Remove unused versions', ['cleanup', '--remove-unused', '--yes']);
            },
            child: const Text('Remove unused'),
          ),
        ],
      ],
    );
  }

  Widget _section(C c, String title, {String? trailing}) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.text),
          ),
        ),
        if (trailing != null) Text(trailing, style: TextStyle(fontSize: 12, color: c.muted)),
      ],
    ),
  );
}
