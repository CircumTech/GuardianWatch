// ════════════════════════════════════════════════════════════════════════════
// lib/features/insights/screens/insights_screen.dart
// ════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../config/constants.dart';
import '../../../models/insight.dart';
import '../../../providers/insight_provider.dart';
import '../../../widgets/insight_card.dart';

// ============================================================================
// Insights Screen
// ============================================================================

class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen>
    with SingleTickerProviderStateMixin {
  bool _isPurchasing = false;

  // Animation for insights list
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _loadInsights();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _loadInsights() async {
    await context.read<InsightProvider>().loadInsights();
    _fadeController.reset();
    _fadeController.forward();
  }

  Future<void> _generateInsights() async {
    final ip = context.read<InsightProvider>();
    await ip.generateDailyInsights();
    if (mounted && ip.error == null) {
      _fadeController.reset();
      _fadeController.forward();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('New insights generated'),
          backgroundColor: Theme.of(context).colorScheme.primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
    }
  }

  Future<void> _subscribe(String productId) async {
    if (_isPurchasing) return;
    setState(() => _isPurchasing = true);

    try {
      final ip = context.read<InsightProvider>();
      final success = await ip.purchase(productId);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Premium activated successfully'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
        await _loadInsights();
      } else if (mounted && !success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Purchase cancelled or failed'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isPurchasing = false);
    }
  }

  Future<void> _restorePurchases() async {
    setState(() => _isPurchasing = true);
    try {
      final ip = context.read<InsightProvider>();
      final restored = await ip.restorePurchases();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              restored
                  ? 'Purchases restored successfully'
                  : 'No previous purchases found',
            ),
            backgroundColor: restored ? Colors.green : Colors.orange,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
        if (restored) await _loadInsights();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Restore failed: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isPurchasing = false);
    }
  }

  Future<void> _manageSubscriptions() async {
    final ip = context.read<InsightProvider>();
    try {
      await ip.openManageSubscriptions();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open subscription settings: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ip = context.watch<InsightProvider>();
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Insights'),
        elevation: 0,
        backgroundColor: cs.surface,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: ip.isGenerating ? null : _generateInsights,
            tooltip: 'Generate insights',
          ),
          IconButton(
            icon: const Icon(Icons.restore_outlined),
            onPressed: _isPurchasing ? null : _restorePurchases,
            tooltip: 'Restore purchases',
          ),
          if (ip.isPremium)
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              onPressed: _manageSubscriptions,
              tooltip: 'Manage subscription',
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadInsights,
        color: cs.primary,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: _buildBody(ip, cs),
        ),
      ),
    );
  }

  Widget _buildBody(InsightProvider ip, ColorScheme cs) {
    if (ip.isLoading && ip.insights.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (ip.isGenerating) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Analyzing your health data',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'This may take a moment',
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withOpacity(0.5),
              ),
            ),
          ],
        ),
      );
    }

    if (ip.error != null && ip.insights.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 56, color: cs.error),
            const SizedBox(height: 16),
            Text(
              'Failed to load insights',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: cs.error,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              ip.error!,
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface.withOpacity(0.6),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _loadInsights,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (ip.insights.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.auto_awesome_outlined,
              size: 56,
              color: cs.onSurface.withOpacity(0.15),
            ),
            const SizedBox(height: 16),
            Text(
              'No insights available',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Generate insights from your health data',
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface.withOpacity(0.4),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _generateInsights,
              icon: const Icon(Icons.refresh),
              label: const Text('Generate Insights'),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Premium Status
        if (!ip.isPremium)
          _PremiumBanner(
            isPurchasing: _isPurchasing,
            onSubscribeMonthly: () => _subscribe(AppConstants.premiumMonthlyId),
            onSubscribeAnnual: () => _subscribe(AppConstants.premiumAnnualId),
            onRestore: _restorePurchases,
          )
        else
          _PremiumActiveBanner(cs),

        const SizedBox(height: 20),

        // Insights List
        ...ip.insights.map(
          (insight) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: InsightCard(
              insight: insight,
              isPremium: ip.isPremium,
              onTap: () => _showInsightDetail(insight),
            ),
          ),
        ),
      ],
    );
  }

  Widget _PremiumActiveBanner(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          colors: [cs.primary, cs.secondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white24,
            ),
            child: const Icon(
              Icons.star_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Premium Active',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                Text(
                  'Full access to all AI-powered insights',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.85),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: _manageSubscriptions,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white, width: 1.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            child: const Text('Manage'),
          ),
        ],
      ),
    );
  }

  void _showInsightDetail(Insight insight) {
    final cs = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      backgroundColor: cs.surface,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    color: cs.outline.withOpacity(0.3),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                insight.title,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: _getSeverityColor(
                    insight.severity,
                    cs,
                  ).withOpacity(0.12),
                ),
                child: Text(
                  insight.severity.name.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _getSeverityColor(insight.severity, cs),
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                insight.detail,
                style: TextStyle(
                  fontSize: 16,
                  height: 1.6,
                  color: cs.onSurface,
                ),
              ),
              if (insight.recommendation != null) ...[
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: cs.primaryContainer.withOpacity(0.15),
                    border: Border.all(
                      color: cs.primaryContainer.withOpacity(0.3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Recommendation',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.primary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        insight.recommendation!,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          color: cs.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Color _getSeverityColor(InsightSeverity severity, ColorScheme cs) {
    switch (severity) {
      case InsightSeverity.normal:
        return Colors.green;
      case InsightSeverity.caution:
        return Colors.orange;
      case InsightSeverity.critical:
        return Colors.red;
      default:
        return cs.primary;
    }
  }
}

// ============================================================================
// Premium Banner
// ============================================================================

class _PremiumBanner extends StatelessWidget {
  final bool isPurchasing;
  final VoidCallback onSubscribeMonthly;
  final VoidCallback onSubscribeAnnual;
  final VoidCallback onRestore;

  const _PremiumBanner({
    required this.isPurchasing,
    required this.onSubscribeMonthly,
    required this.onSubscribeAnnual,
    required this.onRestore,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: cs.tertiaryContainer.withOpacity(0.15),
        border: Border.all(color: cs.tertiaryContainer.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cs.tertiary.withOpacity(0.12),
                ),
                child: Icon(
                  Icons.auto_awesome_outlined,
                  color: cs.tertiary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Unlock AI Insights',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Get AI-powered arrhythmia detection, sleep apnea risk scoring, '
            'and personalised health recommendations.',
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurface.withOpacity(0.7),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: isPurchasing ? null : onSubscribeMonthly,
            icon: isPurchasing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : const Icon(Icons.star_rounded),
            label: const Text('Go Premium – \$4.99 / month'),
            style: FilledButton.styleFrom(
              backgroundColor: cs.tertiary,
              foregroundColor: cs.onTertiary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
              minimumSize: const Size(double.infinity, 0),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: isPurchasing ? null : onSubscribeAnnual,
            style: OutlinedButton.styleFrom(
              foregroundColor: cs.tertiary,
              side: BorderSide(color: cs.tertiary.withOpacity(0.4)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
              minimumSize: const Size(double.infinity, 0),
            ),
            child: const Text('Annual Plan – \$39.99 / year (save 33%)'),
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: isPurchasing ? null : onRestore,
              style: TextButton.styleFrom(
                foregroundColor: cs.onSurface.withOpacity(0.5),
              ),
              child: const Text('Restore previous purchase'),
            ),
          ),
        ],
      ),
    );
  }
}
