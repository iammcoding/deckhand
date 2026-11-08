import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/bench.dart';
import '../../core/devices.dart';
import '../../core/jobs.dart';
import '../../core/projects.dart';
import '../../core/sdk.dart';
import '../../core/sessions.dart';
import '../side/build_side.dart' show reveal;
import '../theme.dart';
import '../widgets/page_header.dart';

class _Emulator {
  final String id, name, maker, platform;
  const _Emulator(this.id, this.name, this.maker, this.platform);
}

typedef _Custom = ({String id, String label, bool enabled});

/// Devices, emulators and custom devices, and what you can do with each:
/// screenshot, install, uninstall, read its log, attach to a running app.
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  static IconData icon(String family) => switch (family) {
    'android' => Icons.android_rounded,
    'ios' => Icons.phone_iphone_rounded,
    'macos' => Icons.laptop_mac_rounded,
    'windows' => Icons.desktop_windows_rounded,
    'linux' => Icons.terminal_rounded,
    'web' => Icons.public_rounded,
    _ => Icons.devices_other_rounded,
  };

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  List<_Emulator>? _emulators;
  String? _emuNote;
  final Set<String> _launching = {};
  List<_Custom>? _custom; // null until read
  bool _customOff = false; // the feature is switched off
  String? _customPath;
  final Set<String> _busy = {}; // device ids taking a screenshot

  @override
  void initState() {
    super.initState();
    _loadEmulators();
    _loadCustom();
  }

  void _say(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<ProcessResult?> _run(List<String> args, {String? cwd, Duration timeout = const Duration(minutes: 2)}) async {
    try {
      return await Sdk.instance.run(args, cwd: cwd, timeout: timeout);
    } catch (e) {
      if (mounted) _say('$e');
      return null;
    }
  }

  // ---- Emulators -------------------------------------------------------------

  Future<void> _loadEmulators() async {
    final r = await _run(['emulators']);
    if (!mounted) return;
    final out = '${r?.stdout ?? ''}';
    final list = <_Emulator>[];
    // A table: "Id • Name • Manufacturer • Platform", then one row each.
    for (final l in out.split('\n')) {
      final cols = l.split(' • ').map((x) => x.trim()).toList();
      if (cols.length < 2 || cols[0] == 'Id') continue;
      list.add(_Emulator(cols[0], cols[1], cols.length > 2 ? cols[2] : '', cols.length > 3 ? cols[3] : ''));
    }
    setState(() {
      _emulators = list;
      _emuNote = list.isEmpty
          ? (out.contains('Unable to find')
                ? 'None found. Android Studio (with an emulator image) or Xcode (with a simulator) provides them.'
                : 'None yet.')
          : null;
    });
  }

  Future<void> _launch(_Emulator e, {bool cold = false}) async {
    setState(() => _launching.add(e.id));
    final r = await _run(['emulators', '--launch', e.id, if (cold) '--cold'], timeout: const Duration(minutes: 3));
    if (!mounted) return;
    setState(() => _launching.remove(e.id));
    if (r != null && r.exitCode != 0) {
      final why = '${r.stderr}'.trim();
      _say(why.isNotEmpty ? why : "Couldn't start ${e.name}.");
      return;
    }
    // Booting takes a while; look for it a few times.
    for (final s in [5, 15, 30]) {
      Future.delayed(Duration(seconds: s), Devices.instance.refresh);
    }
  }

  Future<void> _createEmulator() async {
    final c = C.of(context);
    final name = TextEditingController();
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: c.panel,
            title: Text('New Android emulator', style: TextStyle(fontSize: 16, color: c.text)),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Flutter makes a Pixel emulator from the newest Android system image installed.',
                    style: TextStyle(fontSize: 12.5, color: c.muted),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: name,
                    autofocus: true,
                    style: TextStyle(fontSize: 13, color: c.text),
                    decoration: const InputDecoration(isDense: true, hintText: 'Name (optional), like pixel_api_35'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
            ],
          ),
        ) ??
        false;
    final n = name.text.trim().replaceAll(RegExp(r'\s+'), '_');
    name.dispose();
    if (!ok) return;
    final code = await runTask('Create emulator', [
      'emulators',
      '--create',
      if (n.isNotEmpty) ...['--name', n],
    ]);
    if (code == null && mounted) _say('Another task is still running.');
    if (code == 0) _loadEmulators();
  }

  // ---- Custom devices --------------------------------------------------------

  Future<void> _loadCustom() async {
    final r = await _run(['custom-devices', 'list']);
    if (!mounted) return;
    final out = '${r?.stdout ?? ''}${r?.stderr ?? ''}';
    if (out.contains('must be enabled')) {
      setState(() {
        _customOff = true;
        _custom = const [];
      });
      return;
    }
    final list = <_Custom>[
      for (final m in RegExp(r'id: (.+?), label: (.+?), enabled: (true|false)').allMatches(out))
        (id: m.group(1)!, label: m.group(2)!, enabled: m.group(3) == 'true'),
    ];
    setState(() {
      _customOff = false;
      _custom = list;
      _customPath = RegExp(r'in "(.+?)"').firstMatch(out)?.group(1);
    });
  }

  Future<void> _addCustom() async {
    final c = C.of(context);
    final json = TextEditingController(text: _customTemplate);
    var check = true;
    String? error;
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
              backgroundColor: c.panel,
              title: Text('Add a custom device', style: TextStyle(fontSize: 16, color: c.text)),
              content: SizedBox(
                width: 580,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'A custom device is anything Flutter can reach through commands you give it, like a Raspberry Pi over ssh. '
                      'Describe it in JSON. The template is for a Pi at raspberrypi.local running flutter-pi.',
                      style: TextStyle(fontSize: 12.5, height: 1.4, color: c.muted),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 300,
                      child: TextField(
                        controller: json,
                        maxLines: null,
                        expands: true,
                        style: monoStyle.copyWith(fontSize: 11.5, color: c.text),
                        decoration: InputDecoration(
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                          errorText: error,
                          contentPadding: const EdgeInsets.all(10),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Checkbox(value: check, onChanged: (x) => setD(() => check = x ?? true)),
                        Text('Check that it works before saving', style: TextStyle(fontSize: 12.5, color: c.text)),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(
                  onPressed: () {
                    try {
                      final j = jsonDecode(json.text);
                      if (j is! Map || '${j['id'] ?? ''}'.isEmpty) throw const FormatException('it needs an "id"');
                      Navigator.pop(ctx, true);
                    } on FormatException catch (e) {
                      setD(() => error = 'Not valid: ${e.message}');
                    }
                  },
                  child: const Text('Add'),
                ),
              ],
            ),
          ),
        ) ??
        false;
    final text = json.text;
    json.dispose();
    if (!ok) return;
    // One line, passed to the tool as a single argument.
    final compact = jsonEncode(jsonDecode(text));
    final code = await runTask('Add custom device', [
      'custom-devices',
      'add',
      '--json=$compact',
      check ? '--check' : '--no-check',
    ]);
    if (code == null && mounted) _say('Another task is still running.');
    if (code != null) {
      _loadCustom();
      Devices.instance.refresh();
    }
  }

  static const _customTemplate = r'''{
  "id": "pi",
  "label": "Raspberry Pi",
  "sdkNameAndVersion": "Raspberry Pi 4",
  "platform": "linux-arm64",
  "enabled": true,
  "ping": ["ping", "-c", "1", "raspberrypi.local"],
  "pingSuccessRegex": null,
  "postBuild": null,
  "install": ["scp", "-r", "-o", "BatchMode=yes", "${localPath}", "pi@raspberrypi.local:/tmp/${appName}"],
  "uninstall": ["ssh", "-o", "BatchMode=yes", "pi@raspberrypi.local", "rm -rf \"/tmp/${appName}\""],
  "runDebug": ["ssh", "-o", "BatchMode=yes", "pi@raspberrypi.local", "flutter-pi \"/tmp/${appName}\""],
  "forwardPort": ["ssh", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-L", "127.0.0.1:${hostPort}:127.0.0.1:${devicePort}", "pi@raspberrypi.local", "echo 'Port forwarding success'; read"],
  "forwardPortSuccessRegex": "Port forwarding success",
  "screenshot": null
}''';

  // ---- Device actions --------------------------------------------------------

  Future<void> _screenshot(Device d) async {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
    final dir = Directory(p.join(home, 'Pictures', 'Deckhand'));
    await dir.create(recursive: true);
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final file = p.join(
      dir.path,
      '${d.name.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')}-'
      '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}.png',
    );
    setState(() => _busy.add(d.id));
    final r = await _run(['screenshot', '-d', d.id, '-o', file]);
    if (!mounted) return;
    setState(() => _busy.remove(d.id));
    if (r == null || r.exitCode != 0 || !File(file).existsSync()) {
      final why = '${r?.stderr ?? ''}\n${r?.stdout ?? ''}'.trim().split('\n').where((l) => l.trim().isNotEmpty).lastOrNull;
      _say(why ?? "Couldn't take a screenshot of ${d.name}.");
      return;
    }
    _showShot(file);
  }

  void _showShot(String file) {
    final c = C.of(context);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: c.panel,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Padding(padding: const EdgeInsets.all(12), child: Image.file(File(file))),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        file,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle.copyWith(fontSize: 11.5, color: c.muted),
                      ),
                    ),
                    TextButton(onPressed: () => reveal(file), child: const Text('Show in folder')),
                    FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _install(Device d, {required bool uninstall}) async {
    final pr = Projects.instance.current;
    if (pr == null) return;
    var mode = 'release';
    if (!uninstall) {
      final c = C.of(context);
      final picked = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          backgroundColor: c.panel,
          title: Text('Install ${pr.name} on ${d.name}', style: TextStyle(fontSize: 15, color: c.text)),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Installs the app you last built in that mode. Build it first if you haven\'t.',
                style: TextStyle(fontSize: 12.5, color: c.muted),
              ),
            ),
            for (final m in const ['release', 'profile', 'debug'])
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, m),
                child: Text(m[0].toUpperCase() + m.substring(1), style: TextStyle(fontSize: 13, color: c.text)),
              ),
          ],
        ),
      );
      if (picked == null) return;
      mode = picked;
    }
    final code = await runTask(uninstall ? 'Uninstall from ${d.name}' : 'Install on ${d.name}', [
      'install',
      '-d',
      d.id,
      if (uninstall) '--uninstall-only' else '--$mode',
    ], cwd: pr.path);
    if (code == null && mounted) _say('Another task is still running.');
  }

  Future<void> _logs(Device d) async {
    final old = currentLogs.value;
    if (old != null && old.running) old.cancel();
    Bench.instance.showBottom(BottomTab.logs);
    await startJob(currentLogs, Job('Log · ${d.name}', ['logs', '-d', d.id]));
  }

  Future<void> _attach(Device d) async {
    final pr = Projects.instance.current;
    if (pr == null) return;
    final old = currentRun.value;
    if (old != null && !old.stopped) await old.stop();
    old?.dispose();
    final s = RunSession(projectPath: pr.path, deviceId: d.id, deviceName: d.name, attach: true);
    currentRun.value = s;
    Bench.instance.showBottom(BottomTab.run);
    s.start();
  }

  // ---- UI ----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([Devices.instance, Projects.instance]),
      builder: (context, _) {
        final d = Devices.instance;
        final hasProject = Projects.instance.current != null;
        return ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            PageHeader(
              title: 'Devices',
              subtitle: 'Phones, simulators, emulators and this computer, as Flutter sees them.',
              actions: [
                OutlinedButton.icon(
                  onPressed: () {
                    d.refresh();
                    _loadEmulators();
                    _loadCustom();
                  },
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Refresh'),
                ),
              ],
            ),
            _pad(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _section(c, 'Connected'),
                  if (d.error != null) Text(d.error!, style: TextStyle(color: c.bad, fontSize: 12.5)),
                  if (d.list.isEmpty)
                    Text(
                      d.loading ? 'Looking for devices…' : 'Nothing connected. Plug in a phone, or start an emulator below.',
                      style: TextStyle(fontSize: 12.5, color: c.muted),
                    ),
                  for (final dev in d.list) _deviceRow(c, dev, hasProject),
                  _section(c, 'Emulators and simulators', action: ('New Android emulator', _createEmulator)),
                  if (_emulators == null) Text('Looking…', style: TextStyle(fontSize: 12.5, color: c.muted)),
                  if (_emuNote != null) Text(_emuNote!, style: TextStyle(fontSize: 12.5, color: c.muted)),
                  for (final e in _emulators ?? const <_Emulator>[])
                    _row(
                      c,
                      icon: DevicesPage.icon(e.platform),
                      title: e.name,
                      sub: [e.maker, e.platform].where((x) => x.isNotEmpty).join(' · '),
                      trailing: [
                        if (_launching.contains(e.id))
                          Text('Starting…', style: TextStyle(fontSize: 12, color: c.muted))
                        else ...[
                          if (e.platform == 'android')
                            TextButton(onPressed: () => _launch(e, cold: true), child: const Text('Cold boot')),
                          OutlinedButton(onPressed: () => _launch(e), child: const Text('Start')),
                        ],
                      ],
                    ),
                  _section(c, 'Custom devices', action: _customOff ? null : ('Add', _addCustom)),
                  if (_custom == null) Text('Looking…', style: TextStyle(fontSize: 12.5, color: c.muted)),
                  if (_customOff)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'For boards and machines Flutter doesn\'t know, like a Raspberry Pi. This is off.',
                            style: TextStyle(fontSize: 12.5, color: c.muted),
                          ),
                        ),
                        OutlinedButton(
                          onPressed: () async {
                            await _run(['config', '--enable-custom-devices']);
                            _loadCustom();
                          },
                          child: const Text('Turn on'),
                        ),
                      ],
                    ),
                  if (!_customOff && (_custom?.isEmpty ?? false))
                    Text('None yet.', style: TextStyle(fontSize: 12.5, color: c.muted)),
                  for (final cd in _custom ?? const <_Custom>[])
                    _row(
                      c,
                      icon: Icons.developer_board_rounded,
                      title: cd.label,
                      sub: '${cd.id}${cd.enabled ? '' : ' · disabled'}',
                      trailing: [
                        TextButton(
                          onPressed: () async {
                            final r = await _run(['custom-devices', 'delete', '-d', cd.id]);
                            if (r != null && r.exitCode != 0 && mounted) _say('${r.stderr}'.trim());
                            _loadCustom();
                            Devices.instance.refresh();
                          },
                          child: Text('Remove', style: TextStyle(color: c.bad)),
                        ),
                      ],
                    ),
                  if (!_customOff && (_custom?.isNotEmpty ?? false))
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _customPath ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: monoStyle.copyWith(fontSize: 11, color: c.muted),
                            ),
                          ),
                          TextButton(
                            onPressed: () async {
                              final r = await _run(['custom-devices', 'reset']);
                              if (r != null && mounted) _say('${r.stdout}'.trim().split('\n').last);
                              _loadCustom();
                            },
                            child: const Text('Reset (keeps a backup)'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _deviceRow(C c, Device dev, bool hasProject) {
    final d = Devices.instance;
    final on = d.selected?.id == dev.id;
    final busy = _busy.contains(dev.id);
    return _row(
      c,
      icon: DevicesPage.icon(dev.family),
      title: dev.name,
      sub: '${dev.sdk}${dev.emulator ? ' · simulator' : ''} · ${dev.id}',
      selected: on,
      onTap: () => d.select(dev.id),
      trailing: [
        if (on)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text('in use', style: TextStyle(fontSize: 11.5, color: c.accent)),
          ),
        IconButton(
          tooltip: 'Screenshot',
          icon: busy
              ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: c.muted))
              : const Icon(Icons.photo_camera_outlined, size: 17),
          onPressed: busy ? null : () => _screenshot(dev),
        ),
        IconButton(tooltip: 'Device log', icon: const Icon(Icons.notes_rounded, size: 17), onPressed: () => _logs(dev)),
        PopupMenuButton<String>(
          tooltip: 'More',
          color: c.panel,
          icon: const Icon(Icons.more_horiz_rounded, size: 18),
          onSelected: (v) {
            switch (v) {
              case 'install':
                _install(dev, uninstall: false);
              case 'uninstall':
                _install(dev, uninstall: true);
              case 'attach':
                _attach(dev);
              case 'use':
                d.select(dev.id);
            }
          },
          itemBuilder: (_) => [
            _item(c, 'use', 'Use for Run'),
            _item(c, 'install', 'Install the app…', enabled: hasProject),
            _item(c, 'uninstall', 'Uninstall the app', enabled: hasProject),
            _item(c, 'attach', 'Attach to the running app', enabled: hasProject),
          ],
        ),
      ],
    );
  }

  PopupMenuItem<String> _item(C c, String v, String t, {bool enabled = true}) => PopupMenuItem(
    value: v,
    height: 32,
    enabled: enabled,
    child: Text(t, style: TextStyle(fontSize: 13, color: enabled ? c.text : c.muted)),
  );

  Widget _pad(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 860), child: child),
  );

  Widget _section(C c, String title, {(String, VoidCallback)? action}) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.text),
          ),
        ),
        if (action != null) TextButton(onPressed: action.$2, child: Text(action.$1)),
      ],
    ),
  );

  Widget _row(
    C c, {
    required IconData icon,
    required String title,
    required String sub,
    List<Widget> trailing = const [],
    bool selected = false,
    VoidCallback? onTap,
  }) => Material(
    color: selected ? c.raised : Colors.transparent,
    borderRadius: BorderRadius.circular(6),
    child: InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 20, color: selected ? c.accent : c.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.text),
                  ),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.muted),
                  ),
                ],
              ),
            ),
            ...trailing,
          ],
        ),
      ),
    ),
  );
}
