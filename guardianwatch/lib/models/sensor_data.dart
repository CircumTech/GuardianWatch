// ─── lib/models/sensor_data.dart ─────────────────────────────────────────────

class SensorData {
  final String? id; // optional unique identifier
  final int? heartRate; // bpm
  final int? spo2; // %
  final double? temperature; // °C
  final List<double>? ecgMv; // ECG millivolt samples
  final int? battery; // %
  final DateTime timestamp;

  SensorData({
    this.id,
    this.heartRate,
    this.spo2,
    this.temperature,
    this.ecgMv,
    this.battery,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'heart_rate': heartRate,
        'spo2': spo2,
        'temperature': temperature,
        'ecg_mv': ecgMv,
        'battery': battery,
        'timestamp': timestamp.toIso8601String(),
      };

  factory SensorData.fromJson(Map<String, dynamic> j) => SensorData(
        id: j['id'] as String?,
        heartRate: j['heart_rate'] as int?,
        spo2: j['spo2'] as int?,
        temperature: (j['temperature'] as num?)?.toDouble(),
        ecgMv: (j['ecg_mv'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList(),
        battery: j['battery'] as int?,
        timestamp: DateTime.parse(j['timestamp'] as String),
      );

  // For SQLite storage (serialise ECG list as comma-separated string)
  Map<String, dynamic> toMap() => {
        'id': id,
        'heart_rate': heartRate,
        'spo2': spo2,
        'temperature': temperature,
        'ecg_mv': ecgMv?.map((e) => e.toString()).join(','),
        'battery': battery,
        'timestamp': timestamp.toIso8601String(),
      };

  // Optional: fromMap factory (requires parsing CSV back to List<double>)
  factory SensorData.fromMap(Map<String, dynamic> m) => SensorData(
        id: m['id'] as String?,
        heartRate: m['heart_rate'] as int?,
        spo2: m['spo2'] as int?,
        temperature: (m['temperature'] as num?)?.toDouble(),
        ecgMv: (m['ecg_mv'] as String?)
            ?.split(',')
            .map((s) => double.tryParse(s) ?? 0.0)
            .toList(),
        battery: m['battery'] as int?,
        timestamp: DateTime.parse(m['timestamp'] as String),
      );
}
