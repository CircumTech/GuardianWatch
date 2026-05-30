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