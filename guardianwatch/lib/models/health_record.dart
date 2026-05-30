// ─── lib/models/health_record.dart ───────────────────────────────────────────

class HealthRecord {
  final String id;
  final String userId;
  final int heartRate;
  final int spo2;
  final double temperature;
  final DateTime recordedAt;

  HealthRecord({
    required this.id,
    required this.userId,
    required this.heartRate,
    required this.spo2,
    required this.temperature,
    required this.recordedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'user_id': userId,
        'heart_rate': heartRate,
        'spo2': spo2,
        'temperature': temperature,
        'recorded_at': recordedAt.toIso8601String(),
      };

  factory HealthRecord.fromMap(Map<String, dynamic> m) => HealthRecord(
        id: m['id'] as String,
        userId: m['user_id'] as String,
        heartRate: m['heart_rate'] as int,
        spo2: m['spo2'] as int,
        temperature: (m['temperature'] as num).toDouble(),
        recordedAt: DateTime.parse(m['recorded_at'] as String),
      );

  Map<String, dynamic> toJson() => toMap();
  factory HealthRecord.fromJson(Map<String, dynamic> json) =>
      HealthRecord.fromMap(json);
}
