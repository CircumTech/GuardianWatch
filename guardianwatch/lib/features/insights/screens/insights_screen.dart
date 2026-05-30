// ════════════════════════════════════════════════════════════════════════════
// lib/features/insights/screens/insights_screen.dart
// ════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../config/constants.dart';
import '../../../models/insight.dart';
import '../../../providers/insight_provider.dart';
import '../../../widgets/insight_card.dart';

class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  bool _isPurchasing = false;

  @override
  void initState() {
    super.initState();
    _loadInsights();
  }

  Future<void> _loadInsights() async {
    await context.read<InsightProvider>().loadInsights();
  }

  Future<void> _generateInsights() async {
    final ip = context.read<InsightProvider>();
    await ip.generateDailyInsights();
    if (mounted && ip.error == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('New insights generated!'),
          backgroundColor: Colors.green,
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
          const SnackBar(
            content: Text('Premium activated! Thank you.'),
            backgroundColor: Colors.green,
          ),
        );
        await _loadInsights();
      } else if (mounted && !success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Purchase failed or was cancelled.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
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
            content: Text(restored
                ? 'Purchases restored successfully'
                : 'No previous purchases found'),
            backgroundColor: restored ? Colors.green : Colors.orange,
          ),
        );
        if (restored) await _loadInsights();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restore failed: $e'), backgroundColor: Colors.red),
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
        SnackBar(content: Text('Could not open subscription settings: $e')),
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
        actions: [
          // Generate insights button (refresh)
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: ip.isGenerating ? null : _generateInsights,
            tooltip: 'Generate new insights',
          ),
          IconButton(
            icon: const Icon(Icons.restore),
            onPressed: _isPurchasing ? null : _restorePurchases,
            tooltip: 'Restore purchases',
          ),
          if (ip.isPremium)
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: _manageSubscriptions,
              tooltip: 'Manage subscription',
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadInsights,
        child: _buildBody(ip, cs),
      ),
    );
  }

  Widget _buildBody(InsightProvider ip, ColorScheme cs) {
    if (ip.isLoading && ip.insights.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (ip.isGenerating) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Analyzing your health data...'),
            SizedBox(height: 8),
            Text(
              'This may take a moment',
              style: TextStyle(fontSize: 12),
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
            Icon(Icons.error_outline, size: 64, color: cs.error),
            const SizedBox(height: 16),
            Text('Failed to load insights', style: TextStyle(color: cs.error)),
            const SizedBox(height: 8),
            Text(ip.error!, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loadInsights,
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
            Icon(Icons.auto_awesome, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            const Text('No insights available yet'),
            const SizedBox(height: 8),
            Text(
              'Tap the refresh button to generate insights\nfrom your health data.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _generateInsights,
              icon: const Icon(Icons.refresh),
              label: const Text('Generate Insights'),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!ip.isPremium) ...[
          _PremiumBanner(
            isPurchasing: _isPurchasing,
            onSubscribeMonthly: () => _subscribe(AppConstants.premiumMonthlyId),
            onSubscribeAnnual: () => _subscribe(AppConstants.premiumAnnualId),
            onRestore: _restorePurchases,
          ),
          const SizedBox(height: 20),
        ] else
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                colors: [cs.primary, cs.secondary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.star, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Premium Active',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'You have access to all AI-powered insights',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.9),
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
                    side: const BorderSide(color: Colors.white),
                  ),
                  child: const Text('Manage'),
                ),
              ],
            ),
          ),
        if (ip.isPremium) const SizedBox(height: 20),
        ...ip.insights.map((insight) => InsightCard(
          insight: insight,
          isPremium: ip.isPremium,
          onTap: () => _showInsightDetail(insight),
        )),
      ],
    );
  }

  void _showInsightDetail(Insight insight) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
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
                    color: Colors.grey.shade400,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                insight.title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: Theme.of(context).colorScheme.primaryContainer,
                ),
                child: Text(
                  insight.severity.name.toUpperCase(),
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                insight.detail,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (insight.recommendation != null) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Theme.of(context).colorScheme.primaryContainer,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Recommendation',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(insight.recommendation!),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 80),
            ],
          ),
        ),
      ),
    );
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
    return Card(
      color: cs.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome, color: cs.tertiary),
                const SizedBox(width: 8),
                Text(
                  'Unlock AI Insights',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Get AI-powered arrhythmia detection, sleep apnea risk scoring, '
                  'and personalised health recommendations.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: isPurchasing ? null : onSubscribeMonthly,
              icon: isPurchasing
                  ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
                  : const Icon(Icons.star),
              label: const Text('Go Premium – \$4.99/month'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: isPurchasing ? null : onSubscribeAnnual,
              child: const Text('Annual plan – \$39.99/year (save 33%)'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: isPurchasing ? null : onRestore,
              child: const Text('Restore previous purchase'),
            ),
          ],
        ),
      ),
    );
  }
}