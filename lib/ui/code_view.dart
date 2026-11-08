import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/bench.dart';
import '../core/projects.dart';
import '../core/sdk.dart';
import 'theme.dart';

/// A file, read-only, with line numbers and colours. Files are cached by
/// modified time, so going back to a tab is instant.
class CodeView extends StatefulWidget {
  final String path;
  const CodeView({super.key, required this.path});

  @override
  State<CodeView> createState() => _CodeViewState();
}

class _Loaded {
  final DateTime modified;
  final List<String>? lines;
  final String? why; // why it isn't shown as text
  final bool image;
  final int longest;
  const _Loaded(this.modified, {this.lines, this.why, this.image = false, this.longest = 0});
}

class _CodeViewState extends State<CodeView> {
  static final Map<String, _Loaded> _cache = {};
  static const _lineH = 19.0;
  static const _charW = 7.55; // Menlo at 12.5
  static const _images = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};

  _Loaded? _file;
  final _v = ScrollController();
  final _h = ScrollController();
  int? _mark;

  @override
  void initState() {
    super.initState();
    _load();
    Bench.instance.addListener(_maybeReveal);
  }

  @override
  void didUpdateWidget(CodeView old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _mark = null;
      _load();
    }
  }

  @override
  void dispose() {
    Bench.instance.removeListener(_maybeReveal);
    _v.dispose();
    _h.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final path = widget.path;
    final f = File(path);
    try {
      final stat = await f.stat();
      final hit = _cache[path];
      if (hit != null && hit.modified == stat.modified) {
        setState(() => _file = hit);
        _maybeReveal();
        return;
      }
      _Loaded loaded;
      if (_images.contains(p.extension(path).toLowerCase())) {
        loaded = _Loaded(stat.modified, image: true);
      } else if (stat.size > 2 * 1024 * 1024) {
        loaded = _Loaded(
          stat.modified,
          why: 'This file is ${(stat.size / 1048576).toStringAsFixed(1)} MB, too big to show here.',
        );
      } else {
        final bytes = await f.readAsBytes();
        final head = bytes.length > 8000 ? bytes.sublist(0, 8000) : bytes;
        if (head.contains(0)) {
          loaded = _Loaded(stat.modified, why: 'This is a binary file.');
        } else {
          final lines = const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true));
          var longest = 0;
          for (final l in lines) {
            if (l.length > longest) longest = l.length;
          }
          loaded = _Loaded(stat.modified, lines: lines.isEmpty ? [''] : lines, longest: longest);
        }
      }
      _cache[path] = loaded;
      if (_cache.length > 40) _cache.remove(_cache.keys.first);
      if (!mounted || widget.path != path) return;
      setState(() => _file = loaded);
      _maybeReveal();
    } catch (e) {
      if (mounted) setState(() => _file = _Loaded(DateTime(0), why: "Couldn't open this file: $e"));
    }
  }

  /// A problem was clicked: scroll to its line and mark it.
  void _maybeReveal() {
    final r = Bench.instance.reveal;
    if (r == null || r.path != widget.path || _file?.lines == null) return;
    Bench.instance.reveal = null;
    setState(() => _mark = r.line);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_v.hasClients) return;
      final y = ((r.line - 1) * _lineH - _v.position.viewportDimension / 3).clamp(0.0, _v.position.maxScrollExtent);
      _v.jumpTo(y);
    });
  }

  void _openOutside() async {
    // VS Code if it's installed (at the line), otherwise the default app.
    final at = _mark != null ? '${widget.path}:$_mark' : widget.path;
    try {
      final r = await Process.run('code', ['--goto', at], environment: Sdk.instance.env, runInShell: true);
      if (r.exitCode == 0) return;
    } catch (_) {}
    if (Platform.isMacOS) {
      Process.run('open', [widget.path]);
    } else if (Platform.isWindows) {
      Process.run('cmd', ['/c', 'start', '', widget.path]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    final root = Projects.instance.current?.path;
    final rel = root != null && p.isWithin(root, widget.path) ? p.relative(widget.path, from: root) : widget.path;
    final f = _file;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Breadcrumb, like an editor.
        Container(
          height: 26,
          padding: const EdgeInsets.only(left: 14, right: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  p.split(rel).join('  ›  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: c.muted),
                ),
              ),
              TextButton.icon(
                onPressed: _openOutside,
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: c.muted),
                icon: const Icon(Icons.edit_outlined, size: 13),
                label: const Text('Edit', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        Expanded(
          child: f == null
              ? const SizedBox.shrink()
              : f.image
              ? Center(child: InteractiveViewer(child: Image.file(File(widget.path))))
              : f.lines == null
              ? Center(
                  child: Text(f.why ?? '', style: TextStyle(color: c.muted, fontSize: 13)),
                )
              : _code(c, f),
        ),
      ],
    );
  }

  Widget _code(C c, _Loaded f) {
    final lines = f.lines!;
    final gutter = 22.0 + '${lines.length}'.length * _charW;
    final lang = Highlighter.forPath(widget.path);
    final colors = SyntaxColors.of(context);
    // Block comments run across lines, so work out where each line starts.
    final inBlock = lang.blockStates(lines);
    return LayoutBuilder(
      builder: (context, box) {
        final width = (gutter + 24 + f.longest * _charW).clamp(box.maxWidth, double.infinity);
        // The vertical bar sits at the window's edge, not the end of the
        // longest line.
        return Scrollbar(
          controller: _v,
          notificationPredicate: (n) => n.depth == 1,
          child: Scrollbar(
            controller: _h,
            notificationPredicate: (n) => n.depth == 0,
            child: SingleChildScrollView(
              controller: _h,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                child: SelectionArea(
                  child: ListView.builder(
                    controller: _v,
                    itemExtent: _lineH,
                    padding: const EdgeInsets.only(bottom: 40),
                    itemCount: lines.length,
                    itemBuilder: (_, i) {
                      final marked = _mark == i + 1;
                      return Container(
                        color: marked ? c.warn.withValues(alpha: 0.14) : null,
                        child: Row(
                          children: [
                            SizedBox(
                              width: gutter,
                              child: SelectionContainer.disabled(
                                child: Text(
                                  '${i + 1}',
                                  textAlign: TextAlign.right,
                                  style: mono.copyWith(height: 1.0, color: marked ? c.text : c.muted.withValues(alpha: 0.55)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 18),
                            Expanded(
                              child: Text.rich(
                                TextSpan(children: lang.spans(lines[i], colors, startInBlock: inBlock[i])),
                                maxLines: 1,
                                softWrap: false,
                                style: mono.copyWith(height: 1.0, color: c.text),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Code colours, warm to match the app.
class SyntaxColors {
  final Color keyword, string, comment, number, type, annotation;
  const SyntaxColors(this.keyword, this.string, this.comment, this.number, this.type, this.annotation);

  static const _dark = SyntaxColors(
    Color(0xFFE8A55C), // keyword: the accent, softened
    Color(0xFFA9C98A), // string
    Color(0xFF6E6A65), // comment
    Color(0xFFDB8B6E), // number
    Color(0xFF8CC7C0), // type
    Color(0xFFC9A0DC), // annotation
  );
  static const _light = SyntaxColors(
    Color(0xFFB4530A),
    Color(0xFF4D7A2A),
    Color(0xFF928D86),
    Color(0xFFB4462B),
    Color(0xFF1F7A73),
    Color(0xFF8A4FA8),
  );

  static SyntaxColors of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? _dark : _light;
}

/// A small tokenizer: comments, strings, numbers, keywords, type names and
/// annotations. Enough to read code comfortably, not a full parser.
class Highlighter {
  final Set<String> keywords;
  final String? line; // line comment marker
  final bool block; // /* */ comments
  final bool types; // Capitalised words are types
  const Highlighter(this.keywords, {this.line = '//', this.block = true, this.types = true});

  static const _dart = {
    'abstract',
    'as',
    'assert',
    'async',
    'await',
    'base',
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
    'Function',
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
    'sealed',
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
    'when',
    'while',
    'with',
    'yield',
    'int',
    'double',
    'num',
    'bool',
    'String',
  };
  static const _kotlin = {
    'package',
    'import',
    'class',
    'interface',
    'object',
    'fun',
    'val',
    'var',
    'if',
    'else',
    'when',
    'for',
    'while',
    'return',
    'true',
    'false',
    'null',
    'override',
    'private',
    'public',
    'internal',
    'protected',
    'companion',
    'data',
    'sealed',
    'try',
    'catch',
    'finally',
    'throw',
    'is',
    'as',
    'in',
    'this',
    'super',
    'lateinit',
    'suspend',
    'new',
    'static',
    'void',
    'final',
    'extends',
    'implements',
    'plugins',
    'id',
    'apply',
  };
  static const _swift = {
    'import',
    'class',
    'struct',
    'enum',
    'protocol',
    'extension',
    'func',
    'let',
    'var',
    'if',
    'else',
    'guard',
    'switch',
    'case',
    'default',
    'for',
    'in',
    'while',
    'return',
    'true',
    'false',
    'nil',
    'self',
    'super',
    'override',
    'private',
    'public',
    'internal',
    'static',
    'init',
    'try',
    'catch',
    'throw',
    'throws',
    'async',
    'await',
    'some',
    'any',
    'weak',
    '@objc',
    'final',
    'lazy',
  };
  static const _yaml = {'true', 'false', 'null', 'yes', 'no'};

  static Highlighter forPath(String path) => switch (p.extension(path).toLowerCase()) {
    '.dart' => const Highlighter(_dart),
    '.kt' || '.kts' || '.java' || '.gradle' => const Highlighter(_kotlin),
    '.swift' || '.m' || '.h' || '.cc' || '.cpp' || '.c' => const Highlighter(_swift),
    '.js' || '.ts' || '.json' => const Highlighter(_dart, types: false),
    '.yaml' || '.yml' || '.sh' || '.properties' || '.toml' => const Highlighter(_yaml, line: '#', block: false, types: false),
    _ => const Highlighter({}, line: null, block: false, types: false),
  };

  /// For each line, whether it starts inside a /* */ comment.
  List<bool> blockStates(List<String> lines) {
    final out = List<bool>.filled(lines.length, false);
    if (!block) return out;
    var inside = false;
    for (var i = 0; i < lines.length; i++) {
      out[i] = inside;
      final l = lines[i];
      var j = 0;
      while (j < l.length) {
        if (inside) {
          final e = l.indexOf('*/', j);
          if (e < 0) break;
          inside = false;
          j = e + 2;
        } else {
          final s = l.indexOf('/*', j);
          final lc = line == null ? -1 : l.indexOf(line!, j);
          if (s < 0 || (lc >= 0 && lc < s)) break;
          inside = true;
          j = s + 2;
        }
      }
    }
    return out;
  }

  static final _word = RegExp(r'[A-Za-z_$@][A-Za-z0-9_$]*');
  static final _num = RegExp(r'(0x[0-9a-fA-F]+|\d+(\.\d+)?([eE][+-]?\d+)?)');

  List<TextSpan> spans(String text, SyntaxColors s, {bool startInBlock = false}) {
    final out = <TextSpan>[];
    final buf = StringBuffer();
    void flush() {
      if (buf.isNotEmpty) {
        out.add(TextSpan(text: buf.toString()));
        buf.clear();
      }
    }

    void add(String t, Color color) {
      flush();
      out.add(
        TextSpan(
          text: t,
          style: TextStyle(color: color),
        ),
      );
    }

    var i = 0;
    if (startInBlock) {
      final e = text.indexOf('*/');
      if (e < 0)
        return [
          TextSpan(
            text: text,
            style: TextStyle(color: s.comment),
          ),
        ];
      add(text.substring(0, e + 2), s.comment);
      i = e + 2;
    }
    while (i < text.length) {
      final rest = text.substring(i);
      if (line != null && rest.startsWith(line!)) {
        add(rest, s.comment);
        break;
      }
      if (block && rest.startsWith('/*')) {
        final e = text.indexOf('*/', i + 2);
        final end = e < 0 ? text.length : e + 2;
        add(text.substring(i, end), s.comment);
        i = end;
        continue;
      }
      final ch = text[i];
      if (ch == '"' || ch == "'" || ch == '`') {
        var j = i + 1;
        while (j < text.length && text[j] != ch) {
          if (text[j] == r'\') j++;
          j++;
        }
        final end = (j + 1).clamp(0, text.length);
        add(text.substring(i, end), s.string);
        i = end;
        continue;
      }
      final w = _word.matchAsPrefix(text, i);
      if (w != null) {
        final t = w.group(0)!;
        if (t.startsWith('@')) {
          add(t, s.annotation);
        } else if (keywords.contains(t)) {
          add(t, s.keyword);
        } else if (types && t[0].toUpperCase() == t[0] && t[0] != '_' && t[0] != r'$') {
          add(t, s.type);
        } else {
          buf.write(t);
        }
        i += t.length;
        continue;
      }
      final n = _num.matchAsPrefix(text, i);
      if (n != null && (i == 0 || !RegExp(r'[A-Za-z_]').hasMatch(text[i - 1]))) {
        add(n.group(0)!, s.number);
        i += n.group(0)!.length;
        continue;
      }
      buf.write(ch);
      i++;
    }
    flush();
    return out;
  }
}
