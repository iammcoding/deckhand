import 'package:flutter/material.dart';

import '../theme.dart';

/// A page's header: its title, a line under it, and actions on the right.
class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  const PageHeader({super.key, required this.title, this.subtitle, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final c = C.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: c.text),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!, style: TextStyle(fontSize: 13, color: c.muted)),
                ],
              ],
            ),
          ),
          ...[for (final a in actions) Padding(padding: const EdgeInsets.only(left: 8), child: a)],
        ],
      ),
    );
  }
}
