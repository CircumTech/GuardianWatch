// ─── lib/widgets/section_header.dart ─────────────────────────────────────────

import 'package:flutter/material.dart';

/// A section title with optional trailing widget.
///
/// Marked as a `header` for accessibility navigation.
class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  /// Horizontal padding. Defaults to 16.
  final double horizontalPadding;

  const SectionHeader(
    this.title, {
    super.key,
    this.trailing,
    this.horizontalPadding = 16,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 8),
      child: Semantics(
        header: true,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}
