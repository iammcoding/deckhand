import 'package:flutter/material.dart';

import '../theme.dart';

/// The heading at the top of a sidebar section.
class SideTitle extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  const SideTitle(this.title, {super.key, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return Container(
      height: 30,
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.text),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// A small label above a group in a side panel.
class SideLabel extends StatelessWidget {
  final String text;
  const SideLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c.muted),
      ),
    );
  }
}

/// One clickable row in a side panel: icon, label, and something on the right.
class SideRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? detail;
  final bool selected;
  final Widget? trailing;
  final Color? iconColor;
  final VoidCallback? onTap;
  const SideRow({
    super.key,
    required this.icon,
    required this.label,
    this.detail,
    this.selected = false,
    this.trailing,
    this.iconColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null && !selected ? 0.5 : 1,
        child: Container(
          height: 28,
          color: selected ? c.raised : null,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(icon, size: 15, color: iconColor ?? (selected ? c.accent : c.muted)),
              const SizedBox(width: 9),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: label,
                        style: TextStyle(color: c.text),
                      ),
                      if (detail != null)
                        TextSpan(
                          text: '  $detail',
                          style: TextStyle(color: c.muted, fontSize: 11.5),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

/// A dot for state: running, starting, stopped.
Widget stateDot(Color color) => Container(
  width: 7,
  height: 7,
  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
);
