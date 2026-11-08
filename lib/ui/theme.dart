import 'package:flutter/material.dart';

/// Deckhand's look: a working tool, quiet and dense. Flat panels, thin rules,
/// one accent. Dark and light.
class C {
  final Color bg, panel, raised, line, text, muted, accent, good, warn, bad;
  const C({
    required this.bg,
    required this.panel,
    required this.raised,
    required this.line,
    required this.text,
    required this.muted,
    required this.accent,
    required this.good,
    required this.warn,
    required this.bad,
  });

  static const dark = C(
    bg: Color(0xFF0E1013),
    panel: Color(0xFF15181D),
    raised: Color(0xFF1C2026),
    line: Color(0xFF262B33),
    text: Color(0xFFE7E9ED),
    muted: Color(0xFF8B929E),
    accent: Color(0xFF3B9EFF),
    good: Color(0xFF3FB950),
    warn: Color(0xFFD29922),
    bad: Color(0xFFF85149),
  );

  static const light = C(
    bg: Color(0xFFF6F7F9),
    panel: Color(0xFFFFFFFF),
    raised: Color(0xFFF0F2F5),
    line: Color(0xFFE1E4E8),
    text: Color(0xFF1F2328),
    muted: Color(0xFF656D76),
    accent: Color(0xFF0969DA),
    good: Color(0xFF1A7F37),
    warn: Color(0xFF9A6700),
    bad: Color(0xFFCF222E),
  );

  static C of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? dark : light;
}

const mono = TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['Consolas', 'DejaVu Sans Mono', 'monospace'], fontSize: 12.5, height: 1.45);

ThemeData buildTheme(Brightness b) {
  final c = b == Brightness.dark ? C.dark : C.light;
  final base = ThemeData(brightness: b, useMaterial3: true, colorSchemeSeed: c.accent);
  return base.copyWith(
    scaffoldBackgroundColor: c.bg,
    dividerColor: c.line,
    textTheme: base.textTheme.apply(bodyColor: c.text, displayColor: c.text),
    iconTheme: IconThemeData(color: c.muted, size: 18),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(6), border: Border.all(color: c.line)),
      textStyle: TextStyle(color: c.text, fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.text,
        side: BorderSide(color: c.line),
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
  );
}
