import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/ai.dart';
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
  final _key = TextEditingController();
  bool _savingKey = false;
  String? _keyMsg;

  Future<void> _saveKey(String? k) async {
    setState(() {
      _savingKey = true;
      _keyMsg = null;
    });
    try {
      await Ai.instance.setKey(k);
      _key.clear();
      _keyMsg = Ai.instance.connected ? 'Connected. The key is in your keychain.' : 'Removed.';
    } catch (e) {
      _keyMsg = '$e';
    }
    if (mounted) setState(() => _savingKey = false);
  }

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
            Text('AI', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.text)),
            const SizedBox(height: 4),
            Text('Ask AI on an error reads the log and your pubspec and suggests a fix. It uses your own Anthropic API key.',
                style: TextStyle(fontSize: 12.5, color: c.muted)),
            const SizedBox(height: 6),
            row('Model', Text('Claude Opus 5.5', style: TextStyle(color: c.text))),
            row(
              'Status',
              Row(children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: Ai.instance.connected ? c.good : c.muted, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(Ai.instance.connected ? 'Connected' : 'Not connected', style: TextStyle(color: c.text)),
                if (Ai.instance.connected) ...[
                  const Spacer(),
                  TextButton(
                    onPressed: _savingKey ? null : () => _saveKey(null),
                    child: Text('Remove key', style: TextStyle(color: c.bad)),
                  ),
                ],
              ]),
            ),
            row(
              'API key',
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _key,
                    obscureText: true,
                    style: mono.copyWith(color: c.text),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: Ai.instance.connected ? 'Replace the key' : 'sk-ant-…',
                      hintStyle: TextStyle(color: c.muted),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: BorderSide(color: c.line)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: BorderSide(color: c.line)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _savingKey ? null : () => _saveKey(_key.text),
                  child: Text(_savingKey ? 'Saving…' : 'Save'),
                ),
              ]),
            ),
            if (_keyMsg != null) Padding(padding: const EdgeInsets.only(left: 160), child: Text(_keyMsg!, style: TextStyle(fontSize: 12, color: c.muted))),
            Padding(
              padding: const EdgeInsets.only(left: 160, top: 4),
              child: Text('Get a key at console.anthropic.com → API keys. It never leaves this computer except to call the API.',
                  style: TextStyle(fontSize: 11.5, color: c.muted.withValues(alpha: 0.8))),
            ),
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
