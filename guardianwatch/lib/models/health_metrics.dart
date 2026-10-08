// ─── lib/models/health_metrics.dart ──────────────────────────────────────────
//
//
// These classes carry WELLNESS / ENGINEERING INDICATORS.
// Nothing here is a clinical measurement or diagnosis.
//
// ─────────────────────────────────────────────────────────────────────────────

// ── Coercion helpers ────────────────────────────────────────────────────────

double _toDouble(dynamic value, [double fallback = 0.0]) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

bool _toBool(dynamic value, [bool fallback = false]) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'true' || normalized == '1';
  }
  return fallback;
}

DateTime? _toDateTimeOrNull(dynamic value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value)?.toLocal();
  return null;
}

String _toStringOr(dynamic value, String fallback) {
  final s = value?.toString();
  if (s == null || s.isEmpty) return fallback;
  return s;
}

// ─────────────────────────────────────────────────────────────────────────────
// Overall Health Metrics — point-in-time wellness snapshot
// ─────────────────────────────────────────────────────────────────────────────

class HealthMetrics {
  final String? id;

  final double hrvScore;
  final double stressLevel;

  /// Engineering trend score (0–100) derived from overnight SpO₂.
  /// NOT a clinical OSA risk score.
  final double oxygenDesaturationTrend;

  final double fatigueIndex;

  /// True when the ECG rhythm-irregularity indicator crossed the
  /// configured screening threshold. This is NOT a diagnosis.
  final bool rhythmIrregularityFlag;

  /// True when skin temperature deviated from the personal baseline
  /// beyond the configured threshold. This is NOT a fever diagnosis.
  final bool temperatureElevationFlag;

  final DateTime computedAt;

  final String? algorithmVersion;
  final String? deviceId;

  const HealthMetrics({
    this.id,
    required this.hrvScore,
    required this.stressLevel,
    required this.oxygenDesaturationTrend,
    required this.fatigueIndex,
    required this.rhythmIrregularityFlag,
    required this.temperatureElevationFlag,
    required this.computedAt,
    this.algorithmVersion,
    this.deviceId,
  });

  HealthMetrics copyWith({
    String? id,
    double? hrvScore,
    double? stressLevel,
    double? oxygenDesaturationTrend,
    double? fatigueIndex,
    bool? rhythmIrregularityFlag,
    bool? temperatureElevationFlag,
    DateTime? computedAt,
    String? algorithmVersion,
    String? deviceId,
  }) {
    return HealthMetrics(
      id: id ?? this.id,
      hrvScore: hrvScore ?? this.hrvScore,
      stressLevel: stressLevel ?? this.stressLevel,
      oxygenDesaturationTrend:
          oxygenDesaturationTrend ?? this.oxygenDesaturationTrend,
      fatigueIndex: fatigueIndex ?? this.fatigueIndex,
      rhythmIrregularityFlag:
          rhythmIrregularityFlag ?? this.rhythmIrregularityFlag,
      temperatureElevationFlag:
          temperatureElevationFlag ?? this.temperatureElevationFlag,
      computedAt: computedAt ?? this.computedAt,
      algorithmVersion: algorithmVersion ?? this.algorithmVersion,
      deviceId: deviceId ?? this.deviceId,
    );
  }

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'hrv_score': hrvScore,
    'stress_level': stressLevel,
    'oxygen_desaturation_trend': oxygenDesaturationTrend,
    'fatigue_index': fatigueIndex,
    'rhythm_irregularity_flag': rhythmIrregularityFlag,
    'temperature_elevation_flag': temperatureElevationFlag,
    'computed_at': computedAt.toUtc().toIso8601String(),
    if (algorithmVersion != null) 'algorithm_version': algorithmVersion,
    if (deviceId != null) 'device_id': deviceId,
  };

  factory HealthMetrics.fromJson(Map<String, dynamic> json) {
    return HealthMetrics(
      id: json['id'] as String?,
      hrvScore: _toDouble(json['hrv_score']),
      stressLevel: _toDouble(json['stress_level']),
      oxygenDesaturationTrend: _toDouble(json['oxygen_desaturation_trend']),
      fatigueIndex: _toDouble(json['fatigue_index']),
      rhythmIrregularityFlag: _toBool(json['rhythm_irregularity_flag']),
      temperatureElevationFlag: _toBool(json['temperature_elevation_flag']),
      computedAt: _toDateTimeOrNull(json['computed_at']) ?? DateTime.now(),
      algorithmVersion: json['algorithm_version'] as String?,
      deviceId: json['device_id'] as String?,
    );
  }

  @override
  String toString() =>
      'HealthMetrics(hrv: $hrvScore, stress: $stressLevel, '
      'odsTrend: $oxygenDesaturationTrend, fatigue: $fatigueIndex, '
      'rhythmFlag: $rhythmIrregularityFlag, tempFlag: $temperatureElevationFlag)';
}

// ─────────────────────────────────────────────────────────────────────────────
// HRV Metrics
// ─────────────────────────────────────────────────────────────────────────────

class HRVMetrics {
  final double rmssd;
  final double sdnn;

  /// Wellness normalization (0–100). NOT a clinical stress measurement.
  final double stressScore;

  final String stressLevel;
  final String recoveryStatus;

  const HRVMetrics({
    required this.rmssd,
    required this.sdnn,
    required this.stressScore,
    required this.stressLevel,
    required this.recoveryStatus,
  });

  HRVMetrics copyWith({
    double? rmssd,
    double? sdnn,
    double? stressScore,
    String? stressLevel,
    String? recoveryStatus,
  }) {
    return HRVMetrics(
      rmssd: rmssd ?? this.rmssd,
      sdnn: sdnn ?? this.sdnn,
      stressScore: stressScore ?? this.stressScore,
      stressLevel: stressLevel ?? this.stressLevel,
      recoveryStatus: recoveryStatus ?? this.recoveryStatus,
    );
  }

  Map<String, dynamic> toJson() => {
    'rmssd': rmssd,
    'sdnn': sdnn,
    'stress_score': stressScore,
    'stress_level': stressLevel,
    'recovery_status': recoveryStatus,
  };

  factory HRVMetrics.fromJson(Map<String, dynamic> json) {
    return HRVMetrics(
      rmssd: _toDouble(json['rmssd']),
      sdnn: _toDouble(json['sdnn']),
      stressScore: _toDouble(json['stress_score']),
      stressLevel: _toStringOr(json['stress_level'], 'Unknown'),
      recoveryStatus: _toStringOr(json['recovery_status'], 'Unknown'),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AFib / Rhythm Irregularity Result
//
//    The UI must not render it as a percentage diagnosis.
// ─────────────────────────────────────────────────────────────────────────────

class AFibResult {
  /// 0.0 – 1.0. NOT a probability. Do not render as a percentage.
  final double irregularityIndicator;

  final bool isSuspected;
  final String confidence;

  const AFibResult({
    required this.irregularityIndicator,
    required this.isSuspected,
    required this.confidence,
  });

  AFibResult copyWith({
    double? irregularityIndicator,
    bool? isSuspected,
    String? confidence,
  }) {
    return AFibResult(
      irregularityIndicator:
          irregularityIndicator ?? this.irregularityIndicator,
      isSuspected: isSuspected ?? this.isSuspected,
      confidence: confidence ?? this.confidence,
    );
  }

  Map<String, dynamic> toJson() => {
    'irregularity_indicator': irregularityIndicator,
    'is_suspected': isSuspected,
    'confidence': confidence,
  };

  factory AFibResult.fromJson(Map<String, dynamic> json) {
    return AFibResult(
      irregularityIndicator: _toDouble(json['irregularity_indicator']),
      isSuspected: _toBool(json['is_suspected']),
      confidence: _toStringOr(json['confidence'], 'Low'),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Oxygen Desaturation Trend
// ─────────────────────────────────────────────────────────────────────────────

class OxygenDesaturationTrend {
  /// Engineering count of overnight SpO₂ dips per hour.
  final double desaturationIndexProxy;

  final double trendScore;
  final String trendLevel;
  final String recommendation;

  const OxygenDesaturationTrend({
    required this.desaturationIndexProxy,
    required this.trendScore,
    required this.trendLevel,
    required this.recommendation,
  });

  OxygenDesaturationTrend copyWith({
    double? desaturationIndexProxy,
    double? trendScore,
    String? trendLevel,
    String? recommendation,
  }) {
    return OxygenDesaturationTrend(
      desaturationIndexProxy:
          desaturationIndexProxy ?? this.desaturationIndexProxy,
      trendScore: trendScore ?? this.trendScore,
      trendLevel: trendLevel ?? this.trendLevel,
      recommendation: recommendation ?? this.recommendation,
    );
  }

  Map<String, dynamic> toJson() => {
    'desaturation_index_proxy': desaturationIndexProxy,
    'trend_score': trendScore,
    'trend_level': trendLevel,
    'recommendation': recommendation,
  };

  factory OxygenDesaturationTrend.fromJson(Map<String, dynamic> json) {
    return OxygenDesaturationTrend(
      desaturationIndexProxy: _toDouble(json['desaturation_index_proxy']),
      trendScore: _toDouble(json['trend_score']),
      trendLevel: _toStringOr(json['trend_level'], 'Unknown'),
      recommendation: _toStringOr(json['recommendation'], ''),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Temperature Deviation Result
//
// Wrist temperature ≠ core temperature.
// This is a deviation from a personal baseline, NOT a fever diagnosis.
// ─────────────────────────────────────────────────────────────────────────────

class FeverResult {
  final double currentTemp;
  final double baselineTemp;

  /// 0.0 – 1.0. NOT a probability of infection or fever.
  final double deviationScore;

  final bool isSuspected;
  final String recommendation;

  const FeverResult({
    required this.currentTemp,
    required this.baselineTemp,
    required this.deviationScore,
    required this.isSuspected,
    required this.recommendation,
  });

  FeverResult copyWith({
    double? currentTemp,
    double? baselineTemp,
    double? deviationScore,
    bool? isSuspected,
    String? recommendation,
  }) {
    return FeverResult(
      currentTemp: currentTemp ?? this.currentTemp,
      baselineTemp: baselineTemp ?? this.baselineTemp,
      deviationScore: deviationScore ?? this.deviationScore,
      isSuspected: isSuspected ?? this.isSuspected,
      recommendation: recommendation ?? this.recommendation,
    );
  }

  Map<String, dynamic> toJson() => {
    'current_temp': currentTemp,
    'baseline_temp': baselineTemp,
    'deviation_score': deviationScore,
    'is_suspected': isSuspected,
    'recommendation': recommendation,
  };

  factory FeverResult.fromJson(Map<String, dynamic> json) {
    return FeverResult(
      currentTemp: _toDouble(json['current_temp']),
      baselineTemp: _toDouble(json['baseline_temp']),
      deviationScore: _toDouble(json['deviation_score']),
      isSuspected: _toBool(json['is_suspected']),
      recommendation: _toStringOr(json['recommendation'], ''),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Heart-Rate Elevation / Readiness Result
// ─────────────────────────────────────────────────────────────────────────────

class FatigueResult {
  final double fatigueScore;
  final String readiness;
  final String restingHrTrend;
  final String recommendation;

  const FatigueResult({
    required this.fatigueScore,
    required this.readiness,
    required this.restingHrTrend,
    required this.recommendation,
  });

  FatigueResult copyWith({
    double? fatigueScore,
    String? readiness,
    String? restingHrTrend,
    String? recommendation,
  }) {
    return FatigueResult(
      fatigueScore: fatigueScore ?? this.fatigueScore,
      readiness: readiness ?? this.readiness,
      restingHrTrend: restingHrTrend ?? this.restingHrTrend,
      recommendation: recommendation ?? this.recommendation,
    );
  }

  Map<String, dynamic> toJson() => {
    'fatigue_score': fatigueScore,
    'readiness': readiness,
    'resting_hr_trend': restingHrTrend,
    'recommendation': recommendation,
  };

  factory FatigueResult.fromJson(Map<String, dynamic> json) {
    return FatigueResult(
      fatigueScore: _toDouble(json['fatigue_score']),
      readiness: _toStringOr(json['readiness'], 'Unknown'),
      restingHrTrend: _toStringOr(json['resting_hr_trend'], ''),
      recommendation: _toStringOr(json['recommendation'], ''),
    );
  }
}
