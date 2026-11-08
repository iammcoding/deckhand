import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/projects.dart';
import '../../core/sdk.dart';
import '../widgets/page_header.dart';
import '../theme.dart';

class _Check {
  final String status; // ok, warn, bad
  final String title;
  final List<String> details;
  _Check(this.status, this.title, this.details);
}

/// `flutter doctor -v` as a checklist: what's fine, what needs a look, and
/// the tool's own lines for each.
class DoctorPage extends StatefulWidget {
  const DoctorPage({super.key});

  @override
  State<DoctorPage> createState() => _DoctorPageState();
}

class _DoctorPageState extends State<DoctorPage> {
  List<_Check> _checks = const [];
  bool _running = false;
  String? _error;
  final Set<int> _open = {};

  static List<_Check> _parse(String out) {
    final checks = <_Check>[];
    final head = RegExp(r'^\[(.)\]\s+(.+)$');
    for (final raw in const LineSplitter().convert(out)) {
      final m = head.firstMatch(raw.trimRight());
      if (m != null) {
        final mark = m.group(1)!;
        final status = mark == '✓' || mark == '√' ? 'ok' : (mark == '!' ? 'warn' : 'bad');
        checks.add(_Check(status, m.group(2)!, []));
      } else if (checks.isNotEmpty && raw.trim().isNotEmpty) {
        checks.last.details.add(raw.trim());
      }
    }
    return checks;
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final r = await Sdk.instance.run(
        ['doctor', '-v'],
        cwd: Projects.instance.current?.path,
        timeout: const Duration(minutes: 3),
      );
      if (!mounted) return;
      final checks = _parse('${r.stdout}');
      setState(() {
        _checks = checks;
        _open
          ..clear()
          ..addAll([
            for (var i = 0; i < checks.length; i++)
              if (checks[i].status != 'ok') i,
          ]);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  void initState() {
    super.initState();
    if (Sdk.instance.ready) _run();
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final issues = _checks.where((x) => x.status != 'ok').length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeader(
          title: 'Doctor',
          subtitle: _checks.isEmpty
              ? 'Checks your Flutter setup'
              : issues == 0
              ? 'Everything looks good'
              : '$issues ${issues == 1 ? 'thing needs' : 'things need'} a look',
          actions: [
            OutlinedButton.icon(
              onPressed: _running ? null : _run,
              icon: _running
                  ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: c.muted))
                  : const Icon(Icons.refresh_rounded, size: 16),
              label: Text(_running ? 'Checking…' : 'Run again'),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(_error!, style: TextStyle(color: c.bad)),
          ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            itemCount: _checks.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final x = _checks[i];
              final (icon, color) = switch (x.status) {
                'ok' => (Icons.check_circle_rounded, c.good),
                'warn' => (Icons.error_rounded, c.warn),
                _ => (Icons.cancel_rounded, c.bad),
              };
              final open = _open.contains(i);
              return Container(
                decoration: BoxDecoration(
                  color: c.panel,
                  border: Border.all(color: c.line),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => setState(() => open ? _open.remove(i) : _open.add(i)),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Icon(icon, size: 19, color: color),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                x.title,
                                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.text),
                              ),
                            ),
                            Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: c.muted),
                          ],
                        ),
                      ),
                    ),
                    if (open && x.details.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(45, 0, 14, 14),
                        child: SelectionArea(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final d in x.details)
                                Text(
                                  d,
                                  style: mono.copyWith(
                                    fontSize: 12,
                                    color: d.startsWith('✗') || d.startsWith('X ')
                                        ? c.bad
                                        : d.startsWith('!')
                                        ? c.warn
                                        : c.muted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
