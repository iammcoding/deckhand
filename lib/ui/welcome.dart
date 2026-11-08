import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/ai.dart';
import '../core/devices.dart';
import '../core/projects.dart';
import '../core/sdk.dart';
import 'theme.dart';

/// First launch: the deck on the left, and what Deckhand needs on the right,
/// ticked off as it finds it. Ends by opening a project.
class Welcome extends StatefulWidget {
  final VoidCallback onDone;
  final VoidCallback onOpenSettings;
  const Welcome({super.key, required this.onDone, required this.onOpenSettings});

  @override
  State<Welcome> createState() => _WelcomeState();
}

class _WelcomeState extends State<Welcome> {
  String? _version;

  @override
  void initState() {
    super.initState();
    Devices.instance.addListener(_changed);
    Sdk.instance.version().then((v) {
      if (mounted && v != null) setState(() => _version = '${v['frameworkVersion']} · ${v['channel']}');
    });
  }

  @override
  void dispose() {
    Devices.instance.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _locateFlutter() async {
    final f = await openFile(confirmButtonText: 'Use this Flutter');
    if (f == null) return;
    await Sdk.instance.setFlutterBin(f.path);
    final v = await Sdk.instance.version();
    Devices.instance.refresh();
    if (mounted) setState(() => _version = v == null ? null : '${v['frameworkVersion']} · ${v['channel']}');
  }

  Future<void> _open() async {
    final dir = await getDirectoryPath(confirmButtonText: 'Open project');
    if (dir == null || !mounted) return;
    final err = await Projects.instance.open(dir);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    } else {
      widget.onDone();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final flutterOk = Sdk.instance.ready && _version != null;
    final devices = Devices.instance.list;
    final recent = Projects.instance.recent;
    return Scaffold(
      body: Row(
        children: [
          // The deck, with the name over it.
          Expanded(
            flex: 5,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset('assets/welcome/deck.jpg', fit: BoxFit.cover, alignment: const Alignment(0, 0.2)),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.35),
                        Colors.black.withValues(alpha: 0.05),
                        Colors.black.withValues(alpha: 0.75),
                      ],
                      stops: const [0, 0.45, 1],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(40, 70, 40, 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.anchor_rounded, size: 20, color: Colors.white),
                          SizedBox(width: 9),
                          Text(
                            'Deckhand',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                          ),
                        ],
                      ),
                      const Spacer(),
                      const Text(
                        'Run, build and ship\nFlutter apps from one window.',
                        style: TextStyle(
                          fontSize: 28,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Devices, hot reload, builds and your setup, with fixes for the errors you hit.',
                        style: TextStyle(fontSize: 14, height: 1.4, color: Colors.white.withValues(alpha: 0.75)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // What it needs.
          Expanded(
            flex: 4,
            child: Container(
              color: c.bg,
              padding: const EdgeInsets.fromLTRB(44, 70, 44, 36),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Get set up',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: c.text, letterSpacing: -0.3),
                  ),
                  const SizedBox(height: 6),
                  Text('Deckhand checks these for you.', style: TextStyle(fontSize: 13.5, color: c.muted)),
                  const SizedBox(height: 26),
                  _step(
                    c,
                    done: flutterOk,
                    title: 'Flutter',
                    detail: flutterOk ? _version! : (Sdk.instance.ready ? 'Checking…' : "Not found on this computer's PATH"),
                    action: flutterOk ? null : TextButton(onPressed: _locateFlutter, child: const Text('Locate')),
                  ),
                  _step(
                    c,
                    done: devices.isNotEmpty,
                    title: 'A device',
                    detail: devices.isNotEmpty
                        ? devices.map((d) => d.name).take(3).join(', ')
                        : (Devices.instance.loading ? 'Looking…' : 'Plug in a phone or start a simulator'),
                    action: devices.isNotEmpty
                        ? null
                        : TextButton(onPressed: Devices.instance.refresh, child: const Text('Look again')),
                  ),
                  _step(
                    c,
                    done: Ai.instance.connected,
                    optional: true,
                    title: 'AI for errors',
                    detail: Ai.instance.connected ? 'Connected' : 'Optional. Reads a failing log and suggests the fix',
                    action: Ai.instance.connected
                        ? null
                        : TextButton(onPressed: widget.onOpenSettings, child: const Text('Connect')),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    height: 40,
                    child: FilledButton.icon(
                      onPressed: Sdk.instance.ready ? _open : null,
                      icon: const Icon(Icons.folder_open_rounded, size: 17),
                      label: const Text('Open a Flutter project'),
                    ),
                  ),
                  if (recent.isNotEmpty) ...[
                    const SizedBox(height: 26),
                    Text(
                      'RECENT',
                      style: TextStyle(fontSize: 10.5, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: c.muted),
                    ),
                    const SizedBox(height: 6),
                    for (final r in recent.take(4))
                      InkWell(
                        onTap: () async {
                          await Projects.instance.open(r.path);
                          widget.onDone();
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Row(
                            children: [
                              Text(
                                r.name,
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  r.path,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: mono.copyWith(fontSize: 11, color: c.muted),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                  const Spacer(),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: widget.onDone,
                      child: Text('Skip for now', style: TextStyle(color: c.muted)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _step(C c, {required bool done, required String title, required String detail, Widget? action, bool optional = false}) =>
      Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.line)),
        ),
        child: Row(
          children: [
            Icon(
              done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
              size: 18,
              color: done ? c.good : (optional ? c.muted : c.warn),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.text),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.muted),
                  ),
                ],
              ),
            ),
            ?action,
          ],
        ),
      );
}

/// While Deckhand finds Flutter and reads your projects: the mark, centred.
class Splash extends StatelessWidget {
  const Splash({super.key});

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.anchor_rounded, size: 34, color: c.text),
            const SizedBox(height: 12),
            Text(
              'Deckhand',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.text),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: 120,
              child: LinearProgressIndicator(minHeight: 2, color: c.accent, backgroundColor: c.line),
            ),
          ],
        ),
      ),
    );
  }
}
