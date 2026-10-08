// ════════════════════════════════════════════════════════════════════════════
// lib/services/insight_model_service.dart
// ════════════════════════════════════════════════════════════════════════════
//
// Guardian Watch physiological insight engine.
//
// Everything in this file produces WELLNESS / ENGINEERING INDICATORS.
// Nothing here establishes a medical diagnosis.
//
// Rules enforced:
//   No output field is named "probability".
//   No method name claims a diagnosis.
//   The validated TFLite AFib model is used when its tensor contract
//    can be resolved from the interpreter. The engineering RR-
//    irregularity heuristic remains as a fallback so the app still
//    produces an indicator if the model asset is missing.
//   Hardware limits are documented where they constrain claims
//      (no airflow sensor → no apnea inference; wrist temp ≠ core temp).
//
// AFib MODEL
// ----------
// The asset `assets/models/afib_detection.tflite` is treated as validated.
// Inference expects:
//   Input:  a single ECG window, normalized per-window (z-score)
//   Output: either a softmax [normal, afib] vector, or a single sigmoid
//             score for AFib
// The exact shape is read at runtime from the interpreter, so the app
// stays compatible across model revisions.
// ════════════════════════════════════════════════════════════════════════════

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../config/constants.dart';
import '../models/health_metrics.dart';

// ════════════════════════════════════════════════════════════════════════════
// Internal helpers
// ════════════════════════════════════════════════════════════════════════════

class _Observation<T> {
  final T value;
  final DateTime timestamp;

  const _Observation({required this.value, required this.timestamp});
}

class _EcgPeak {
  final int sampleIndex;
  final double amplitude;

  const _EcgPeak({required this.sampleIndex, required this.amplitude});
}

// ════════════════════════════════════════════════════════════════════════════
// Insight model service
// ════════════════════════════════════════════════════════════════════════════

class InsightModelService {
  static final InsightModelService _instance = InsightModelService._internal();

  factory InsightModelService() => _instance;

  InsightModelService._internal();

  Interpreter? _afibInterpreter;

  bool _modelsLoaded = false;

  /// Tracks a load attempt so concurrent callers do not race the asset
  /// open. Reset to null on failure so a later call can retry.
  Future<void>? _loadingModels;

  bool get modelsLoaded => _modelsLoaded;

  bool get afibModelAvailable => _afibInterpreter != null;

  // ══════════════════════════════════════════════════════════════════════════
  // Configuration
  // ══════════════════════════════════════════════════════════════════════════

  static const double ecgSampleRate = AppConstants.ecgSampleRate;

  static const int maxRrIntervals = 300;

  // Sized for overnight tracking. At 1 Hz, 86_400 = 24 hours.
  static const int maxHeartRateHistory = 86400;
  static const int maxTemperatureHistory = 86400;
  static const int maxSpO2History = 86400;

  /// Working ECG buffer (30 seconds at 250 Hz).
  static const int maxEcgBufferSamples = AppConstants.maxEcgWorkingSamples;

  /// Overlap between adjacent packets so a peak split across a packet
  /// boundary is not lost.
  static const int peakDetectionOverlapSamples = 12;

  static const String _afibModelPath = 'assets/models/afib_detection.tflite';

  /// Minimum samples to attempt AFib inference (4 s at 250 Hz).
  static const int _minimumAfibSamples = 1000;

  /// Decision threshold on the model's AFib score.
  /// Locked to the value used during model validation.
  static const double _afibDecisionThreshold = 0.70;

  // ══════════════════════════════════════════════════════════════════════════
  // Buffers
  // ══════════════════════════════════════════════════════════════════════════

  final List<int> _rrIntervals = <int>[];

  final List<_Observation<int>> _heartRateHistory = <_Observation<int>>[];

  final List<_Observation<double>> _temperatureHistory =
      <_Observation<double>>[];

  final List<_Observation<int>> _spo2History = <_Observation<int>>[];

  final List<double> _ecgBuffer = <double>[];

  final List<double> _ecgDetectionTail = <double>[];

  DateTime? _ecgBufferStartTime;

  int? _lastRPeakSampleGlobal;

  int _nextGlobalEcgSampleIndex = 0;

  bool _disposed = false;

  // ══════════════════════════════════════════════════════════════════════════
  // Model loading
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> loadModels() async {
    if (_modelsLoaded || _afibInterpreter != null) {
      return;
    }

    // Deduplicate concurrent loads.
    final inFlight = _loadingModels;
    if (inFlight != null) {
      return inFlight;
    }

    final future = _loadModelsInternal();
    _loadingModels = future;

    try {
      await future;
    } finally {
      if (identical(_loadingModels, future)) {
        _loadingModels = null;
      }
    }
  }

  Future<void> _loadModelsInternal() async {
    try {
      final interpreter = await Interpreter.fromAsset(_afibModelPath);

      _afibInterpreter = interpreter;
      _modelsLoaded = true;

      final inputShape = interpreter.getInputTensor(0).shape;
      final inputType = interpreter.getInputTensor(0).type;
      final outputShape = interpreter.getOutputTensor(0).shape;

      debugPrint(
        'Guardian AFib model loaded. '
        'input: $inputShape ($inputType), output: $outputShape',
      );
    } catch (e, stack) {
      _afibInterpreter = null;
      _modelsLoaded = false;

      debugPrint('Guardian AFib model loading failed: $e');
      debugPrintStack(stackTrace: stack);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ECG ingestion
  // ══════════════════════════════════════════════════════════════════════════

  void addEcgSample(List<double> samples, {DateTime? timestamp}) {
    if (samples.isEmpty) {
      return;
    }

    final validSamples = samples
        .where((sample) => sample.isFinite)
        .toList(growable: false);

    if (validSamples.isEmpty) {
      return;
    }

    final packetStart = timestamp ?? DateTime.now();

    _ecgBufferStartTime ??= packetStart;

    final globalStart = _nextGlobalEcgSampleIndex;

    _ecgBuffer.addAll(validSamples);

    final tail = List<double>.from(_ecgDetectionTail);

    final combined = <double>[...tail, ...validSamples];

    final peaks = _detectRPeaks(combined);

    final tailLength = tail.length;

    for (final peak in peaks) {
      if (peak.sampleIndex < tailLength) {
        continue;
      }

      final localIndex = peak.sampleIndex - tailLength;

      final globalPeakIndex = globalStart + localIndex;

      _processRPeak(globalPeakIndex);
    }

    _nextGlobalEcgSampleIndex += validSamples.length;

    final overlapCount = math.min(peakDetectionOverlapSamples, combined.length);

    _ecgDetectionTail
      ..clear()
      ..addAll(combined.sublist(combined.length - overlapCount));

    if (_ecgBuffer.length > maxEcgBufferSamples) {
      final removeCount = _ecgBuffer.length - maxEcgBufferSamples;

      _ecgBuffer.removeRange(0, removeCount);

      if (_ecgBufferStartTime != null) {
        final removedDurationMs = (removeCount / ecgSampleRate * 1000).round();

        _ecgBufferStartTime = _ecgBufferStartTime!.add(
          Duration(milliseconds: removedDurationMs),
        );
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // R-peak processing
  // ══════════════════════════════════════════════════════════════════════════

  void _processRPeak(int globalSampleIndex) {
    final previous = _lastRPeakSampleGlobal;

    if (previous == null) {
      _lastRPeakSampleGlobal = globalSampleIndex;
      return;
    }

    final sampleDifference = globalSampleIndex - previous;

    if (sampleDifference <= 0) {
      return;
    }

    final rrMilliseconds = (sampleDifference / ecgSampleRate * 1000).round();

    if (rrMilliseconds >= 300 && rrMilliseconds <= 2000) {
      _rrIntervals.add(rrMilliseconds);

      if (_rrIntervals.length > maxRrIntervals) {
        _rrIntervals.removeAt(0);
      }
    }

    _lastRPeakSampleGlobal = globalSampleIndex;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ECG preprocessing / R-peak detection
  // ══════════════════════════════════════════════════════════════════════════

  List<_EcgPeak> _detectRPeaks(List<double> signal) {
    if (signal.length < 5) {
      return const [];
    }

    final filtered = _movingAverageDetrend(signal, window: 5);

    if (filtered.isEmpty) {
      return const [];
    }

    final maxAmplitude = filtered.reduce(math.max);
    final minAmplitude = filtered.reduce(math.min);
    final amplitudeRange = maxAmplitude - minAmplitude;

    if (!amplitudeRange.isFinite || amplitudeRange <= 0) {
      return const [];
    }

    final threshold = minAmplitude + amplitudeRange * 0.65;

    const minimumPeakDistance = 40;

    final peaks = <_EcgPeak>[];
    int? lastAcceptedIndex;

    for (var i = 1; i < filtered.length - 1; i++) {
      final current = filtered[i];

      if (current < threshold) {
        continue;
      }

      final isLocalMaximum =
          current > filtered[i - 1] && current >= filtered[i + 1];

      if (!isLocalMaximum) {
        continue;
      }

      if (lastAcceptedIndex != null &&
          i - lastAcceptedIndex < minimumPeakDistance) {
        if (peaks.isNotEmpty && current > peaks.last.amplitude) {
          peaks.removeLast();
          peaks.add(_EcgPeak(sampleIndex: i, amplitude: current));
          lastAcceptedIndex = i;
        }
        continue;
      }

      peaks.add(_EcgPeak(sampleIndex: i, amplitude: current));
      lastAcceptedIndex = i;
    }

    return peaks;
  }

  /// Sliding-window detrend
  List<double> _movingAverageDetrend(
    List<double> signal, {
    required int window,
  }) {
    if (signal.isEmpty || window <= 0) {
      return const [];
    }

    final n = signal.length;
    final output = List<double>.filled(n, 0);

    final prefix = List<double>.filled(n + 1, 0);
    for (var i = 0; i < n; i++) {
      prefix[i + 1] = prefix[i] + signal[i];
    }

    final half = window ~/ 2;

    for (var i = 0; i < n; i++) {
      final start = math.max(0, i - half);
      final end = math.min(n - 1, i + half);
      final count = end - start + 1;
      final sum = prefix[end + 1] - prefix[start];
      final baseline = count > 0 ? sum / count : 0.0;
      output[i] = signal[i] - baseline;
    }

    return output;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Ingestion
  // ══════════════════════════════════════════════════════════════════════════

  void addHeartRate(int heartRate, {DateTime? timestamp}) {
    if (heartRate < 20 || heartRate > 240) {
      return;
    }

    _heartRateHistory.add(
      _Observation<int>(
        value: heartRate,
        timestamp: timestamp ?? DateTime.now(),
      ),
    );

    if (_heartRateHistory.length > maxHeartRateHistory) {
      _heartRateHistory.removeAt(0);
    }
  }

  void addTemperature(double temperature, {DateTime? timestamp}) {
    if (!temperature.isFinite || temperature < 0 || temperature > 60) {
      return;
    }

    _temperatureHistory.add(
      _Observation<double>(
        value: temperature,
        timestamp: timestamp ?? DateTime.now(),
      ),
    );

    if (_temperatureHistory.length > maxTemperatureHistory) {
      _temperatureHistory.removeAt(0);
    }
  }

  void addSpO2(int spo2, {DateTime? timestamp}) {
    if (spo2 < 50 || spo2 > 100) {
      return;
    }

    _spo2History.add(
      _Observation<int>(value: spo2, timestamp: timestamp ?? DateTime.now()),
    );

    if (_spo2History.length > maxSpO2History) {
      _spo2History.removeAt(0);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // HRV
  // ══════════════════════════════════════════════════════════════════════════

  HRVMetrics computeHRV() {
    if (_rrIntervals.length < 30) {
      return _insufficientHrv();
    }

    final cleanRr = _rrIntervals
        .where((rr) => rr >= 300 && rr <= 2000)
        .toList();

    if (cleanRr.length < 30) {
      return _insufficientHrv();
    }

    final successiveDifferences = <double>[];

    for (var i = 1; i < cleanRr.length; i++) {
      successiveDifferences.add((cleanRr[i] - cleanRr[i - 1]).toDouble());
    }

    if (successiveDifferences.isEmpty) {
      return _insufficientHrv();
    }

    final squaredMean =
        successiveDifferences
            .map((diff) => diff * diff)
            .reduce((a, b) => a + b) /
        successiveDifferences.length;

    final rmssd = math.sqrt(squaredMean);

    final mean = cleanRr.reduce((a, b) => a + b) / cleanRr.length;

    if (!mean.isFinite || mean <= 0) {
      return _insufficientHrv();
    }

    final variance =
        cleanRr
            .map((rr) => math.pow(rr - mean, 2) as num)
            .reduce((a, b) => a + b) /
        cleanRr.length;

    final sdnn = math.sqrt(variance.toDouble());

    final stressScore = (100 - (rmssd / 80 * 100)).clamp(0.0, 100.0).toDouble();

    final stressLevel = stressScore < 30
        ? 'Low'
        : stressScore < 60
        ? 'Medium'
        : 'High';

    final recoveryStatus = rmssd > 50
        ? 'Excellent recovery'
        : rmssd > 35
        ? 'Good recovery'
        : rmssd > 25
        ? 'Normal recovery'
        : 'Poor recovery';

    return HRVMetrics(
      rmssd: rmssd,
      sdnn: sdnn,
      stressScore: stressScore,
      stressLevel: stressLevel,
      recoveryStatus: recoveryStatus,
    );
  }

  HRVMetrics _insufficientHrv() {
    return HRVMetrics(
      rmssd: 0,
      sdnn: 0,
      stressScore: 50,
      stressLevel: 'Insufficient data',
      recoveryStatus: 'Need more clean ECG data',
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Rhythm irregularity indicator (AFib research path)
  //
  // Pipeline:
  //   1. If the validated TFLite model is available → use it.
  //   2. Otherwise it fall back to the engineering RR-irregularity heuristic.
  //
  // Returns an ENGINEERING IRREGULARITY INDICATOR.
  //    NOT a probability of AFib.
  //    MUST NOT be shown to a user as a diagnosis.
  // ══════════════════════════════════════════════════════════════════════════

  Future<AFibResult> computeRhythmIrregularityIndicator(
    List<double> ecgSegment,
  ) async {
    final valid = ecgSegment.where((sample) => sample.isFinite).toList();

    if (valid.length < _minimumAfibSamples) {
      return const AFibResult(
        irregularityIndicator: 0,
        isSuspected: false,
        confidence: 'Insufficient data',
      );
    }

    // ── Model path ────────────────────────────────────────────────────────

    if (_afibInterpreter == null) {
      await loadModels();
    }

    final interpreter = _afibInterpreter;

    if (interpreter != null) {
      try {
        final modelResult = _runAfibModel(interpreter, valid);

        if (modelResult != null) {
          return modelResult;
        }
      } catch (e, stack) {
        debugPrint('AFib model inference failed: $e');
        debugPrintStack(stackTrace: stack);
      }
    }

    // ── Heuristic fallback ────────────────────────────────────────────────

    return _heuristicRhythmIrregularity(valid);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // TFLite inference
  // ══════════════════════════════════════════════════════════════════════════

  /// Runs the validated AFib TFLite model against a single ECG window.
  ///
  /// Returns null if the model contract cannot be satisfied or inference
  /// fails — in which case the caller falls back to the heuristic.
  AFibResult? _runAfibModel(Interpreter interpreter, List<double> ecgSegment) {
    // ── Inspect tensor contract ───────────────────────────────────────────

    final inputTensor = interpreter.getInputTensor(0);
    final inputShape = inputTensor.shape;

    // Support [1, N] and [1, N, 1].
    if (inputShape.length < 2) {
      debugPrint('AFib model: unsupported input rank ${inputShape.length}.');
      return null;
    }

    final expectedSamples = inputShape[1];
    if (expectedSamples <= 0) {
      debugPrint('AFib model: invalid input window $expectedSamples.');
      return null;
    }

    // ── Build the input window ────────────────────────────────────────────

    final window = _fitWindow(ecgSegment, expectedSamples);
    if (window == null) {
      return null;
    }

    // ── Normalize (per-window z-score) ────────────────────────────────────
    //
    // This must match the training pipeline. If you trained on min-max
    // normalized data, or on raw millivolts, change this method.

    final normalized = _zScoreNormalize(window);

    // ── Build nested-list input tensor ────────────────────────────────────

    final input = inputShape.length == 2
        ? [normalized] // shape [1, N]
        : [
            normalized.map((v) => [v]).toList(),
          ]; // shape [1, N, 1]

    // ── Allocate the output tensor ────────────────────────────────────────

    final outputTensor = interpreter.getOutputTensor(0);
    final outputShape = outputTensor.shape;

    final output = _allocateOutput(outputShape);
    if (output == null) {
      debugPrint('AFib model: unsupported output shape $outputShape.');
      return null;
    }

    // ── Inference ─────────────────────────────────────────────────────────

    interpreter.run(input, output);

    // ── Parse output ──────────────────────────────────────────────────────

    final score = _extractAfibScore(output, outputShape);
    if (score == null) {
      debugPrint('AFib model: could not extract score from $outputShape.');
      return null;
    }

    final clamped = score.clamp(0.0, 1.0).toDouble();
    final suspected = clamped >= _afibDecisionThreshold;

    return AFibResult(
      irregularityIndicator: clamped,
      isSuspected: suspected,
      confidence: 'Model',
    );
  }

  /// Fits [segment] to exactly [targetLength] samples.
  ///
  /// If more samples are available then take the most recent window.
  /// If fewer are available then center the signal and zero-pad.
  ///
  /// Returns null only if the target length is 0 or the segment is empty.
  List<double>? _fitWindow(List<double> segment, int targetLength) {
    if (segment.isEmpty || targetLength <= 0) {
      return null;
    }

    if (segment.length == targetLength) {
      return List<double>.from(segment);
    }

    if (segment.length > targetLength) {
      return segment.sublist(segment.length - targetLength);
    }

    // Zero-pad in the center.
    final missing = targetLength - segment.length;
    final leftPad = missing ~/ 2;
    final rightPad = missing - leftPad;

    return <double>[
      ...List<double>.filled(leftPad, 0.0),
      ...segment,
      ...List<double>.filled(rightPad, 0.0),
    ];
  }

  /// Per-window z-score normalization.
  ///
  /// Returns zeros for a constant signal so the model sees a stable input.
  List<double> _zScoreNormalize(List<double> window) {
    if (window.isEmpty) {
      return const [];
    }

    final n = window.length;

    var sum = 0.0;
    for (final v in window) {
      sum += v;
    }
    final mean = sum / n;

    var sqSum = 0.0;
    for (final v in window) {
      final d = v - mean;
      sqSum += d * d;
    }
    final variance = sqSum / n;
    final std = math.sqrt(variance);

    if (!std.isFinite || std < 1e-6) {
      return List<double>.filled(n, 0.0);
    }

    return window.map((v) => (v - mean) / std).toList();
  }

  /// Allocates a nested list matching the model's output shape.
  ///
  /// Supports [1], [1, 1], [1, 2], [2].
  List<dynamic>? _allocateOutput(List<int> shape) {
    switch (shape.length) {
      case 1:
        return List<double>.filled(shape[0], 0.0);

      case 2:
        return List.generate(
          shape[0],
          (_) => List<double>.filled(shape[1], 0.0),
        );

      default:
        return null;
    }
  }

  /// Extracts the AFib score from the model's output.
  ///
  /// Supported contracts:
  ///   • [1, 2] → softmax [normal, afib] → returns output[0][1]
  ///   • [2]    → flat version of the same
  ///   • [1, 1] → sigmoid → returns output[0][0]
  ///   • [1]    → flat version of the same
  double? _extractAfibScore(List<dynamic> output, List<int> shape) {
    try {
      if (shape.length == 2 && shape[0] == 1 && shape[1] == 2) {
        final row = output[0] as List<dynamic>;
        return (row[1] as num).toDouble();
      }

      if (shape.length == 1 && shape[0] == 2) {
        return (output[1] as num).toDouble();
      }

      if (shape.length == 2 && shape[0] == 1 && shape[1] == 1) {
        final row = output[0] as List<dynamic>;
        return (row[0] as num).toDouble();
      }

      if (shape.length == 1 && shape[0] == 1) {
        return (output[0] as num).toDouble();
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Heuristic fallback (RR irregularity)
  // ══════════════════════════════════════════════════════════════════════════

  AFibResult _heuristicRhythmIrregularity(List<double> valid) {
    final peaks = _detectRPeaks(valid);

    if (peaks.length < 5) {
      return const AFibResult(
        irregularityIndicator: 0,
        isSuspected: false,
        confidence: 'Insufficient data',
      );
    }

    final rrMilliseconds = <double>[];

    for (var i = 1; i < peaks.length; i++) {
      final sampleDifference = peaks[i].sampleIndex - peaks[i - 1].sampleIndex;

      if (sampleDifference <= 0) {
        continue;
      }

      final rr = sampleDifference / ecgSampleRate * 1000;

      if (rr >= 300 && rr <= 2000) {
        rrMilliseconds.add(rr);
      }
    }

    if (rrMilliseconds.length < 4) {
      return const AFibResult(
        irregularityIndicator: 0,
        isSuspected: false,
        confidence: 'Low',
      );
    }

    final mean = rrMilliseconds.reduce((a, b) => a + b) / rrMilliseconds.length;

    if (!mean.isFinite || mean <= 0) {
      return const AFibResult(
        irregularityIndicator: 0,
        isSuspected: false,
        confidence: 'Low',
      );
    }

    final variance =
        rrMilliseconds
            .map((rr) => math.pow(rr - mean, 2) as num)
            .reduce((a, b) => a + b) /
        rrMilliseconds.length;

    final standardDeviation = math.sqrt(variance.toDouble());

    final irregularityScore = (standardDeviation / mean)
        .clamp(0.0, 1.0)
        .toDouble();

    final indicator = ((irregularityScore - 0.10) / 0.30)
        .clamp(0.0, 1.0)
        .toDouble();

    final suspected = indicator >= _afibDecisionThreshold;

    return AFibResult(
      irregularityIndicator: indicator,
      isSuspected: suspected,
      confidence: 'Low',
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Oxygen desaturation trend
  // ══════════════════════════════════════════════════════════════════════════

  OxygenDesaturationTrend computeOxygenDesaturationTrend({
    Duration minimumDuration = const Duration(hours: 4),
  }) {
    if (_spo2History.length < 10) {
      return const OxygenDesaturationTrend(
        desaturationIndexProxy: 0,
        trendScore: 0,
        trendLevel: 'Insufficient data',
        recommendation:
            'Collect more overnight SpO₂ data before computing a trend.',
      );
    }

    final first = _spo2History.first.timestamp;
    final last = _spo2History.last.timestamp;
    final duration = last.difference(first);

    if (duration < minimumDuration) {
      return const OxygenDesaturationTrend(
        desaturationIndexProxy: 0,
        trendScore: 0,
        trendLevel: 'Insufficient data',
        recommendation: 'Collect at least several hours of overnight data.',
      );
    }

    final baselineCount = math.max(20, _spo2History.length ~/ 10);
    final baselineValues = _spo2History
        .take(baselineCount)
        .map((observation) => observation.value.toDouble())
        .toList();

    if (baselineValues.isEmpty) {
      return const OxygenDesaturationTrend(
        desaturationIndexProxy: 0,
        trendScore: 0,
        trendLevel: 'Insufficient data',
        recommendation: 'Insufficient oxygen data.',
      );
    }

    final baseline =
        baselineValues.reduce((a, b) => a + b) / baselineValues.length;

    var desaturationEvents = 0;
    var insideEvent = false;

    for (final observation in _spo2History) {
      final value = observation.value;

      if (value <= baseline - 3) {
        if (!insideEvent) {
          desaturationEvents++;
          insideEvent = true;
        }
      } else if (value >= baseline - 2) {
        insideEvent = false;
      }
    }

    final hours = duration.inMilliseconds / Duration.millisecondsPerHour;

    if (!hours.isFinite || hours <= 0) {
      return const OxygenDesaturationTrend(
        desaturationIndexProxy: 0,
        trendScore: 0,
        trendLevel: 'Insufficient data',
        recommendation: 'Insufficient recording duration.',
      );
    }

    final desaturationIndexProxy = desaturationEvents / hours;
    final trendScore = (desaturationIndexProxy / 30 * 100)
        .clamp(0.0, 100.0)
        .toDouble();

    final trendLevel = trendScore < 15
        ? 'Low'
        : trendScore < 40
        ? 'Medium'
        : 'High';

    final recommendation = trendScore < 15
        ? 'No strong overnight oxygen trend was identified in this recording.'
        : trendScore < 40
        ? 'A repeated overnight oxygen trend was observed. Continue monitoring. '
              'Discuss persistent patterns with a clinician.'
        : 'A repeated overnight oxygen trend was observed. Professional '
              'evaluation is appropriate if symptoms are present.';

    return OxygenDesaturationTrend(
      desaturationIndexProxy: desaturationIndexProxy,
      trendScore: trendScore,
      trendLevel: trendLevel,
      recommendation: recommendation,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Temperature deviation
  // ══════════════════════════════════════════════════════════════════════════

  FeverResult computeTemperatureDeviation({
    Duration baselineWindow = const Duration(hours: 24),
  }) {
    if (_temperatureHistory.isEmpty) {
      return const FeverResult(
        currentTemp: 0,
        baselineTemp: 0,
        deviationScore: 0,
        isSuspected: false,
        recommendation: 'No temperature data available.',
      );
    }

    final latest = _temperatureHistory.last;
    final now = latest.timestamp;
    final cutoff = now.subtract(baselineWindow);

    final baselineObservations = _temperatureHistory
        .where((observation) => !observation.timestamp.isBefore(cutoff))
        .toList();

    if (baselineObservations.length < 6) {
      return FeverResult(
        currentTemp: latest.value,
        baselineTemp: latest.value,
        deviationScore: 0,
        isSuspected: false,
        recommendation:
            'Collect more temperature data to establish a personal baseline.',
      );
    }

    final baselineValues =
        baselineObservations.map((observation) => observation.value).toList()
          ..sort();

    final baseline = _median(baselineValues);
    final current = latest.value;
    final deviation = current - baseline;

    final deviationScore = (deviation / 1.0).clamp(0.0, 1.0).toDouble();
    final suspected = deviation >= 0.6;

    return FeverResult(
      currentTemp: current,
      baselineTemp: baseline,
      deviationScore: deviationScore,
      isSuspected: suspected,
      recommendation: suspected
          ? 'Your temperature is elevated relative to your recent baseline. '
                'Continue monitoring and seek medical advice if you feel '
                'unwell or the elevation persists.'
          : 'No significant temperature elevation was identified.',
    );
  }

  double _median(List<double> values) {
    if (values.isEmpty) {
      return 0;
    }

    final middle = values.length ~/ 2;

    if (values.length.isOdd) {
      return values[middle];
    }

    return (values[middle - 1] + values[middle]) / 2;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Heart-rate elevation indicator
  // ══════════════════════════════════════════════════════════════════════════

  FatigueResult computeHeartRateElevationIndicator({double? sleepHours}) {
    if (_heartRateHistory.length < 7) {
      return const FatigueResult(
        fatigueScore: 0,
        readiness: 'Need more data',
        restingHrTrend: 'Collect more resting-heart-rate observations',
        recommendation:
            'Continue wearing Guardian Watch regularly so a personal trend '
            'can be established.',
      );
    }

    final latest = _heartRateHistory.last;
    final recentCount = math.min(7, _heartRateHistory.length);
    final baselineWindow = _heartRateHistory.sublist(
      _heartRateHistory.length - recentCount,
    );

    final baseline =
        baselineWindow
            .map((observation) => observation.value.toDouble())
            .reduce((a, b) => a + b) /
        baselineWindow.length;

    final hrIncrease = baseline > 0
        ? ((latest.value - baseline) / baseline) * 100
        : 0.0;

    var fatigueScore = (hrIncrease * 5).clamp(0.0, 100.0).toDouble();

    if (sleepHours != null && sleepHours.isFinite) {
      final sleepAdjustment = math.max(0.0, (7 - sleepHours) * 10);
      fatigueScore = (fatigueScore + sleepAdjustment)
          .clamp(0.0, 100.0)
          .toDouble();
    }

    final readiness = fatigueScore < 30
        ? 'High'
        : fatigueScore < 60
        ? 'Moderate'
        : 'Low';

    final recommendation = fatigueScore < 30
        ? 'Your recent heart-rate trend does not indicate a large fatigue '
              'signal. Continue your normal recovery routine.'
        : fatigueScore < 60
        ? 'Consider moderate activity and prioritize recovery.'
        : 'Prioritize recovery and monitor how you feel before '
              'strenuous exercise.';

    return FatigueResult(
      fatigueScore: fatigueScore,
      readiness: readiness,
      restingHrTrend: '${baseline.round()} → ${latest.value} bpm',
      recommendation: recommendation,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // State accessors
  // ══════════════════════════════════════════════════════════════════════════

  int get rrIntervalCount => _rrIntervals.length;
  int get heartRateObservationCount => _heartRateHistory.length;
  int get temperatureObservationCount => _temperatureHistory.length;
  int get spo2ObservationCount => _spo2History.length;
  int get ecgBufferSampleCount => _ecgBuffer.length;

  DateTime? get ecgBufferStartTime => _ecgBufferStartTime;
  List<double> get ecgBufferSnapshot => List.unmodifiable(_ecgBuffer);

  // ══════════════════════════════════════════════════════════════════════════
  // Selective buffer clearing
  // ══════════════════════════════════════════════════════════════════════════

  void clearEcgBuffers() {
    _rrIntervals.clear();
    _ecgBuffer.clear();
    _ecgDetectionTail.clear();
    _ecgBufferStartTime = null;
    _lastRPeakSampleGlobal = null;
    _nextGlobalEcgSampleIndex = 0;
  }

  void clearHeartRateHistory() => _heartRateHistory.clear();
  void clearTemperatureHistory() => _temperatureHistory.clear();
  void clearSpo2History() => _spo2History.clear();

  void clearBuffers() {
    clearEcgBuffers();
    clearHeartRateHistory();
    clearTemperatureHistory();
    clearSpo2History();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Dispose
  // ══════════════════════════════════════════════════════════════════════════

  void dispose() {
    if (_disposed) {
      return;
    }

    _disposed = true;

    try {
      _afibInterpreter?.close();
    } catch (_) {}

    _afibInterpreter = null;
    _modelsLoaded = false;

    clearBuffers();
  }
}
