// ════════════════════════════════════════════════════════════════════════════
// lib/providers/insight_provider.dart
// ════════════════════════════════════════════════════════════════════════════
//
// InsightProvider — live metrics + insight generation.
//
// Responsibilities:
//   Drive the InsightModelService with incoming sensor samples
//   Compute realtime HRV / oxygen-trend / temperature / HR indicators
//   Fetch backend insights and merge with locally generated ones
//   Generate insight cards from the current wellness indicators
//   Track premium entitlement state via IAPService
//
// Every insight produced here is a WELLNESS indicator.
// Never a diagnosis. Titles and summaries avoid clinical claims.
//
// Design rules:
//   Uses ApiService.shared.
//   InsightModelService is a singleton — never dispose it here.
//   All notifyListeners() paths are guarded by _disposed.
//

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart' show ProductDetails;

import '../models/health_metrics.dart';
import '../models/insight.dart';
import '../services/api_service.dart';
import '../services/iap_service.dart';
import '../services/insight_model_service.dart';

class InsightProvider extends ChangeNotifier {
  InsightProvider(this._iap) {
    _initialize();
  }

  // ── Services ──────────────────────────────────────────────────────────────

  final ApiService _api = ApiService.shared;

  final IAPService _iap;

  /// Singleton — never disposed by this provider.
  final InsightModelService _modelService = InsightModelService();

  // ── State ─────────────────────────────────────────────────────────────────

  List<Insight> _insights = <Insight>[];

  bool _loading = false;
  bool _generating = false;
  bool _modelsReady = false;
  bool _initialized = false;
  String? _error;

  // ── Realtime indicators ───────────────────────────────────────────────────

  HRVMetrics? _currentHRV;
  AFibResult? _currentRhythm;
  OxygenDesaturationTrend? _currentOxygenTrend;
  FeverResult? _currentTemperatureDeviation;
  FatigueResult? _currentHrElevation;

  // ── Subscriptions ─────────────────────────────────────────────────────────

  StreamSubscription<bool>? _premiumSubscription;

  final Completer<void> _readyCompleter = Completer<void>();

  bool _disposed = false;

  // ══════════════════════════════════════════════════════════════════════════
  // Getters
  // ══════════════════════════════════════════════════════════════════════════

  List<Insight> get insights => List<Insight>.unmodifiable(_insights);

  bool get isLoading => _loading;
  bool get isGenerating => _generating;
  bool get isPremium => _iap.isPremium;
  bool get modelsReady => _modelsReady;
  bool get isInitialized => _initialized;
  bool get isReady => _initialized;
  String? get error => _error;

  HRVMetrics? get currentHRV => _currentHRV;

  /// Engineering rhythm-irregularity indicator, NOT a diagnosis.
  AFibResult? get currentRhythmIrregularity => _currentRhythm;

  /// Overnight oxygen-desaturation trend, NOT an apnea metric.
  OxygenDesaturationTrend? get currentOxygenTrend => _currentOxygenTrend;

  /// Temperature deviation from baseline, NOT a fever diagnosis.
  FeverResult? get currentTemperatureDeviation => _currentTemperatureDeviation;

  /// Resting-HR elevation indicator, NOT a multimodal fatigue score.
  FatigueResult? get currentHrElevation => _currentHrElevation;

  /// Awaits model loading + first insight fetch.
  Future<void> waitUntilReady() => _readyCompleter.future;

  // ══════════════════════════════════════════════════════════════════════════
  // Initialization
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _initialize() async {
    if (_initialized) return;

    try {
      await _modelService.loadModels();
      _modelsReady = _modelService.modelsLoaded;

      if (!_modelsReady) {
        debugPrint(
          'Guardian insight provider initialized without a loaded ML model. '
          'Rhythm screening will fall back to the RR-irregularity heuristic.',
        );
      }
    } catch (e, stack) {
      debugPrint('Guardian insight model initialization failed: $e');
      debugPrintStack(stackTrace: stack);
      _modelsReady = false;
    }

    // Watch premium state so we can refresh insights when entitlement changes.
    _premiumSubscription = _iap.premiumStream.listen(
      (_) {
        unawaited(loadInsights());
      },
      onError: (Object error, StackTrace stack) {
        debugPrint('Guardian premium stream error: $error');
        debugPrintStack(stackTrace: stack);
        _setError('Premium entitlement update failed.');
      },
    );

    _initialized = true;

    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }

    _safeNotify();

    // Load remote insights on startup.
    unawaited(loadInsights());
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Error handling
  // ══════════════════════════════════════════════════════════════════════════

  void clearError() {
    if (_error == null) return;
    _error = null;
    _safeNotify();
  }

  void _setError(String message) {
    _error = message;
    _safeNotify();
  }

  /// Maps any error to a user-safe message.
  ///
  /// Raw `toString()` values are never surfaced to the UI for
  /// non-network errors.
  String _friendlyError(Object error) {
    if (error is ApiException) {
      if (error.isUnauthorized) {
        return 'Your session has expired. Please sign in again.';
      }
      if (error.isForbidden) {
        return 'You do not have permission to view this.';
      }
      if (error.isNotFound) {
        return 'The requested data was not found.';
      }
      if (error.isServerError) {
        return 'The Guardian server is unavailable. Please try again later.';
      }
      if (error.isValidationError) {
        return 'The request could not be validated. Please check your data.';
      }
      if (error.statusCode == null) {
        return 'Network connection failed. Please check your internet '
            'connection and try again.';
      }
      return error.message;
    }

    final text = error.toString();
    if (text.isEmpty) return 'An unexpected error occurred.';

    if (text.contains('SocketException') ||
        text.contains('Failed host lookup') ||
        text.contains('ClientException') ||
        text.contains('HandshakeException')) {
      return 'Network connection failed. Please check your internet '
          'connection and try again.';
    }

    if (error is StateError) return 'The operation is not available.';

    // Do not leak raw Dart errors to the user.
    return 'Something went wrong. Please try again.';
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Real-time data ingestion
  // ══════════════════════════════════════════════════════════════════════════

  void feedEcgData(List<double> ecgSamples, {DateTime? timestamp}) {
    if (_disposed || ecgSamples.isEmpty) return;
    _modelService.addEcgSample(ecgSamples, timestamp: timestamp);
  }

  void feedHeartRate(int heartRate, {DateTime? timestamp}) {
    if (_disposed) return;
    if (heartRate <= 0 || heartRate > 240) return;
    _modelService.addHeartRate(heartRate, timestamp: timestamp);
  }

  void feedTemperature(double temperature, {DateTime? timestamp}) {
    if (_disposed) return;
    if (!temperature.isFinite || temperature <= 0 || temperature > 60) return;
    _modelService.addTemperature(temperature, timestamp: timestamp);
  }

  void feedSpO2(int spo2, {DateTime? timestamp}) {
    if (_disposed) return;
    if (spo2 <= 0 || spo2 > 100) return;
    _modelService.addSpO2(spo2, timestamp: timestamp);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Realtime indicators
  // ══════════════════════════════════════════════════════════════════════════

  void updateRealtimeMetrics() {
    if (_disposed) return;
    _updateRealtimeMetricsInternal();
    _safeNotify();
  }

  void _updateRealtimeMetricsInternal() {
    _currentHRV = _modelService.computeHRV();
    _currentOxygenTrend = _modelService.computeOxygenDesaturationTrend();
    _currentTemperatureDeviation = _modelService.computeTemperatureDeviation();
    _currentHrElevation = _modelService.computeHeartRateElevationIndicator();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Backend insights
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> loadInsights() async {
    if (_disposed || _loading) return;

    _loading = true;
    _error = null;
    _safeNotify();

    try {
      final remote = await _api.fetchInsights();
      if (_disposed) return;

      _insights = _deduplicate(remote);
      _updateRealtimeMetricsInternal();
    } catch (e, stack) {
      debugPrint('Guardian insight loading failed: $e');
      debugPrintStack(stackTrace: stack);

      // Preserve existing insights if the network fails.
      if (_insights.isEmpty && !_disposed) {
        _error = _friendlyError(e);
      }
    } finally {
      if (!_disposed) {
        _loading = false;
        _safeNotify();
      }
    }
  }

  List<Insight> _deduplicate(List<Insight> input) {
    final seen = <String>{};
    final result = <Insight>[];
    for (final insight in input) {
      if (seen.add(insight.id)) result.add(insight);
    }
    return result;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Generate insights from current indicators
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> generateDailyInsights() async {
    if (_disposed || _generating) return;

    _generating = true;
    _error = null;
    _safeNotify();

    try {
      _updateRealtimeMetricsInternal();

      final generated = <Insight>[];
      final now = DateTime.now();

      // ── HRV / recovery (FREE) ──────────────────────────────────────────

      final hrv = _currentHRV;
      if (hrv != null &&
          hrv.stressLevel != 'Insufficient data' &&
          hrv.rmssd > 0) {
        generated.add(
          Insight(
            id: '${now.microsecondsSinceEpoch}_hrv',
            title: 'Stress & Recovery Report',
            summary:
                'Your HRV analysis indicates ${hrv.stressLevel.toLowerCase()} stress.',
            detail:
                'RMSSD: ${hrv.rmssd.toStringAsFixed(1)} ms\n'
                'SDNN: ${hrv.sdnn.toStringAsFixed(1)} ms\n'
                'Stress score: ${hrv.stressScore.toStringAsFixed(1)}/100\n\n'
                'Recovery status: ${hrv.recoveryStatus}.\n\n'
                'HRV is influenced by sleep, exercise, stress, illness, '
                'hydration and other physiological factors. This is a '
                'wellness indicator, not a medical measurement.',
            severity: hrv.stressScore >= 70
                ? InsightSeverity.warning
                : hrv.stressScore >= 50
                ? InsightSeverity.caution
                : InsightSeverity.normal,
            isPremium: false,
            generatedAt: now,
            recommendation: hrv.stressScore >= 70
                ? 'Consider prioritizing rest, hydration and '
                      'stress-management activities.'
                : 'Maintain healthy sleep and recovery habits.',
          ),
        );
      }

      // ── Overnight oxygen trend (PREMIUM) ───────────────────────────────
      // ──────────────────────────────────────────────────────────────────

      final oxygen = _currentOxygenTrend;
      if (oxygen != null && oxygen.trendLevel != 'Insufficient data') {
        generated.add(
          Insight(
            id: '${now.microsecondsSinceEpoch}_oxygen_trend',
            title: 'Overnight Oxygen Trend',
            summary: 'Oxygen-dip trend level: ${oxygen.trendLevel}.',
            detail:
                'Oxygen desaturation events per hour '
                '(engineering proxy): '
                '${oxygen.desaturationIndexProxy.toStringAsFixed(1)}.\n\n'
                'This is an overnight oxygen-trend indicator based on '
                'available SpO₂ samples. It is not a diagnosis of sleep '
                'apnea and should not replace clinical assessment.',
            severity: oxygen.trendScore >= 60
                ? InsightSeverity.warning
                : oxygen.trendScore >= 30
                ? InsightSeverity.caution
                : InsightSeverity.normal,
            isPremium: true,
            generatedAt: now,
            recommendation: oxygen.recommendation,
          ),
        );
      }

      // ── Temperature deviation (FREE) ───────────────────────────────────

      final tempDev = _currentTemperatureDeviation;
      if (tempDev != null && tempDev.isSuspected) {
        final difference = tempDev.currentTemp - tempDev.baselineTemp;
        generated.add(
          Insight(
            id: '${now.microsecondsSinceEpoch}_temperature',
            title: 'Temperature Above Baseline',
            summary:
                'Your temperature is ${difference.toStringAsFixed(1)} °C '
                'above your recent baseline.',
            detail:
                'Current temperature: '
                '${tempDev.currentTemp.toStringAsFixed(1)} °C\n'
                'Estimated baseline: '
                '${tempDev.baselineTemp.toStringAsFixed(1)} °C\n\n'
                'This is a personal temperature-trend indicator. '
                'It does not establish the presence or cause of an infection.',
            severity: difference >= 2
                ? InsightSeverity.warning
                : InsightSeverity.caution,
            isPremium: false,
            generatedAt: now,
            recommendation: tempDev.recommendation,
          ),
        );
      }

      // ── HR-elevation indicator (FREE) ──────────────────────────────────

      final hrElev = _currentHrElevation;
      if (hrElev != null) {
        generated.add(
          Insight(
            id: '${now.microsecondsSinceEpoch}_hr_elevation',
            title: 'Recovery & Heart-Rate Elevation',
            summary: 'Current readiness: ${hrElev.readiness}.',
            detail:
                'Elevation score: '
                '${hrElev.fatigueScore.toStringAsFixed(1)}/100\n\n'
                'Recent heart-rate trend: '
                '${hrElev.restingHrTrend}.\n\n'
                'This is based on resting heart-rate trend only, '
                'not a multimodal fatigue measurement.',
            severity: hrElev.fatigueScore >= 70
                ? InsightSeverity.warning
                : hrElev.fatigueScore >= 40
                ? InsightSeverity.caution
                : InsightSeverity.normal,
            isPremium: false,
            generatedAt: now,
            recommendation: hrElev.recommendation,
          ),
        );
      }

      // NOTE: no automatic rhythm insight is generated here.
      // Rhythm screening requires an explicit ECG session segment
      // through analyzeEcgRhythm().

      if (generated.isNotEmpty && !_disposed) {
        _insights = [...generated, ..._insights];
        _insights = _deduplicate(_insights);
        _safeNotify();

        // Best-effort backend persistence.
        try {
          await _api.saveInsights(generated);
        } catch (e) {
          debugPrint('Failed to save generated Guardian insights: $e');
        }
      }
    } catch (e, stack) {
      debugPrint('Guardian daily insight generation failed: $e');
      debugPrintStack(stackTrace: stack);
      if (!_disposed) _error = _friendlyError(e);
    } finally {
      if (!_disposed) {
        _generating = false;
        _safeNotify();
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Fetch Products
  // Passthrough to IAPService for the paywall UI to display prices.
  //
  /// Returns an empty list if the store is unavailable or the fetch fails.
  // ══════════════════════════════════════════════════════════════════════════

  Future<List<ProductDetails>> fetchProducts() async {
    if (_disposed) return const [];
    try {
      return await _iap.fetchProducts();
    } catch (e) {
      debugPrint('Guardian product fetch failed: $e');
      return const [];
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Rhythm irregularity screening
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> analyzeEcgRhythm(List<double> ecgSegment) async {
    if (_disposed || ecgSegment.isEmpty) return;

    _error = null;
    _safeNotify();

    try {
      final result = await _modelService.computeRhythmIrregularityIndicator(
        ecgSegment,
      );

      if (_disposed) return;

      _currentRhythm = result;

      // No alert unless the screening threshold was crossed.
      if (!result.isSuspected) {
        _safeNotify();
        return;
      }

      final now = DateTime.now();

      final insight = Insight(
        id: '${now.microsecondsSinceEpoch}_rhythm',
        title: 'Irregular Rhythm Pattern',
        summary:
            'The analysed ECG segment contains an irregular pattern that '
            'may warrant medical review.',
        detail:
            'Guardian Watch identified an irregular rhythm pattern in '
            'the analysed ECG segment.\n\n'
            'This is a screening/engineering indicator, not a diagnosis '
            'of atrial fibrillation. Other rhythm conditions, noise, poor '
            'electrode contact and signal artifacts can affect the result.',
        severity: InsightSeverity.warning,
        isPremium: true,
        generatedAt: now,
        recommendation:
            'If you have symptoms or repeated irregular-rhythm results, '
            'seek evaluation from a qualified healthcare professional.',
      );

      _insights.insert(0, insight);
      _insights = _deduplicate(_insights);
      _safeNotify();

      try {
        await _api.saveInsights(<Insight>[insight]);
      } catch (e) {
        debugPrint('Failed to save rhythm insight: $e');
      }
    } catch (e, stack) {
      debugPrint('Guardian rhythm analysis failed: $e');
      debugPrintStack(stackTrace: stack);
      if (!_disposed) {
        _error = _friendlyError(e);
        _safeNotify();
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Purchases
  // ══════════════════════════════════════════════════════════════════════════

  Future<bool> purchase(String productId) async {
    if (_disposed) return false;

    _error = null;
    _safeNotify();

    try {
      final products = await _iap.fetchProducts();
      if (_disposed) return false;

      if (products.isEmpty) {
        _setError('Premium products are currently unavailable.');
        return false;
      }

      final match = products
          .where((product) => product.id == productId)
          .toList();
      if (match.isEmpty) {
        _setError('The selected premium plan is unavailable.');
        return false;
      }

      final initiated = await _iap.purchase(match.first);
      if (!initiated && !_disposed) {
        _setError('The premium purchase could not be started.');
      }
      return initiated;
    } catch (e, stack) {
      debugPrint('Guardian premium purchase failed: $e');
      debugPrintStack(stackTrace: stack);
      if (!_disposed) _setError(_friendlyError(e));
      return false;
    }
  }

  Future<bool> restorePurchases() async {
    if (_disposed) return false;

    _error = null;
    _safeNotify();

    try {
      final restored = await _iap.restorePurchases();
      if (restored && !_disposed) {
        await loadInsights();
      }
      return restored;
    } catch (e, stack) {
      debugPrint('Guardian purchase restoration failed: $e');
      debugPrintStack(stackTrace: stack);
      if (!_disposed) _setError(_friendlyError(e));
      return false;
    }
  }

  Future<void> openManageSubscriptions() async {
    if (_disposed) return;

    _error = null;

    try {
      await _iap.openManageSubscriptions();
    } catch (e, stack) {
      debugPrint('Guardian subscription management failed: $e');
      debugPrintStack(stackTrace: stack);
      if (!_disposed) _setError(_friendlyError(e));
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Session reset
  // ══════════════════════════════════════════════════════════════════════════

  /// Clears all user-specific state.
  ///
  /// Call on sign-out. Clears the singleton model buffers so the next
  /// signed-in user does not inherit the previous user's samples.
  void resetSession() {
    if (_disposed) return;

    _insights.clear();
    _currentHRV = null;
    _currentRhythm = null;
    _currentOxygenTrend = null;
    _currentTemperatureDeviation = null;
    _currentHrElevation = null;
    _error = null;

    _modelService.clearBuffers();

    _safeNotify();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Notify guard
  // ══════════════════════════════════════════════════════════════════════════

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Dispose
  // ══════════════════════════════════════════════════════════════════════════

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    _premiumSubscription?.cancel();
    _premiumSubscription = null;

    // Do NOT dispose _modelService — it is a shared singleton.
    // Buffers are cleared separately on sign-out via resetSession().

    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }

    super.dispose();
  }
}
