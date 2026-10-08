// ─── lib/models/sensor_data.dart ─────────────────────────────────────────────
//
// A single Guardian Watch sensor reading.
//
// USAGE
// -----
// This model represents a live sensor packet from the BLE pipeline.
// It is NOT the persistence model for health history — that is
// HealthRecord.
//
// ECG WARNING
// -----------
// `ecgMv` may contain a small live packet from BLE notifications.
// Long ECG recordings must NOT be persisted through this model's
// toMap() / toJson(). Use a dedicated ECG session store (binary file or
// chunked objects) as described in the Guardian Watch report.
//
// TIMESTAMP CONVENTION
// --------------------
// In-memory:  local DateTime
// JSON:       UTC ISO-8601 string
// SQLite map: UTC ISO-8601 string
// ─────────────────────────────────────────────────────────────────────────────

class SensorData {
  /// Optional identifier. If this instance will be persisted, an id must
  /// be set by the caller.
  final String? id;

  /// Guardian Watch hardware ID.
  final String? deviceId;

  /// Heart rate in BPM (20–240). Values outside this range are rejected
  /// at parse time.
  final int? heartRate;

  /// Blood oxygen saturation percentage (50–100).
  final int? spo2;

  /// Temperature in degrees Celsius (0–60).
  final double? temperature;

  /// Small ECG sample packet received during live monitoring.
  ///
  ///   Do not use this field to persist long ECG recordings.
  ///   Max ~1000 samples per instance is the intended usage.
  final List<double>? ecgMv;

  /// Battery percentage from 0–100.
  final int? battery;

  /// Signal quality from 0–100.
  final int? signalQuality;

  /// Local timestamp.
  final DateTime timestamp;

  const SensorData({
    this.id,
    this.deviceId,
    this.heartRate,
    this.spo2,
    this.temperature,
    this.ecgMv,
    this.battery,
    this.signalQuality,
    required this.timestamp,
  });

  SensorData copyWith({
    String? id,
    String? deviceId,
    int? heartRate,
    int? spo2,
    double? temperature,
    List<double>? ecgMv,
    int? battery,
    int? signalQuality,
    DateTime? timestamp,
    bool clearEcgMv = false,
  }) {
    return SensorData(
      id: id ?? this.id,
      deviceId: deviceId ?? this.deviceId,
      heartRate: heartRate ?? this.heartRate,
      spo2: spo2 ?? this.spo2,
      temperature: temperature ?? this.temperature,
      ecgMv: clearEcgMv ? null : ecgMv ?? this.ecgMv,
      battery: battery ?? this.battery,
      signalQuality: signalQuality ?? this.signalQuality,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  // ── JSON ────────────────────────────────────────────────────────────────
  //
  // Null fields are omitted rather than sent as null so the backend can
  // distinguish "not measured" from "measured as zero".

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    if (deviceId != null) 'device_id': deviceId,
    if (heartRate != null) 'heart_rate': heartRate,
    if (spo2 != null) 'spo2': spo2,
    if (temperature != null) 'temperature': temperature,
    if (ecgMv != null) 'ecg_mv': ecgMv,
    if (battery != null) 'battery': battery,
    if (signalQuality != null) 'signal_quality': signalQuality,
    'timestamp': timestamp.toUtc().toIso8601String(),
  };

  factory SensorData.fromJson(Map<String, dynamic> json) {
    return SensorData(
      id: json['id']?.toString(),
      deviceId: json['device_id']?.toString(),
      heartRate: _toInt(json['heart_rate']),
      spo2: _toInt(json['spo2']),
      temperature: _toDouble(json['temperature']),
      ecgMv: _parseEcg(json['ecg_mv']),
      battery: _toInt(json['battery']),
      signalQuality: _toInt(json['signal_quality']),
      timestamp: _toDateTime(json['timestamp']) ?? DateTime.now(),
    );
  }

  // ── SQLite map ──────────────────────────────────────────────────────────

  /// SQLite-compatible map.
  ///
  ///    ECG packets are serialized as comma-separated values. This is
  ///    suitable ONLY for small live packets (see the class-level
  ///    warning). Long recordings must use a dedicated ECG store.
  ///
  /// Throws [StateError] if [ecgMv] exceeds 1000 samples — a strong
  /// signal that the caller is misusing this model.
  Map<String, dynamic> toMap() {
    final ecg = ecgMv;
    if (ecg != null && ecg.length > 1000) {
      throw StateError(
        'SensorData.toMap() refuses to persist ${ecg.length} ECG '
        'samples. Use a dedicated ECG session store for long recordings.',
      );
    }

    return {
      'id': id,
      'device_id': deviceId,
      'heart_rate': heartRate,
      'spo2': spo2,
      'temperature': temperature,
      'ecg_mv': ecg?.join(','),
      'battery': battery,
      'signal_quality': signalQuality,
      'timestamp': timestamp.toUtc().toIso8601String(),
    };
  }

  factory SensorData.fromMap(Map<String, dynamic> map) {
    List<double>? parsedEcg;
    final ecgString = map['ecg_mv'] as String?;
    if (ecgString != null && ecgString.isNotEmpty) {
      parsedEcg = ecgString
          .split(',')
          .map(double.tryParse)
          .whereType<double>()
          .toList();
    }

    return SensorData(
      id: map['id']?.toString(),
      deviceId: map['device_id']?.toString(),
      heartRate: _toInt(map['heart_rate']),
      spo2: _toInt(map['spo2']),
      temperature: _toDouble(map['temperature']),
      ecgMv: parsedEcg,
      battery: _toInt(map['battery']),
      signalQuality: _toInt(map['signal_quality']),
      timestamp: _toDateTime(map['timestamp']) ?? DateTime.now(),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  static int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static DateTime? _toDateTime(dynamic value) {
    if (value is DateTime) return value.toLocal();
    if (value is String) return DateTime.tryParse(value)?.toLocal();
    return null;
  }

  static List<double>? _parseEcg(dynamic value) {
    if (value is! List) return null;
    final parsed = value
        .whereType<num>()
        .map((v) => v.toDouble())
        .toList(growable: false);
    return parsed.isEmpty ? null : parsed;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SensorData && other.id == id && other.timestamp == timestamp;

  @override
  int get hashCode => Object.hash(id, timestamp);

  @override
  String toString() =>
      'SensorData(hr: $heartRate, spo2: $spo2, temp: $temperature, '
      'battery: $battery, ts: $timestamp)';
}
