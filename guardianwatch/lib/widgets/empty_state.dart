// ─── lib/widgets/empty_state.dart ─────────────────────────────────────────────

import 'package:flutter/material.dart';

/// A centered empty-state view with icon, title, subtitle, and optional action.
///
/// Adapts to the current theme and stays legible on tablets via a max
/// width constraint.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;

  /// Optional supporting text. If null, only the title is shown.
  final String? subtitle;

  /// Optional action widget (usually a button).
  final Widget? action;

  /// Optional maximum width for the content column.
  final double maxWidth;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
    this.maxWidth = 400,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Semantics(
      container: true,
      label: _semanticLabel,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 64,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.65),
                      height: 1.4,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                if (action != null) ...[const SizedBox(height: 20), action!],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _semanticLabel {
    if (subtitle != null && subtitle!.isNotEmpty) {
      return '$title. $subtitle';
    }
    return title;
  }
}
