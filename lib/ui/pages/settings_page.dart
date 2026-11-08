import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/agents.dart';
import '../../core/ai.dart';
import '../../core/devices.dart';
import '../../core/sdk.dart';
import '../widgets/page_header.dart';
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
  final _url = TextEditingController();
  final _model = TextEditingController();
  List<String> _models = const [];
  bool _loadingModels = false;
  bool _saving = false;
  String? _aiMsg;
  final Map<String, TextEditingController> _tpl = {};

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _syncAi();
    Agents.instance.addListener(_changed);
  }

  @override
  void dispose() {
    Agents.instance.removeListener(_changed);
    _key.dispose();
    _url.dispose();
    _model.dispose();
    for (final c in _tpl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _syncAi() {
    _url.text = Ai.instance.baseUrl;
    _model.text = Ai.instance.model;
    _key.clear();
    _models = const [];
    _aiMsg = null;
  }

  Future<void> _loadVersion() async {
    final v = await Sdk.instance.version();
    if (mounted) setState(() => _version = v);
  }

  Future<void> _pickFlutter() async {
    final f = await openFile(confirmButtonText: 'Use this Flutter');
    if (f == null) return;
    if (!(f.path.endsWith('flutter') || f.path.endsWith('flutter.bat'))) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("Pick the flutter file inside your Flutter SDK's bin folder.")));
      }
      return;
    }
    await Sdk.instance.setFlutterBin(f.path);
    setState(() => _version = null);
    _loadVersion();
    Devices.instance.refresh();
    Agents.instance.detect();
  }

  Future<void> _setTheme(ThemeMode m) async {
    widget.themeMode.value = m;
    (await SharedPreferences.getInstance()).setString('theme', m.name);
    setState(() {});
  }

  Future<void> _switchProvider(Provider p) async {
    await Ai.instance.use(p);
    setState(_syncAi);
  }

  Future<void> _loadModels() async {
    final p = Ai.instance.provider;
    setState(() {
      _loadingModels = true;
      _aiMsg = null;
    });
    try {
      // A key typed but not saved yet still counts for listing.
      if (_key.text.trim().isNotEmpty) await Ai.instance.setKey(p, _key.text);
      if (p.hasUrl) await Ai.instance.use(p, url: _url.text.trim());
      final list = await Ai.instance.listModels(p);
      setState(() {
        _models = list;
        _aiMsg = list.isEmpty
            ? (p == Provider.ollama ? 'No models yet. Run: ollama pull qwen2.5-coder' : 'No models found.')
            : null;
      });
    } catch (e) {
      setState(() => _aiMsg = '$e');
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _saveAi() async {
    final p = Ai.instance.provider;
    setState(() {
      _saving = true;
      _aiMsg = null;
    });
    try {
      if (_key.text.trim().isNotEmpty) await Ai.instance.setKey(p, _key.text);
      await Ai.instance.use(p, model: _model.text.trim(), url: p.hasUrl ? _url.text.trim() : null);
      _key.clear();
      _aiMsg = Ai.instance.connected
          ? 'Saved. Ask AI uses ${p.label} · ${Ai.instance.model}.'
          : 'Pick a model${p.needsKey ? ' and add a key' : ''}.';
    } catch (e) {
      _aiMsg = '$e';
    }
    if (mounted) setState(() => _saving = false);
  }

  InputDecoration _field(C c, String hint) => InputDecoration(
    isDense: true,
    hintText: hint,
    hintStyle: TextStyle(color: c.muted),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(5),
      borderSide: BorderSide(color: c.line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(5),
      borderSide: BorderSide(color: c.line),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final v = _version;
    final p = Ai.instance.provider;
    Widget row(String label, Widget value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 160,
            child: Text(label, style: TextStyle(fontSize: 13, color: c.muted)),
          ),
          Expanded(child: value),
        ],
      ),
    );
    Widget section(String title, String? sub, List<Widget> children) => Container(
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.panel,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.text),
          ),
          if (sub != null) ...[const SizedBox(height: 4), Text(sub, style: TextStyle(fontSize: 12.5, color: c.muted))],
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const PageHeader(title: 'Settings'),
        section('Flutter SDK', null, [
          row(
            'Flutter command',
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    Sdk.instance.flutterBin ?? 'Not found',
                    style: mono.copyWith(color: Sdk.instance.ready ? c.text : c.bad),
                  ),
                ),
                OutlinedButton(onPressed: _pickFlutter, child: const Text('Change')),
              ],
            ),
          ),
          row('Version', Text(v == null ? '…' : '${v['frameworkVersion']} · ${v['channel']}', style: TextStyle(color: c.text))),
          row('Dart', Text(v == null ? '…' : '${v['dartSdkVersion']}', style: TextStyle(color: c.text))),
          row(
            'This computer',
            Text('${Platform.operatingSystem} ${Platform.operatingSystemVersion}', style: TextStyle(color: c.text)),
          ),
        ]),

        section(
          'AI model',
          "Ask AI sends the end of the log, and the project files it decides to read, to the model you pick. It can't read .env files or signing keys. With Ollama, nothing leaves this computer.",
          [
            row(
              'Provider',
              DropdownButtonHideUnderline(
                child: DropdownButton<Provider>(
                  value: p,
                  isDense: true,
                  dropdownColor: c.panel,
                  style: TextStyle(fontSize: 13, color: c.text),
                  items: [for (final x in Provider.values) DropdownMenuItem(value: x, child: Text(x.label))],
                  onChanged: (x) => x == null ? null : _switchProvider(x),
                ),
              ),
            ),
            if (p.needsKey)
              row(
                'API key',
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _key,
                        obscureText: true,
                        style: mono.copyWith(color: c.text),
                        decoration: _field(c, Ai.instance.hasKey(p) ? 'Saved in the keychain. Type to replace.' : p.keyHint),
                      ),
                    ),
                    if (Ai.instance.hasKey(p)) ...[
                      const SizedBox(width: 6),
                      TextButton(
                        onPressed: () async {
                          await Ai.instance.setKey(p, null);
                          setState(() => _aiMsg = 'Key removed.');
                        },
                        child: Text('Remove', style: TextStyle(color: c.bad)),
                      ),
                    ],
                  ],
                ),
              ),
            if (p.hasUrl)
              row(
                'Address',
                TextField(
                  controller: _url,
                  style: mono.copyWith(color: c.text),
                  decoration: _field(c, p.defaultUrl),
                ),
              ),
            row(
              'Model',
              Row(
                children: [
                  Expanded(
                    child: _models.isEmpty
                        ? TextField(
                            controller: _model,
                            style: mono.copyWith(color: c.text),
                            decoration: _field(c, 'Load the list, or type a model id'),
                          )
                        : DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              isExpanded: true,
                              isDense: true,
                              value: _models.contains(_model.text) ? _model.text : null,
                              hint: Text('Pick a model (${_models.length})', style: TextStyle(color: c.muted, fontSize: 13)),
                              dropdownColor: c.panel,
                              style: mono.copyWith(color: c.text),
                              items: [
                                for (final m in _models)
                                  DropdownMenuItem(
                                    value: m,
                                    child: Text(m, overflow: TextOverflow.ellipsis),
                                  ),
                              ],
                              onChanged: (m) => setState(() => _model.text = m ?? ''),
                            ),
                          ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _loadingModels ? null : _loadModels,
                    child: Text(_loadingModels ? 'Loading…' : 'Load models'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 160, top: 6),
              child: Row(
                children: [
                  FilledButton(onPressed: _saving ? null : _saveAi, child: Text(_saving ? 'Saving…' : 'Save')),
                  const SizedBox(width: 12),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(color: Ai.instance.connected ? c.good : c.muted, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      Ai.instance.connected ? 'Using ${Ai.instance.provider.label} · ${Ai.instance.model}' : 'Not connected',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: c.muted),
                    ),
                  ),
                ],
              ),
            ),
            if (_aiMsg != null)
              Padding(
                padding: const EdgeInsets.only(left: 160, top: 8),
                child: Text(_aiMsg!, style: TextStyle(fontSize: 12, color: c.text)),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 160, top: 6),
              child: Text(
                p == Provider.ollama
                    ? 'Free and private: the model runs on this computer. Install from ollama.com, then e.g. ollama pull qwen2.5-coder.'
                    : p.needsKey
                    ? 'Get a key: ${p.keyUrl}. Keys stay in your keychain and only go to ${p.label}.'
                    : 'Any server that speaks the OpenAI chat API.',
                style: TextStyle(fontSize: 11.5, color: c.muted.withValues(alpha: 0.85)),
              ),
            ),
          ],
        ),

        section(
          'Coding agents',
          'Fix with an agent hands it the error and lets it edit your code, then shows what changed with an undo. Deckhand finds the ones installed.',
          [
            for (final a in agents) _agentRow(c, a),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: Agents.instance.detect,
                icon: const Icon(Icons.refresh_rounded, size: 15),
                label: const Text('Look again'),
              ),
            ),
          ],
        ),

        section('Appearance', null, [
          const SizedBox(height: 4),
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
      ],
    );
  }

  Widget _agentRow(C c, Agent a) {
    final installed = Agents.instance.found.containsKey(a.id);
    final on = Agents.instance.chosen == a.id && installed;
    final ctrl = _tpl.putIfAbsent(a.id, () => TextEditingController(text: Agents.instance.template(a)));
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Radio<String>(
                value: a.id,
                groupValue: Agents.instance.chosen,
                onChanged: installed ? (v) => Agents.instance.choose(a.id) : null,
                visualDensity: VisualDensity.compact,
              ),
              Text(
                a.name,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: installed ? c.text : c.muted),
              ),
              if (a.openSource) ...[
                const SizedBox(width: 8),
                Text('open source', style: TextStyle(fontSize: 11, color: c.muted)),
              ],
              const Spacer(),
              Text(
                installed ? (on ? 'In use' : 'Installed') : 'Not installed · ${a.site}',
                style: TextStyle(fontSize: 12, color: installed ? (on ? c.good : c.muted) : c.muted.withValues(alpha: 0.7)),
              ),
            ],
          ),
          if (installed)
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: ctrl,
                      style: mono.copyWith(fontSize: 12, color: c.text),
                      decoration: _field(c, a.defaultTemplate),
                      onSubmitted: (t) => Agents.instance.setTemplate(a, t),
                    ),
                  ),
                  const SizedBox(width: 6),
                  TextButton(
                    onPressed: () {
                      Agents.instance.setTemplate(a, ctrl.text);
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text('${a.name} command saved'), duration: const Duration(seconds: 1)));
                    },
                    child: const Text('Save'),
                  ),
                  TextButton(
                    onPressed: () {
                      ctrl.text = a.defaultTemplate;
                      Agents.instance.setTemplate(a, a.defaultTemplate);
                    },
                    child: Text('Reset', style: TextStyle(color: c.muted)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
