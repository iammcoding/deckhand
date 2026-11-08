import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/devices.dart';
import '../../core/sdk.dart';
import '../shell.dart';
import '../theme.dart';

class SettingsPage extends StatefulWidget {
  final ValueNotifier<ThemeMode> themeMode;
  const SettingsPage({super.key, required this.themeMode});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, dynamic>? _version;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final v = await Sdk.instance.version();
    if (mounted) setState(() => _version = v);
  }

  Future<void> _pickFlutter() async {
    final f = await openFile(confirmButtonText: 'Use this Flutter');
    if (f == null) return;
    final ok = f.path.endsWith('flutter') || f.path.endsWith('flutter.bat');
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick the flutter file inside your Flutter SDK\'s bin folder.')));
      }
      return;
    }
    await Sdk.instance.setFlutterBin(f.path);
    setState(() => _version = null);
    _loadVersion();
    Devices.instance.refresh();
  }

  Future<void> _setTheme(ThemeMode m) async {
    widget.themeMode.value = m;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme', m.name);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final v = _version;
    Widget row(String label, Widget value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 160, child: Text(label, style: TextStyle(fontSize: 13, color: c.muted))),
            Expanded(child: value),
          ]),
        );
    return ListView(padding: EdgeInsets.zero, children: [
      const PageHeader(title: 'Settings'),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: c.panel, border: Border.all(color: c.line), borderRadius: BorderRadius.circular(6)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Flutter SDK', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.text)),
            const SizedBox(height: 6),
            row(
              'Flutter command',
              Row(children: [
                Expanded(
                  child: SelectableText(Sdk.instance.flutterBin ?? 'Not found',
                      style: mono.copyWith(color: Sdk.instance.ready ? c.text : c.bad)),
                ),
                OutlinedButton(onPressed: _pickFlutter, child: const Text('Change')),
              ]),
            ),
            row('Version', Text(v == null ? '…' : '${v['frameworkVersion']} · ${v['channel']}', style: TextStyle(color: c.text))),
            row('Dart', Text(v == null ? '…' : '${v['dartSdkVersion']}', style: TextStyle(color: c.text))),
            row('This computer', Text('${Platform.operatingSystem} ${Platform.operatingSystemVersion}', style: TextStyle(color: c.text))),
            const SizedBox(height: 14),
            Divider(color: c.line, height: 1),
            const SizedBox(height: 14),
            Text('Appearance', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.text)),
            const SizedBox(height: 10),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
              ],
              selected: {widget.themeMode.value},
              showSelectedIcon: false,
              onSelectionChanged: (s) => _setTheme(s.first),
            ),
          ]),
        ),
      ),
    ]);
  }
}
