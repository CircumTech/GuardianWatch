// ─── lib/widgets/insight_card.dart ───────────────────────────────────────────

import 'package:flutter/material.dart';

import '../models/insight.dart';

/// A card that renders a single [Insight].
///
/// Premium insights the user has not unlocked render with a lock overlay.
///
/// Severity labels are user-facing and must avoid clinical / alarmist
/// language. The raw `InsightSeverity` enum names are never displayed.
class InsightCard extends StatelessWidget {
  final Insight insight;
  final bool isPremium;
  final VoidCallback? onTap;

  const InsightCard({
    super.key,
    required this.insight,
    required this.isPremium,
    this.onTap,
  });

  bool get _locked => insight.isPremium && !isPremium;

  Color _severityColor(ColorScheme colorScheme) {
    switch (insight.severity) {
      case InsightSeverity.normal:
        // Neutral, not the brand accent — the accent is reserved for
        // call-to-action surfaces.
        return colorScheme.onSurface.withValues(alpha: 0.55);
      case InsightSeverity.caution:
        return Colors.orange;
      case InsightSeverity.warning:
        return Colors.deepOrange;
      case InsightSeverity.critical:
        return colorScheme.error;
    }
  }

  IconData _severityIcon() {
    switch (insight.severity) {
      case InsightSeverity.normal:
        return Icons.check_circle_outline;
      case InsightSeverity.caution:
        return Icons.warning_amber_rounded;
      case InsightSeverity.warning:
        return Icons.error_outline;
      case InsightSeverity.critical:
        return Icons.priority_high_rounded;
    }
  }

  /// User-facing severity label.
  ///
  /// Mirrors `InsightsScreen._severityLabel` so both surfaces stay in sync.
  /// Avoids raw enum names and clinical terminology.
  String _severityLabel() {
    switch (insight.severity) {
      case InsightSeverity.normal:
        return 'Normal';
      case InsightSeverity.caution:
        return 'Notice';
      case InsightSeverity.warning:
        return 'Attention';
      case InsightSeverity.critical:
        return 'Urgent';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final severityColor = _severityColor(colorScheme);
    final severityLabel = _severityLabel();

    return Semantics(
      container: true,
      button: onTap != null,
      label: _locked
          ? '${insight.title}. Premium insight. Locked.'
          : '${insight.title}. ${severityLabel.toLowerCase()} insight.'
                '${insight.isPremium ? ' Premium.' : ''}',
      child: Card(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.55),
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            children: [
              _CardContent(
                insight: insight,
                locked: _locked,
                severityColor: severityColor,
                severityIcon: _severityIcon(),
                severityLabel: severityLabel,
              ),
              if (_locked) Positioned.fill(child: _LockedOverlay(onTap: onTap)),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Card content
// ════════════════════════════════════════════════════════════════════════════

class _CardContent extends StatelessWidget {
  final Insight insight;
  final bool locked;
  final Color severityColor;
  final IconData severityIcon;
  final String severityLabel;

  const _CardContent({
    required this.insight,
    required this.locked,
    required this.severityColor,
    required this.severityIcon,
    required this.severityLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Locked cards show the summary; unlocked cards show the full detail.
    // Fall back to detail if summary is missing.
    final visibleText = locked
        ? (insight.summary.isNotEmpty ? insight.summary : insight.detail)
        : insight.detail;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.surface,
            colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: severityColor.withValues(alpha: 0.10),
                  ),
                  child: Icon(severityIcon, size: 18, color: severityColor),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        insight.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        severityLabel.toUpperCase(),
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: severityColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (insight.isPremium) _PremiumBadge(locked: locked),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              visibleText,
              maxLines: locked ? 3 : null,
              overflow: locked ? TextOverflow.ellipsis : TextOverflow.visible,
              style: theme.textTheme.bodyMedium?.copyWith(
                height: 1.5,
                color: colorScheme.onSurface.withValues(alpha: 0.76),
              ),
            ),
            if (!locked &&
                insight.recommendation != null &&
                insight.recommendation!.trim().isNotEmpty) ...[
              const SizedBox(height: 14),
              _RecommendationBox(text: insight.recommendation!),
            ],
            if (!locked)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Tap to view details',
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurface.withValues(alpha: 0.40),
                      ),
                    ),
                    Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 12,
                      color: colorScheme.onSurface.withValues(alpha: 0.35),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Premium badge
// ════════════════════════════════════════════════════════════════════════════

class _PremiumBadge extends StatelessWidget {
  final bool locked;

  const _PremiumBadge({required this.locked});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final color = locked
        ? colorScheme.onSurface.withValues(alpha: 0.55)
        : colorScheme.primary;

    return Semantics(
      label: locked ? 'Premium. Locked.' : 'Premium.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          color: color.withValues(alpha: 0.10),
          border: Border.all(color: color.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              locked ? Icons.lock_outline : Icons.star_rounded,
              size: 12,
              color: color,
            ),
            const SizedBox(width: 3),
            Text(
              'PREMIUM',
              style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Locked overlay
// ════════════════════════════════════════════════════════════════════════════

class _LockedOverlay extends StatelessWidget {
  final VoidCallback? onTap;

  const _LockedOverlay({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.58),
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.12),
                ),
                child: const Icon(
                  Icons.workspace_premium_outlined,
                  color: Colors.white,
                  size: 25,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Premium Insight',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Tap to unlock',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.78),
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 2),
              Icon(
                Icons.arrow_forward_rounded,
                size: 16,
                color: Colors.white.withValues(alpha: 0.80),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Recommendation box
// ════════════════════════════════════════════════════════════════════════════

class _RecommendationBox extends StatelessWidget {
  final String text;

  const _RecommendationBox({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.12)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.lightbulb_outline_rounded,
            size: 17,
            color: colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Recommendation',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    height: 1.4,
                    color: colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
