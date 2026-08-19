// ─── lib/models/health_metrics.dart ──────────────────────────────────────────

class HealthMetrics {
  final double hrvScore;        // Heart Rate Variability (0-100)
  final double stressLevel;     // Stress level (0-100)
  final double sleepApneaRisk;  // 0-100 risk score
  final double fatigueIndex;    // Fatigue/overtraining index
  final bool possibleAFib;      // Atrial fibrillation suspicion
  final bool possibleFever;     // Fever suspicion
  final DateTime computedAt;

  HealthMetrics({
    required this.hrvScore,
    required this.stressLevel,
    required this.sleepApneaRisk,
    required this.fatigueIndex,
    required this.possibleAFib,
    required this.possibleFever,
    required this.computedAt,
  });

  Map<String, dynamic> toJson() => {
    'hrv_score': hrvScore,
    'stress_level': stressLevel,
    'sleep_apnea_risk': sleepApneaRisk,
    'fatigue_index': fatigueIndex,
    'possible_afib': possibleAFib,
    'possible_fever': possibleFever,
    'computed_at': computedAt.toIso8601String(),
  };

  factory HealthMetrics.fromJson(Map<String, dynamic> j) => HealthMetrics(
    hrvScore: (j['hrv_score'] as num).toDouble(),
    stressLevel: (j['stress_level'] as num).toDouble(),
    sleepApneaRisk: (j['sleep_apnea_risk'] as num).toDouble(),
    fatigueIndex: (j['fatigue_index'] as num).toDouble(),
    possibleAFib: j['possible_afib'] as bool,
    possibleFever: j['possible_fever'] as bool,
    computedAt: DateTime.parse(j['computed_at'] as String),
  );
}

class HRVMetrics {
  final double rmssd;           // Root mean square of successive differences
  final double sdnn;            // Standard deviation of NN intervals
  final double stressScore;     // 0-100 (lower is better)
  final String stressLevel;     // Low, Medium, High
  final String recoveryStatus;  // Good recovery, Normal recovery, Poor recovery

  HRVMetrics({
    required this.rmssd,
    required this.sdnn,
    required this.stressScore,
    required this.stressLevel,
    required this.recoveryStatus,
  });

  Map<String, dynamic> toJson() => {
    'rmssd': rmssd,
    'sdnn': sdnn,
    'stress_score': stressScore,
    'stress_level': stressLevel,
    'recovery_status': recoveryStatus,
  };

  factory HRVMetrics.fromJson(Map<String, dynamic> json) => HRVMetrics(
    rmssd: json['rmssd']?.toDouble() ?? 0,
    sdnn: json['sdnn']?.toDouble() ?? 0,
    stressScore: json['stress_score']?.toDouble() ?? 0,
    stressLevel: json['stress_level'] ?? 'Unknown',
    recoveryStatus: json['recovery_status'] ?? 'Unknown',
  );
}

class AFibResult {
  final double probability;     // 0-1
  final bool isSuspected;
  final String confidence;      // High, Medium, Low

  AFibResult({
    required this.probability,
    required this.isSuspected,
    required this.confidence,
  });

  Map<String, dynamic> toJson() => {
    'probability': probability,
    'is_suspected': isSuspected,
    'confidence': confidence,
  };

  factory AFibResult.fromJson(Map<String, dynamic> json) => AFibResult(
    probability: json['probability']?.toDouble() ?? 0,
    isSuspected: json['is_suspected'] ?? false,
    confidence: json['confidence'] ?? 'Low',
  );
}

class SleepApneaRisk {
  final double odi;             // Oxygen Desaturation Index
  final double riskScore;       // 0-100
  final String riskLevel;       // Low, Medium, High
  final String recommendation;

  SleepApneaRisk({
    required this.odi,
    required this.riskScore,
    required this.riskLevel,
    required this.recommendation,
  });

  Map<String, dynamic> toJson() => {
    'odi': odi,
    'risk_score': riskScore,
    'risk_level': riskLevel,
    'recommendation': recommendation,
  };

  factory SleepApneaRisk.fromJson(Map<String, dynamic> json) => SleepApneaRisk(
    odi: json['odi']?.toDouble() ?? 0,
    riskScore: json['risk_score']?.toDouble() ?? 0,
    riskLevel: json['risk_level'] ?? 'Unknown',
    recommendation: json['recommendation'] ?? '',
  );
}

class FeverResult {
  final double currentTemp;
  final double baselineTemp;
  final double probability;
  final bool isSuspected;
  final String recommendation;

  FeverResult({
    required this.currentTemp,
    required this.baselineTemp,
    required this.probability,
    required this.isSuspected,
    required this.recommendation,
  });

  Map<String, dynamic> toJson() => {
    'current_temp': currentTemp,
    'baseline_temp': baselineTemp,
    'probability': probability,
    'is_suspected': isSuspected,
    'recommendation': recommendation,
  };

  factory FeverResult.fromJson(Map<String, dynamic> json) => FeverResult(
    currentTemp: json['current_temp']?.toDouble() ?? 0,
    baselineTemp: json['baseline_temp']?.toDouble() ?? 0,
    probability: json['probability']?.toDouble() ?? 0,
    isSuspected: json['is_suspected'] ?? false,
    recommendation: json['recommendation'] ?? '',
  );
}

class FatigueResult {
  final double fatigueScore;    // 0-100
  final String readiness;       // High, Moderate, Low
  final String restingHrTrend;
  final String recommendation;

  FatigueResult({
    required this.fatigueScore,
    required this.readiness,
    required this.restingHrTrend,
    required this.recommendation,
  });

  Map<String, dynamic> toJson() => {
    'fatigue_score': fatigueScore,
    'readiness': readiness,
    'resting_hr_trend': restingHrTrend,
    'recommendation': recommendation,
  };

  factory FatigueResult.fromJson(Map<String, dynamic> json) => FatigueResult(
    fatigueScore: json['fatigue_score']?.toDouble() ?? 0,
    readiness: json['readiness'] ?? 'Unknown',
    restingHrTrend: json['resting_hr_trend'] ?? '',
    recommendation: json['recommendation'] ?? '',
  );
}