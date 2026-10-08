// ════════════════════════════════════════════════════════════════════════════
// lib/features/insights/screens/insights_screen.dart
// ════════════════════════════════════════════════════════════════════════════
//
// Health Insights.
//
// Every insight surfaced here is a WELLNESS / ENGINEERING indicator.
// None is a diagnosis.
//
// The user-facing strings deliberately avoid:
//   - "AFib screening" / "AFib detection"
//   - "Sleep-apnea risk" / "Sleep-apnea screening"
//   - "Fever" as a diagnostic term
//
// Corresponding replacements:
//   - "Rhythm irregularity indicator"
//   - "Overnight oxygen trend"
//   - "Temperature deviation trend"
//
// The report explicitly states the baseline hardware lacks airflow and
// respiratory-effort sensing, so apnea inference is not supportable, and
// that PPG-based rhythm analysis must not be marketed as diagnosis until
// clinical validation is complete.
//

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../config/constants.dart';
import '../../../models/insight.dart';
import '../../../providers/insight_provider.dart';
import '../../../widgets/insight_card.dart';

// ════════════════════════════════════════════════════════════════════════════
// Insights Screen
// ════════════════════════════════════════════════════════════════════════════

class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen>
    with SingleTickerProviderStateMixin {
  bool _isPurchasing = false;
  bool _isRestoring = false;

  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  /// Cached product price strings. Populated lazily.
  String? _monthlyPrice;
  String? _annualPrice;
  bool _pricesLoaded = false;

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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadInsights();
      _loadPrices();
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Loading
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _loadInsights() async {
    if (!mounted) return;
    final provider = context.read<InsightProvider>();

    try {
      await provider.loadInsights();
      if (!mounted) return;

      _fadeController
        ..reset()
        ..forward();
    } catch (e) {
      debugPrint('Guardian insights load failed: $e');
    }
  }

  /// Best-effort product price fetch.
  ///
  /// Silently degrades if the store is unavailable — the buttons still
  /// work, they just omit the localized price.
  Future<void> _loadPrices() async {
    if (_pricesLoaded || !mounted) return;

    final provider = context.read<InsightProvider>();
    try {
      final products = await provider.fetchProducts();
      if (!mounted) return;

      for (final p in products) {
        if (p.id == AppConstants.premiumMonthlyId) {
          _monthlyPrice = p.price;
        } else if (p.id == AppConstants.premiumAnnualId) {
          _annualPrice = p.price;
        }
      }

      if (mounted) {
        setState(() {
          _pricesLoaded = true;
        });
      }
    } catch (e) {
      debugPrint('Guardian product price fetch skipped: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Generate
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _generateInsights() async {
    final provider = context.read<InsightProvider>();

    if (provider.isGenerating) return;

    await provider.generateDailyInsights();
    if (!mounted) return;

    if (provider.error != null) {
      _showError(provider.error!);
      return;
    }

    _fadeController
      ..reset()
      ..forward();

    _showSuccess('New wellness insights generated.');
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Purchase / restore
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _subscribe(String productId) async {
    if (_isPurchasing || _isRestoring) return;

    setState(() => _isPurchasing = true);

    try {
      final provider = context.read<InsightProvider>();
      final initiated = await provider.purchase(productId);
      if (!mounted) return;

      if (initiated) {
        _showSuccess(
          'Purchase initiated. Your premium access will activate after '
          'the store transaction is verified.',
        );
        await _loadInsights();
      } else {
        final error = provider.error;
        _showWarning(error ?? 'The purchase could not be completed.');
      }
    } catch (e, stack) {
      debugPrint('Guardian premium purchase error: $e');
      debugPrintStack(stackTrace: stack);
      if (mounted) {
        _showError('Unable to complete the purchase. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _isPurchasing = false);
    }
  }

  Future<void> _restorePurchases() async {
    if (_isPurchasing || _isRestoring) return;

    setState(() => _isRestoring = true);

    try {
      final provider = context.read<InsightProvider>();
      final restored = await provider.restorePurchases();
      if (!mounted) return;

      if (restored) {
        _showSuccess('Previous purchases restored.');
        await _loadInsights();
      } else {
        _showWarning('No active Guardian premium purchase was found.');
      }
    } catch (e, stack) {
      debugPrint('Guardian purchase restore error: $e');
      debugPrintStack(stackTrace: stack);
      if (mounted) {
        _showError('Unable to restore purchases. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _isRestoring = false);
    }
  }

  Future<void> _manageSubscriptions() async {
    try {
      await context.read<InsightProvider>().openManageSubscriptions();
    } catch (e, stack) {
      debugPrint('Guardian subscription management error: $e');
      debugPrintStack(stackTrace: stack);
      if (mounted) {
        _showError('Could not open subscription settings.');
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Feedback
  // ══════════════════════════════════════════════════════════════════════════

  void _showSuccess(String message) {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: cs.primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
  }

  void _showWarning(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
        ),
      );
  }

  void _showError(String message) {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: cs.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Build
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<InsightProvider>();
    final cs = Theme.of(context).colorScheme;
    final busy = _isPurchasing || _isRestoring;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Health Insights'),
        elevation: 0,
        backgroundColor: cs.surface,
        surfaceTintColor: cs.surface,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Generate insights',
            onPressed: provider.isGenerating || busy ? null : _generateInsights,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadInsights,
        color: cs.primary,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: _buildBody(provider, cs),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Body
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildBody(InsightProvider provider, ColorScheme cs) {
    if (provider.isLoading && provider.insights.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(
            height: 320,
            child: Center(child: CircularProgressIndicator()),
          ),
        ],
      );
    }

    if (provider.isGenerating) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.55,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 42,
                    height: 42,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: cs.primary,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Analyzing your health data',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Guardian is processing your recent measurements.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withValues(alpha: 0.50),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    if (provider.insights.isEmpty) {
      return _EmptyInsightsState(
        error: provider.error,
        onRetry: _loadInsights,
        onGenerate: _generateInsights,
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
      children: [
        if (provider.error != null && provider.insights.isNotEmpty)
          _InlineError(message: provider.error!),

        if (provider.error != null && provider.insights.isNotEmpty)
          const SizedBox(height: 12),

        if (!provider.isPremium)
          _PremiumBanner(
            isPurchasing: _isPurchasing,
            isRestoring: _isRestoring,
            monthlyPrice: _monthlyPrice,
            annualPrice: _annualPrice,
            onSubscribeMonthly: () => _subscribe(AppConstants.premiumMonthlyId),
            onSubscribeAnnual: () => _subscribe(AppConstants.premiumAnnualId),
            onRestore: _restorePurchases,
          )
        else
          _PremiumActiveBanner(cs, onManage: _manageSubscriptions),

        const SizedBox(height: 20),

        _InsightAvailabilityCard(cs: cs),

        const SizedBox(height: 18),

        ...provider.insights.map(
          (insight) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: InsightCard(
              insight: insight,
              isPremium: provider.isPremium,
              onTap: () => _showInsightDetail(insight),
            ),
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Insight availability
  //
  // Rows match what InsightProvider.generateDailyInsights actually emits.
  // Titles avoid clinical language.
  // ══════════════════════════════════════════════════════════════════════════

  Widget _InsightAvailabilityCard({required ColorScheme cs}) {
    return Card(
      elevation: 0,
      color: cs.surfaceContainerHighest.withValues(alpha: 0.30),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.45)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome_outlined, size: 19, color: cs.primary),
                const SizedBox(width: 8),
                Text(
                  'Guardian Insights',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            const _InsightAvailabilityRow(
              title: 'Stress & recovery report',
              premium: false,
            ),
            const _InsightAvailabilityRow(
              title: 'Temperature deviation trend',
              premium: false,
            ),
            const _InsightAvailabilityRow(
              title: 'Heart-rate elevation indicator',
              premium: false,
            ),
            const _InsightAvailabilityRow(
              title: 'Overnight oxygen trend',
              premium: true,
            ),
            const _InsightAvailabilityRow(
              title: 'Rhythm irregularity indicator',
              premium: true,
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Detail modal
  // ══════════════════════════════════════════════════════════════════════════

  void _showInsightDetail(Insight insight) {
    final cs = Theme.of(context).colorScheme;
    final provider = context.read<InsightProvider>();

    if (insight.isPremium && !provider.isPremium) {
      _showPremiumPrompt();
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.65,
        minChildSize: 0.40,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, scrollController) {
          final severityColor = _getSeverityColor(insight.severity, cs);
          final severityLabel = _severityLabel(insight.severity);

          return ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 32),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    color: cs.outlineVariant,
                  ),
                ),
              ),

              const SizedBox(height: 20),

              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      insight.title,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  if (insight.isPremium)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.workspace_premium_outlined, size: 24),
                    ),
                ],
              ),

              const SizedBox(height: 12),

              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _InsightChip(
                    label: severityLabel.toUpperCase(),
                    color: severityColor,
                  ),
                  if (insight.isPremium)
                    _InsightChip(label: 'PREMIUM', color: cs.primary),
                ],
              ),

              const SizedBox(height: 18),

              Text(
                insight.detail,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.6,
                  color: cs.onSurface,
                ),
              ),

              if (insight.recommendation != null &&
                  insight.recommendation!.trim().isNotEmpty) ...[
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: cs.primaryContainer.withValues(alpha: 0.18),
                    border: Border.all(
                      color: cs.primaryContainer.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Recommendation',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: cs.primary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        insight.recommendation!,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.55,
                          color: cs.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 28),

              Text(
                'Generated ${_formatGeneratedAt(insight.generatedAt)}',
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurface.withValues(alpha: 0.40),
                ),
              ),

              const SizedBox(height: 16),

              Container(
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
                ),
                child: Text(
                  'Health insights are informational and are not a '
                  'diagnosis. Seek professional medical evaluation for '
                  'concerning or persistent symptoms.',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.45,
                    color: cs.onSurface.withValues(alpha: 0.50),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Helpers
  // ══════════════════════════════════════════════════════════════════════════

  String _formatGeneratedAt(DateTime dateTime) {
    final local = dateTime.toLocal();
    return DateFormat('MMM d, yyyy - h:mm a').format(local);
  }

  /// User-facing severity label.
  ///
  /// Avoids the raw enum name and avoids alarming clinical language.
  String _severityLabel(InsightSeverity severity) {
    switch (severity) {
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

  // ══════════════════════════════════════════════════════════════════════════
  // Premium prompt
  //
  // Shown when a locked insight is tapped. Dismisses to the page — the
  // premium banner is already on the page and does not need a separate
  // paywall screen.
  // ══════════════════════════════════════════════════════════════════════════

  void _showPremiumPrompt() {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        final cs = Theme.of(sheetContext).colorScheme;

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.workspace_premium_outlined,
                size: 44,
                color: cs.primary,
              ),
              const SizedBox(height: 14),
              Text(
                'Premium Insight',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Subscribe to Guardian Premium to unlock this insight. '
                'Plans are available on this page.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: cs.onSurface.withValues(alpha: 0.60),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text('Got it'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      },
    );
  }

  Color _getSeverityColor(InsightSeverity severity, ColorScheme cs) {
    switch (severity) {
      case InsightSeverity.normal:
        return Colors.green;
      case InsightSeverity.caution:
        return Colors.orange;
      case InsightSeverity.warning:
        return Colors.deepOrange;
      case InsightSeverity.critical:
        return cs.error;
    }
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Insight availability row
// ════════════════════════════════════════════════════════════════════════════

class _InsightAvailabilityRow extends StatelessWidget {
  final String title;
  final bool premium;

  const _InsightAvailabilityRow({required this.title, required this.premium});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            premium ? Icons.lock_outline : Icons.check_circle_outline,
            size: 18,
            color: premium ? cs.onSurface.withValues(alpha: 0.45) : cs.primary,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              title,
              style: TextStyle(fontSize: 13, color: cs.onSurface),
            ),
          ),
          Text(
            premium ? 'Premium' : 'Free',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: premium
                  ? cs.onSurface.withValues(alpha: 0.45)
                  : cs.primary,
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Premium active banner
// ════════════════════════════════════════════════════════════════════════════

class _PremiumActiveBanner extends StatelessWidget {
  final ColorScheme cs;
  final VoidCallback onManage;

  const _PremiumActiveBanner(this.cs, {required this.onManage});

  @override
  Widget build(BuildContext context) {
    return Container(
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
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.15),
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
                  'Full access to premium wellness insights',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: onManage,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            ),
            child: const Text('Manage'),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Premium banner
// ════════════════════════════════════════════════════════════════════════════

class _PremiumBanner extends StatelessWidget {
  final bool isPurchasing;
  final bool isRestoring;
  final String? monthlyPrice;
  final String? annualPrice;
  final VoidCallback onSubscribeMonthly;
  final VoidCallback onSubscribeAnnual;
  final VoidCallback onRestore;

  const _PremiumBanner({
    required this.isPurchasing,
    required this.isRestoring,
    required this.monthlyPrice,
    required this.annualPrice,
    required this.onSubscribeMonthly,
    required this.onSubscribeAnnual,
    required this.onRestore,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final monthlyLabel = monthlyPrice == null
        ? 'Choose Monthly Plan'
        : 'Monthly - $monthlyPrice';

    final annualLabel = annualPrice == null
        ? 'Choose Annual Plan'
        : 'Annual - $annualPrice';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: cs.tertiaryContainer.withValues(alpha: 0.15),
        border: Border.all(color: cs.tertiaryContainer.withValues(alpha: 0.25)),
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
                  color: cs.tertiary.withValues(alpha: 0.12),
                ),
                child: Icon(
                  Icons.auto_awesome_outlined,
                  color: cs.tertiary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Unlock Premium Insights',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          Text(
            'Unlock overnight oxygen trends, rhythm irregularity '
            'indicators, and expanded wellness analysis. These are '
            'engineering indicators — not medical diagnoses.',
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: cs.onSurface.withValues(alpha: 0.70),
            ),
          ),

          const SizedBox(height: 16),

          const _PremiumFeatureRow(text: 'Overnight oxygen trend'),
          const _PremiumFeatureRow(text: 'Rhythm irregularity indicator'),
          const _PremiumFeatureRow(text: 'Expanded wellness analysis'),

          const SizedBox(height: 16),

          FilledButton.icon(
            onPressed: isPurchasing || isRestoring ? null : onSubscribeMonthly,
            icon: isPurchasing
                ? const SizedBox(
                    width: 19,
                    height: 19,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : const Icon(Icons.star_rounded),
            label: Text(monthlyLabel),
            style: FilledButton.styleFrom(
              backgroundColor: cs.tertiary,
              foregroundColor: cs.onTertiary,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),

          const SizedBox(height: 8),

          OutlinedButton(
            onPressed: isPurchasing || isRestoring ? null : onSubscribeAnnual,
            style: OutlinedButton.styleFrom(
              foregroundColor: cs.tertiary,
              side: BorderSide(color: cs.tertiary.withValues(alpha: 0.45)),
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(annualLabel),
          ),

          const SizedBox(height: 4),

          Center(
            child: TextButton(
              onPressed: isPurchasing || isRestoring ? null : onRestore,
              child: isRestoring
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Restore previous purchase'),
            ),
          ),

          const SizedBox(height: 4),

          Text(
            'Prices and currency are determined by the App Store or '
            'Google Play for your account and region.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10,
              height: 1.35,
              color: cs.onSurface.withValues(alpha: 0.42),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Premium feature row
// ════════════════════════════════════════════════════════════════════════════

class _PremiumFeatureRow extends StatelessWidget {
  final String text;

  const _PremiumFeatureRow({required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 17, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.75),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Inline error
// ════════════════════════════════════════════════════════════════════════════

class _InlineError extends StatelessWidget {
  final String message;

  const _InlineError({required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: cs.errorContainer.withValues(alpha: 0.35),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12, color: cs.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Empty insights state
// ════════════════════════════════════════════════════════════════════════════

class _EmptyInsightsState extends StatelessWidget {
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback onGenerate;

  const _EmptyInsightsState({
    required this.error,
    required this.onRetry,
    required this.onGenerate,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.58,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    error != null
                        ? Icons.error_outline
                        : Icons.auto_awesome_outlined,
                    size: 56,
                    color: error != null
                        ? cs.error
                        : cs.primary.withValues(alpha: 0.45),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    error != null
                        ? 'Unable to load insights'
                        : 'No insights available',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    error ??
                        'Generate an analysis from your recent Guardian '
                            'Watch measurements.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (error != null)
                    FilledButton(onPressed: onRetry, child: const Text('Retry'))
                  else
                    FilledButton.icon(
                      onPressed: onGenerate,
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Generate Insights'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Insight chip
// ════════════════════════════════════════════════════════════════════════════

class _InsightChip extends StatelessWidget {
  final String label;
  final Color color;

  const _InsightChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: color.withValues(alpha: 0.12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.45,
        ),
      ),
    );
  }
}
