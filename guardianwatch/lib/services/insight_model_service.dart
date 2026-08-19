// ─── lib/services/insight_model_service.dart ─────────────────────────────────

import 'dart:math';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import '../models/health_metrics.dart';

class InsightModelService {
  static final InsightModelService _instance = InsightModelService._internal();
  factory InsightModelService() => _instance;
  InsightModelService._internal();

  Interpreter? _afibInterpreter;
  bool _isLoaded = false;

  // Rolling buffers for historical data
  final List<int> _rrIntervals = [];
  final List<int> _restingHrHistory = [];
  final List<double> _temperatureHistory = [];
  final List<int> _spo2History = [];
  int? _lastPeakTime;

  Future<void> loadModels() async {
    try {
      // Load TFLite model (optional - if file exists)
      final model = await _loadModel('assets/models/afib_detection.tflite');
      if (model != null) {
        _afibInterpreter = model;
      }
      _isLoaded = true;
      print('Insight models loaded');
    } catch (e) {
      print('Models not available: $e');
      _isLoaded = false;
    }
  }

  Future<Interpreter?> _loadModel(String path) async {
    try {
      return await Interpreter.fromAsset(path);
    } catch (e) {
      print('Model not found at $path, using rule-based fallback');
      return null;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // ECG Data Processing (RR intervals from raw ECG)
  // ──────────────────────────────────────────────────────────────────────────

  void addEcgSample(List<double> ecgSamples) {
    final peaks = _detectRPeaks(ecgSamples);
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final peak in peaks) {
      if (_lastPeakTime != null) {
        final rr = now - _lastPeakTime!;
        if (rr > 300 && rr < 1500) {
          // Valid RR interval (0.3-1.5 sec)
          _rrIntervals.add(rr);
          if (_rrIntervals.length > 300) _rrIntervals.removeAt(0);
        }
      }
      _lastPeakTime = now;
    }
  }

  List<int> _detectRPeaks(List<double> signal) {
    final peaks = <int>[];
    if (signal.isEmpty) return peaks;

    final threshold = signal.reduce(max) * 0.6;

    for (int i = 1; i < signal.length - 1; i++) {
      if (signal[i] > threshold &&
          signal[i] > signal[i - 1] &&
          signal[i] > signal[i + 1]) {
        peaks.add(i);
      }
    }
    return peaks;
  }

  void addHeartRate(int hr) {
    _restingHrHistory.add(hr);
    if (_restingHrHistory.length > 30) _restingHrHistory.removeAt(0);
  }

  void addTemperature(double temp) {
    _temperatureHistory.add(temp);
    if (_temperatureHistory.length > 48)
      _temperatureHistory.removeAt(0); // 24h at 30min intervals
  }

  void addSpO2(int spo2) {
    _spo2History.add(spo2);
    if (_spo2History.length > 500) _spo2History.removeAt(0);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Insight 1: HRV & Stress Score
  // ──────────────────────────────────────────────────────────────────────────

  HRVMetrics computeHRV() {
    if (_rrIntervals.length < 30) {
      return HRVMetrics(
        rmssd: 0,
        sdnn: 0,
        stressScore: 50,
        stressLevel: 'Insufficient data',
        recoveryStatus: 'Need more ECG data',
      );
    }

    // Compute RMSSD
    final diffs = <int>[];
    for (int i = 1; i < _rrIntervals.length; i++) {
      diffs.add((_rrIntervals[i] - _rrIntervals[i - 1]).abs());
    }
    final rmssd = sqrt(
      diffs.map((d) => d * d).reduce((a, b) => a + b) / diffs.length,
    );

    // Compute SDNN
    final mean = _rrIntervals.reduce((a, b) => a + b) / _rrIntervals.length;
    final sdnn = sqrt(
      _rrIntervals.map((x) => pow(x - mean, 2)).reduce((a, b) => a + b) /
          _rrIntervals.length,
    );

    // Stress score (higher RMSSD = lower stress)
    double stressScore = (100 - (rmssd / 80 * 100)).clamp(0.0, 100.0);

    String stressLevel;
    if (stressScore < 30)
      stressLevel = 'Low';
    else if (stressScore < 60)
      stressLevel = 'Medium';
    else
      stressLevel = 'High';

    String recoveryStatus;
    if (rmssd > 50)
      recoveryStatus = 'Excellent recovery';
    else if (rmssd > 35)
      recoveryStatus = 'Good recovery';
    else if (rmssd > 25)
      recoveryStatus = 'Normal recovery';
    else
      recoveryStatus = 'Poor recovery';

    return HRVMetrics(
      rmssd: rmssd.roundToDouble(),
      sdnn: sdnn.roundToDouble(),
      stressScore: stressScore.roundToDouble(),
      stressLevel: stressLevel,
      recoveryStatus: recoveryStatus,
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Insight 2: Atrial Fibrillation Detection
  // ──────────────────────────────────────────────────────────────────────────

  Future<AFibResult> detectAFib(List<double> ecgSegment) async {
    // Rule-based fallback when ML model is not available
    final rrDiffs = <int>[];
    final peaks = _detectRPeaks(ecgSegment);

    for (int i = 1; i < peaks.length; i++) {
      rrDiffs.add(peaks[i] - peaks[i - 1]);
    }

    if (rrDiffs.isEmpty) {
      return AFibResult(probability: 0, isSuspected: false, confidence: 'Low');
    }

    // Irregularity metric: coefficient of variation
    final mean = rrDiffs.reduce((a, b) => a + b) / rrDiffs.length;
    final variance =
        rrDiffs.map((x) => pow(x - mean, 2)).reduce((a, b) => a + b) /
        rrDiffs.length;
    final cv = sqrt(variance) / mean;

    // High variability > 0.25 suggests possible AFib
    double probability = ((cv - 0.15) / 0.2).clamp(0.0, 1.0);

    return AFibResult(
      probability: probability,
      isSuspected: probability > 0.5,
      confidence: probability > 0.7 ? 'Medium' : 'Low',
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Insight 3: Sleep Apnea Risk (Oxygen Desaturation Index)
  // ──────────────────────────────────────────────────────────────────────────

  SleepApneaRisk computeSleepApneaRisk({int age = 30, double bmi = 24}) {
    if (_spo2History.isEmpty) {
      return SleepApneaRisk(
        odi: 0,
        riskScore: 0,
        riskLevel: 'Insufficient data',
        recommendation:
            'Wear your watch while sleeping to get sleep apnea analysis.',
      );
    }

    final baseline = _spo2History.take(20).reduce((a, b) => a + b) / 20;
    int desaturations = 0;
    int i = 0;

    while (i < _spo2History.length) {
      if (_spo2History[i] < baseline - 3) {
        desaturations++;
        while (i < _spo2History.length && _spo2History[i] < baseline - 2) i++;
      }
      i++;
    }

    final hours = _spo2History.length / 3600.0; // Assume 1Hz
    final odi = desaturations / hours;

    double riskScore = (odi / 30 * 100).clamp(0.0, 100.0);

    String riskLevel;
    String recommendation;
    if (riskScore < 15) {
      riskLevel = 'Low';
      recommendation = 'Your sleep breathing appears normal.';
    } else if (riskScore < 40) {
      riskLevel = 'Medium';
      recommendation =
          'Consider sleeping on your side and maintaining a healthy weight.';
    } else {
      riskLevel = 'High';
      recommendation = 'Consult a doctor about a sleep study.';
    }

    return SleepApneaRisk(
      odi: odi.roundToDouble(),
      riskScore: riskScore.roundToDouble(),
      riskLevel: riskLevel,
      recommendation: recommendation,
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Insight 4: Fever / Infection Detection
  // ──────────────────────────────────────────────────────────────────────────

  FeverResult detectFever() {
    if (_temperatureHistory.length < 24) {
      return FeverResult(
        currentTemp: 0,
        baselineTemp: 0,
        probability: 0,
        isSuspected: false,
        recommendation: 'Need 24 hours of temperature data.',
      );
    }

    final baseline = _temperatureHistory.take(24).reduce((a, b) => a + b) / 24;
    final current = _temperatureHistory.last;
    final deviation = current - baseline;

    double probability = (deviation / 0.5).clamp(0.0, 1.0);
    final isSuspected = probability > 0.6;

    return FeverResult(
      currentTemp: current,
      baselineTemp: baseline,
      probability: probability,
      isSuspected: isSuspected,
      recommendation: isSuspected
          ? 'Rest, hydrate, and monitor your temperature. Consult a doctor if it persists.'
          : 'Your temperature is within normal range.',
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Insight 5: Fatigue / Overtraining Monitor
  // ──────────────────────────────────────────────────────────────────────────

  FatigueResult computeFatigue({double sleepHours = 7}) {
    if (_restingHrHistory.length < 7) {
      return FatigueResult(
        fatigueScore: 0,
        readiness: 'Need more data',
        restingHrTrend: 'Collect 7 days of resting HR',
        recommendation:
            'Wear your watch while sleeping to track resting heart rate.',
      );
    }

    final baseline = _restingHrHistory.take(3).reduce((a, b) => a + b) / 3;
    final current = _restingHrHistory.last;
    final hrIncrease = ((current - baseline) / baseline) * 100;

    double fatigueScore = (hrIncrease * 5).clamp(0.0, 100.0);

    // Adjust for sleep
    final sleepAdjustment = max(0.0, (7 - sleepHours) * 10);
    fatigueScore = (fatigueScore + sleepAdjustment).clamp(0.0, 100.0);

    String readiness;
    String recommendation;
    if (fatigueScore < 30) {
      readiness = 'High - Ready for intense workout';
      recommendation = 'Great recovery! You\'re ready for peak performance.';
    } else if (fatigueScore < 60) {
      readiness = 'Moderate - Light exercise recommended';
      recommendation =
          'Take it easy today. A light walk or stretching is ideal.';
    } else {
      readiness = 'Low - Rest day recommended';
      recommendation = 'Prioritize sleep and recovery. Your body needs rest.';
    }

    return FatigueResult(
      fatigueScore: fatigueScore.roundToDouble(),
      readiness: readiness,
      restingHrTrend: '${baseline.round()} → ${current.round()} bpm',
      recommendation: recommendation,
    );
  }

  void clearBuffers() {
    _rrIntervals.clear();
    _restingHrHistory.clear();
    _temperatureHistory.clear();
    _spo2History.clear();
    _lastPeakTime = null;
  }

  void dispose() {
    _afibInterpreter?.close();
  }
}

/*
import 'dart:math';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import '../models/health_metrics.dart';

class InsightModelService {
  static final InsightModelService _instance = InsightModelService._internal();
  factory InsightModelService() => _instance;
  InsightModelService._internal();

  Interpreter? _afibInterpreter;
  bool _isModelLoaded = false;
  bool _isLoading = false;

  // Rolling buffers for historical data
  final List<int> _rrIntervals = [];
  final List<int> _restingHrHistory = [];
  final List<double> _temperatureHistory = [];
  final List<int> _spo2History = [];
  int? _lastPeakTime;

  // For AFib model: buffer of raw ECG samples (last 512 points)
  final List<double> _ecgBuffer = [];
  static const int _ecgBufferSize = 512;
  double _lastAfibProbability = 0.0;
  DateTime _lastAfibCheck = DateTime.now();

  Future<void> loadModels() async {
    if (_isLoading || _isModelLoaded) return;
    _isLoading = true;
    try {
      // Try to load TFLite model from assets
      _afibInterpreter = await Interpreter.fromAsset('assets/models/afib_detection.tflite');
      _isModelLoaded = true;
      print('✅ AFib detection model loaded');
    } catch (e) {
      print('⚠️ Model not available: $e. Using rule-based fallback.');
      _isModelLoaded = false;
    } finally {
      _isLoading = false;
    }
  }

  // Add a raw ECG sample (for ML model)
  void addEcgSample(List<double> ecgSamples) {
    // Add to rolling buffer
    _ecgBuffer.addAll(ecgSamples);
    while (_ecgBuffer.length > _ecgBufferSize) {
      _ecgBuffer.removeAt(0);
    }

    // Also detect R peaks for RR intervals (used by rule-based fallback and HRV)
    final peaks = _detectRPeaks(ecgSamples);
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final peak in peaks) {
      if (_lastPeakTime != null) {
        final rr = now - _lastPeakTime!;
        if (rr > 300 && rr < 1500) {
          _rrIntervals.add(rr);
          if (_rrIntervals.length > 300) _rrIntervals.removeAt(0);
        }
      }
      _lastPeakTime = now;
    }

    // Periodic AFib check using ML model if enough data
    final nowTime = DateTime.now();
    if (_isModelLoaded && _ecgBuffer.length >= _ecgBufferSize &&
        nowTime.difference(_lastAfibCheck).inSeconds > 10) {
      _runAfibModel();
      _lastAfibCheck = nowTime;
    }
  }

  Future<void> _runAfibModel() async {
    if (_afibInterpreter == null || _ecgBuffer.length < _ecgBufferSize) return;
    try {
      // Prepare input tensor: shape [1, 512, 1]
      final input = List.generate(1, (_) => List.generate(_ecgBufferSize, (i) => [_ecgBuffer[i]]));
      final output = List.filled(1, List.filled(2, 0.0)); // assuming 2 classes: normal, AFib

      _afibInterpreter!.run(input, output);
      // Output probability of AFib (second class)
      _lastAfibProbability = output[0][1];
    } catch (e) {
      print('AFib model inference failed: $e');
      _lastAfibProbability = 0.0;
    }
  }

  List<int> _detectRPeaks(List<double> signal) {
    final peaks = <int>[];
    if (signal.isEmpty) return peaks;

    // Simple threshold-based peak detection
    final maxVal = signal.reduce(max);
    final threshold = maxVal * 0.6;

    for (int i = 1; i < signal.length - 1; i++) {
      if (signal[i] > threshold &&
          signal[i] > signal[i - 1] &&
          signal[i] > signal[i + 1]) {
        peaks.add(i);
      }
    }
    return peaks;
  }

  void addHeartRate(int hr) {
    _restingHrHistory.add(hr);
    if (_restingHrHistory.length > 30) _restingHrHistory.removeAt(0);
  }

  void addTemperature(double temp) {
    _temperatureHistory.add(temp);
    if (_temperatureHistory.length > 48) _temperatureHistory.removeAt(0);
  }

  void addSpO2(int spo2) {
    _spo2History.add(spo2);
    if (_spo2History.length > 500) _spo2History.removeAt(0);
  }

  // HRV & Stress Score (unchanged, but uses _rrIntervals)
  HRVMetrics computeHRV() {
    if (_rrIntervals.length < 30) {
      return HRVMetrics(
        rmssd: 0,
        sdnn: 0,
        stressScore: 50,
        stressLevel: 'Insufficient data',
        recoveryStatus: 'Need more ECG data',
      );
    }

    // Compute RMSSD
    final diffs = <int>[];
    for (int i = 1; i < _rrIntervals.length; i++) {
      diffs.add((_rrIntervals[i] - _rrIntervals[i - 1]).abs());
    }
    final rmssd = sqrt(diffs.map((d) => d * d).reduce((a, b) => a + b) / diffs.length);

    // Compute SDNN
    final mean = _rrIntervals.reduce((a, b) => a + b) / _rrIntervals.length;
    final sdnn = sqrt(_rrIntervals.map((x) => pow(x - mean, 2)).reduce((a, b) => a + b) / _rrIntervals.length);

    // Stress score (higher RMSSD = lower stress)
    double stressScore = (100 - (rmssd / 80 * 100)).clamp(0.0, 100.0);

    String stressLevel;
    if (stressScore < 30) stressLevel = 'Low';
    else if (stressScore < 60) stressLevel = 'Medium';
    else stressLevel = 'High';

    String recoveryStatus;
    if (rmssd > 50) recoveryStatus = 'Excellent recovery';
    else if (rmssd > 35) recoveryStatus = 'Good recovery';
    else if (rmssd > 25) recoveryStatus = 'Normal recovery';
    else recoveryStatus = 'Poor recovery';

    return HRVMetrics(
      rmssd: rmssd.roundToDouble(),
      sdnn: sdnn.roundToDouble(),
      stressScore: stressScore.roundToDouble(),
      stressLevel: stressLevel,
      recoveryStatus: recoveryStatus,
    );
  }

  // AFib Detection – uses ML model if available, otherwise rule-based
  Future<AFibResult> detectAFib(List<double> ecgSegment) async {
    // If ML model is loaded and we have enough data, use its latest probability
    if (_isModelLoaded && _ecgBuffer.length >= _ecgBufferSize) {
      // Use the periodically computed probability
      double probability = _lastAfibProbability;
      bool isSuspected = probability > 0.5;
      String confidence = probability > 0.8 ? 'High' : (probability > 0.6 ? 'Medium' : 'Low');
      return AFibResult(
        probability: probability,
        isSuspected: isSuspected,
        confidence: confidence,
      );
    }

    // Fallback: rule-based using RR interval variability (coefficient of variation)
    final peaks = _detectRPeaks(ecgSegment);
    final rrDiffs = <int>[];
    for (int i = 1; i < peaks.length; i++) {
      rrDiffs.add(peaks[i] - peaks[i - 1]);
    }

    if (rrDiffs.isEmpty) {
      return AFibResult(probability: 0.0, isSuspected: false, confidence: 'Low');
    }

    final mean = rrDiffs.reduce((a, b) => a + b) / rrDiffs.length;
    final variance = rrDiffs.map((x) => pow(x - mean, 2)).reduce((a, b) => a + b) / rrDiffs.length;
    final cv = sqrt(variance) / mean;

    double probability = ((cv - 0.15) / 0.2).clamp(0.0, 1.0);
    return AFibResult(
      probability: probability,
      isSuspected: probability > 0.5,
      confidence: probability > 0.7 ? 'Medium' : 'Low',
    );
  }

  // Sleep Apnea Risk (unchanged)
  SleepApneaRisk computeSleepApneaRisk({int age = 30, double bmi = 24}) {
    if (_spo2History.isEmpty) {
      return SleepApneaRisk(
        odi: 0,
        riskScore: 0,
        riskLevel: 'Insufficient data',
        recommendation: 'Wear your watch while sleeping to get sleep apnea analysis.',
      );
    }

    final baseline = _spo2History.take(20).reduce((a, b) => a + b) / 20;
    int desaturations = 0;
    int i = 0;

    while (i < _spo2History.length) {
      if (_spo2History[i] < baseline - 3) {
        desaturations++;
        while (i < _spo2History.length && _spo2History[i] < baseline - 2) i++;
      }
      i++;
    }

    final hours = _spo2History.length / 3600.0;
    final odi = desaturations / hours;
    double riskScore = (odi / 30 * 100).clamp(0.0, 100.0);

    String riskLevel;
    String recommendation;
    if (riskScore < 15) {
      riskLevel = 'Low';
      recommendation = 'Your sleep breathing appears normal.';
    } else if (riskScore < 40) {
      riskLevel = 'Medium';
      recommendation = 'Consider sleeping on your side and maintaining a healthy weight.';
    } else {
      riskLevel = 'High';
      recommendation = 'Consult a doctor about a sleep study.';
    }

    return SleepApneaRisk(
      odi: odi.roundToDouble(),
      riskScore: riskScore.roundToDouble(),
      riskLevel: riskLevel,
      recommendation: recommendation,
    );
  }

  // Fever detection (unchanged)
  FeverResult detectFever() {
    if (_temperatureHistory.length < 24) {
      return FeverResult(
        currentTemp: 0,
        baselineTemp: 0,
        probability: 0,
        isSuspected: false,
        recommendation: 'Need 24 hours of temperature data.',
      );
    }

    final baseline = _temperatureHistory.take(24).reduce((a, b) => a + b) / 24;
    final current = _temperatureHistory.last;
    final deviation = current - baseline;

    double probability = (deviation / 0.5).clamp(0.0, 1.0);
    final isSuspected = probability > 0.6;

    return FeverResult(
      currentTemp: current,
      baselineTemp: baseline,
      probability: probability,
      isSuspected: isSuspected,
      recommendation: isSuspected
          ? 'Rest, hydrate, and monitor your temperature. Consult a doctor if it persists.'
          : 'Your temperature is within normal range.',
    );
  }

  // Fatigue (unchanged)
  FatigueResult computeFatigue({double sleepHours = 7}) {
    if (_restingHrHistory.length < 7) {
      return FatigueResult(
        fatigueScore: 0,
        readiness: 'Need more data',
        restingHrTrend: 'Collect 7 days of resting HR',
        recommendation: 'Wear your watch while sleeping to track resting heart rate.',
      );
    }

    final baseline = _restingHrHistory.take(3).reduce((a, b) => a + b) / 3;
    final current = _restingHrHistory.last;
    final hrIncrease = ((current - baseline) / baseline) * 100;

    double fatigueScore = (hrIncrease * 5).clamp(0.0, 100.0);
    final sleepAdjustment = max(0.0, (7 - sleepHours) * 10);
    fatigueScore = (fatigueScore + sleepAdjustment).clamp(0.0, 100.0);

    String readiness;
    String recommendation;
    if (fatigueScore < 30) {
      readiness = 'High - Ready for intense workout';
      recommendation = 'Great recovery! You\'re ready for peak performance.';
    } else if (fatigueScore < 60) {
      readiness = 'Moderate - Light exercise recommended';
      recommendation = 'Take it easy today. A light walk or stretching is ideal.';
    } else {
      readiness = 'Low - Rest day recommended';
      recommendation = 'Prioritize sleep and recovery. Your body needs rest.';
    }

    return FatigueResult(
      fatigueScore: fatigueScore.roundToDouble(),
      readiness: readiness,
      restingHrTrend: '${baseline.round()} → ${current.round()} bpm',
      recommendation: recommendation,
    );
  }

  void clearBuffers() {
    _rrIntervals.clear();
    _restingHrHistory.clear();
    _temperatureHistory.clear();
    _spo2History.clear();
    _ecgBuffer.clear();
    _lastPeakTime = null;
    _lastAfibProbability = 0.0;
  }

  void dispose() {
    _afibInterpreter?.close();
  }
}
*/
