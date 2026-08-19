// ─── lib/providers/insight_provider.dart ─────────────────────────────────────

import 'package:flutter/foundation.dart';
import '../models/health_metrics.dart';
import '../models/insight.dart';
import '../services/insight_model_service.dart';
import '../services/api_service.dart';
import '../services/iap_service.dart';

class InsightProvider extends ChangeNotifier {
  final ApiService _api = ApiService();
  final IAPService _iap;
  final InsightModelService _modelService = InsightModelService();

  List<Insight> _insights = [];
  bool _loading = false;
  bool _generating = false;
  String? _error;

  // Real-time metrics
  HRVMetrics? _currentHRV;
  AFibResult? _currentAFib;
  SleepApneaRisk? _currentSleepApnea;
  FeverResult? _currentFever;
  FatigueResult? _currentFatigue;

  InsightProvider(this._iap) {
    _iap.premiumStream.listen((_) {
      loadInsights();
    });
    _modelService.loadModels();
  }

  List<Insight> get insights => _insights;
  bool get isLoading => _loading;
  bool get isGenerating => _generating;
  String? get error => _error;
  bool get isPremium => _iap.isPremium;

  // Real-time metric getters
  HRVMetrics? get currentHRV => _currentHRV;
  AFibResult? get currentAFib => _currentAFib;
  SleepApneaRisk? get currentSleepApnea => _currentSleepApnea;
  FeverResult? get currentFever => _currentFever;
  FatigueResult? get currentFatigue => _currentFatigue;

  // Feed real-time ECG data to the model service
  void feedEcgData(List<double> ecgSamples) {
    _modelService.addEcgSample(ecgSamples);
  }

  void feedHeartRate(int hr) {
    _modelService.addHeartRate(hr);
  }

  void feedTemperature(double temp) {
    _modelService.addTemperature(temp);
  }

  void feedSpO2(int spo2) {
    _modelService.addSpO2(spo2);
  }

  // Update all real-time metrics
  void updateRealtimeMetrics() {
    _currentHRV = _modelService.computeHRV();
    notifyListeners();
  }

  Future<void> loadInsights() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _insights = await _api.fetchInsights();
      _updateRealtimeMetrics();
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void _updateRealtimeMetrics() {
    _currentHRV = _modelService.computeHRV();
    _currentSleepApnea = _modelService.computeSleepApneaRisk();
    _currentFever = _modelService.detectFever();
    _currentFatigue = _modelService.computeFatigue();
  }

  Future<void> generateDailyInsights() async {
    if (_generating) return;
    _generating = true;
    _error = null;
    notifyListeners();

    _updateRealtimeMetrics();

    final insightsList = <Insight>[];

    // Create insight cards from computed metrics
    if (_currentHRV != null && _currentHRV!.stressScore > 0) {
      insightsList.add(
        Insight(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          title: 'Stress & Recovery Report',
          summary:
              'Your HRV indicates ${_currentHRV!.stressLevel.toLowerCase()} stress.',
          detail:
              'Your heart rate variability (HRV) score is ${_currentHRV!.rmssd}ms. '
              'This places you in the ${_currentHRV!.recoveryStatus} category.\n\n'
              'High HRV means your nervous system is balanced and you\'re recovering well. '
              'Low HRV suggests stress, fatigue, or inadequate recovery.',
          severity: _currentHRV!.stressScore > 60
              ? InsightSeverity.warning
              : InsightSeverity.normal,
          isPremium: false,
          generatedAt: DateTime.now(),
          recommendation: _currentHRV!.stressScore > 60
              ? 'Try deep breathing exercises or meditation to lower stress.'
              : _currentHRV!.recoveryStatus == 'Excellent recovery'
              ? 'Great job! Your body is recovering well. Consider a challenging workout today.'
              : 'Get adequate sleep and take short breaks throughout the day.',
        ),
      );
    }

    if (_currentSleepApnea != null) {
      insightsList.add(
        Insight(
          id: DateTime.now().millisecondsSinceEpoch.toString() + '_apnea',
          title: 'Sleep Apnea Risk Assessment',
          summary:
              'Your ODI is ${_currentSleepApnea!.odi}. Risk level: ${_currentSleepApnea!.riskLevel}.',
          detail:
              'The Oxygen Desaturation Index (ODI) measures how many times per hour '
              'your blood oxygen drops by 3% or more.\n\n'
              'ODI < 5: Normal\n'
              'ODI 5-15: Mild sleep apnea\n'
              'ODI 15-30: Moderate sleep apnea\n'
              'ODI > 30: Severe sleep apnea',
          severity: _currentSleepApnea!.riskScore > 40
              ? InsightSeverity.warning
              : InsightSeverity.normal,
          isPremium: true,
          generatedAt: DateTime.now(),
          recommendation: _currentSleepApnea!.recommendation,
        ),
      );
    }

    if (_currentFever != null && _currentFever!.isSuspected) {
      insightsList.add(
        Insight(
          id: DateTime.now().millisecondsSinceEpoch.toString() + '_fever',
          title: 'Possible Fever Detected',
          summary:
              'Your temperature has risen ${(_currentFever!.currentTemp - _currentFever!.baselineTemp).toStringAsFixed(1)}°C above baseline.',
          detail:
              'Your current temperature is ${_currentFever!.currentTemp}°C, '
              'compared to your baseline of ${_currentFever!.baselineTemp}°C.\n\n'
              'A sustained elevation in temperature combined with elevated heart rate '
              'may indicate an infection or inflammatory response.',
          severity: InsightSeverity.warning,
          isPremium: false,
          generatedAt: DateTime.now(),
          recommendation: _currentFever!.recommendation,
        ),
      );
    }

    if (_currentFatigue != null) {
      insightsList.add(
        Insight(
          id: DateTime.now().millisecondsSinceEpoch.toString() + '_fatigue',
          title: 'Readiness to Train',
          summary: 'Readiness: ${_currentFatigue!.readiness}',
          detail:
              'Your fatigue score is ${_currentFatigue!.fatigueScore}/100.\n\n'
              'This is based on your resting heart rate trend (${_currentFatigue!.restingHrTrend}) '
              'and sleep quality.\n\n'
              'A low fatigue score means you\'re well-rested and ready for high-intensity activity. '
              'A high score suggests you need more recovery.',
          severity: _currentFatigue!.fatigueScore > 60
              ? InsightSeverity.warning
              : InsightSeverity.normal,
          isPremium: _currentFatigue!.fatigueScore > 60 ? false : true,
          generatedAt: DateTime.now(),
          recommendation: _currentFatigue!.recommendation,
        ),
      );
    }

    _insights = [...insightsList, ..._insights];
    _generating = false;
    notifyListeners();

    // Save to backend
    try {
      await _api.saveInsights(insightsList);
    } catch (e) {
      print('Failed to save insights: $e');
    }
  }

  Future<void> detectAFibFromSegment(List<double> ecgSegment) async {
    _currentAFib = await _modelService.detectAFib(ecgSegment);
    if (_currentAFib!.isSuspected) {
      // Create an AFib insight
      final afibInsight = Insight(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: 'Irregular Heart Rhythm Detected',
        summary: 'Possible atrial fibrillation (AFib) detected.',
        detail:
            'Our AI analysis of your ECG detected an irregular rhythm pattern '
            'that may indicate atrial fibrillation.\n\n'
            'AFib is a quivering or irregular heartbeat that can lead to blood clots, '
            'stroke, and other heart complications.\n\n'
            'This is not a medical diagnosis. Please consult your doctor.',
        severity: InsightSeverity.warning,
        isPremium: true,
        generatedAt: DateTime.now(),
        recommendation:
            'Schedule an appointment with your healthcare provider for a proper ECG.',
      );
      _insights.insert(0, afibInsight);
      notifyListeners();
    }
  }

  Future<bool> purchase(String productId) async {
    try {
      final products = await _iap.fetchProducts();
      final product = products.firstWhere((p) => p.id == productId);
      final success = await _iap.purchase(product);
      if (success) await loadInsights();
      return success;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> restorePurchases() async {
    try {
      final restored = await _iap.restorePurchases();
      if (restored) await loadInsights();
      return restored;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<void> openManageSubscriptions() async {
    await _iap.openManageSubscriptions();
  }

  @override
  void dispose() {
    _modelService.dispose();
    super.dispose();
  }
}
