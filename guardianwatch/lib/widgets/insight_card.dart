// ─── lib/widgets/insight_card.dart ───────────────────────────────────────────

import 'package:flutter/material.dart';
import '../models/insight.dart';

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

  Color _severityColor() {
    switch (insight.severity) {
      case InsightSeverity.caution:
        return Colors.orange;
      case InsightSeverity.warning:
        return Colors.deepOrange;
      case InsightSeverity.critical:
        return Colors.red;
      default:
        return Colors.green;
    }
  }

  IconData _severityIcon() {
    switch (insight.severity) {
      case InsightSeverity.caution:
        return Icons.warning_amber;
      case InsightSeverity.warning:
        return Icons.error_outline;
      case InsightSeverity.critical:
        return Icons.crisis_alert;
      default:
        return Icons.check_circle_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = insight.isPremium && !isPremium;
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: locked ? null : onTap,
        child: Container(
          decoration: BoxDecoration(
            gradient: locked
                ? null
                : LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                theme.colorScheme.surface,
                theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
              ],
            ),
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _severityColor(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            insight.title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (insight.isPremium)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              color: Colors.amber.withOpacity(0.2),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.star, size: 12, color: Colors.amber),
                                SizedBox(width: 2),
                                Text(
                                  'PREMIUM',
                                  style: TextStyle(
                                    fontSize: 8,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.amber,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      locked ? insight.summary : insight.detail,
                      style: theme.textTheme.bodySmall,
                      maxLines: locked ? 2 : null,
                      overflow: locked ? TextOverflow.ellipsis : TextOverflow.visible,
                    ),
                    if (!locked && insight.recommendation != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.lightbulb_outline,
                              size: 16,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                insight.recommendation!,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (locked)
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: Colors.black.withOpacity(0.6),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.lock_outline,
                            color: Colors.white,
                            size: 28,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Premium Insight',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}