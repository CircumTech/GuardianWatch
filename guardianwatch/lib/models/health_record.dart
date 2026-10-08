// ─── lib/models/health_record.dart ───────────────────────────────────────────
//
// A persisted Guardian Watch physiological reading.
//
// Used by:
//   Local SQLite storage
//   Cloud synchronization
//   History screens
//   Offline mode
//
// TIMESTAMP CONVENTION
// --------------------
// In-memory:  local DateTime
// SQLite:     UTC ISO-8601 string
// JSON/API:   UTC ISO-8601 string
//
// `isSynced` is local application state and is intentionally excluded
// from toJson(). `userId` is also excluded from toJson() — the backend
// derives the user from the authenticated JWT.
// ─────────────────────────────────────────────────────────────────────────────

class HealthRecord {
  final String id;
  final String userId;
  final String? deviceId;
  final String? sessionId;

  final int? heartRate;
  final int? spo2;
  final double? temperature;
  final int? battery;

  /// Time the reading was recorded, in local time.
  final DateTime recordedAt;

  /// Time the row was created locally, in local time.
  final DateTime createdAt;

  /// Whether this record has been successfully synchronized.
  final bool isSynced;

  const HealthRecord({
    required this.id,
    required this.userId,
    this.deviceId,
    this.sessionId,
    this.heartRate,
    this.spo2,
    this.temperature,
    this.battery,
    required this.recordedAt,
    required this.createdAt,
    this.isSynced = false,
  });

  // ── Copy ────────────────────────────────────────────────────────────────

  HealthRecord copyWith({
    String? id,
    String? userId,
    String? deviceId,
    String? sessionId,
    int? heartRate,
    int? spo2,
    double? temperature,
    int? battery,
    DateTime? recordedAt,
    DateTime? createdAt,
    bool? isSynced,
    bool clearDeviceId = false,
    bool clearSessionId = false,
  }) {
    return HealthRecord(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      deviceId: clearDeviceId ? null : deviceId ?? this.deviceId,
      sessionId: clearSessionId ? null : sessionId ?? this.sessionId,
      heartRate: heartRate ?? this.heartRate,
      spo2: spo2 ?? this.spo2,
      temperature: temperature ?? this.temperature,
      battery: battery ?? this.battery,
      recordedAt: recordedAt ?? this.recordedAt,
      createdAt: createdAt ?? this.createdAt,
      isSynced: isSynced ?? this.isSynced,
    );
  }

  // ── SQLite ──────────────────────────────────────────────────────────────

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'user_id': userId,
      'device_id': deviceId,
      'session_id': sessionId,
      'heart_rate': heartRate,
      'spo2': spo2,
      'temperature': temperature,
      'battery': battery,
      'recorded_at': recordedAt.toUtc().toIso8601String(),
      'created_at': createdAt.toUtc().toIso8601String(),
      'is_synced': isSynced ? 1 : 0,
    };
  }

  factory HealthRecord.fromMap(Map<String, dynamic> map) {
    final id = map['id'];
    final userId = map['user_id'];
    final recordedAt = map['recorded_at'];

    if (id is! String || userId is! String || recordedAt is! String) {
      throw const FormatException('Invalid HealthRecord database row.');
    }

    // created_at is required on new schema. Fall back to recorded_at for
    // legacy rows migrated from older versions.
    final createdAtRaw = map['created_at']?.toString() ?? recordedAt;

    return HealthRecord(
      id: id,
      userId: userId,
      deviceId: map['device_id']?.toString(),
      sessionId: map['session_id']?.toString(),
      heartRate: _toInt(map['heart_rate']),
      spo2: _toInt(map['spo2']),
      temperature: _toDouble(map['temperature']),
      battery: _toInt(map['battery']),
      recordedAt: DateTime.parse(recordedAt).toLocal(),
      createdAt: DateTime.parse(createdAtRaw).toLocal(),
      isSynced: _toBool(map['is_synced']),
    );
  }

  // ── JSON / API ──────────────────────────────────────────────────────────
  //
  // user_id is intentionally omitted. The backend derives the user
  // from the authenticated JWT.

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'device_id': deviceId,
      'session_id': sessionId,
      'heart_rate': heartRate,
      'spo2': spo2,
      'temperature': temperature,
      'battery': battery,
      'recorded_at': recordedAt.toUtc().toIso8601String(),
    };
  }

  factory HealthRecord.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final recordedAt = json['recorded_at'];

    if (id is! String || recordedAt is! String) {
      throw const FormatException('Invalid HealthRecord JSON payload.');
    }

    // userId may not be present in the payload if the backend scopes
    // records by JWT. Store it empty locally and let the sync layer
    // fill it in from the session.
    final userId = json['user_id']?.toString() ?? '';

    return HealthRecord(
      id: id,
      userId: userId,
      deviceId: json['device_id']?.toString(),
      sessionId: json['session_id']?.toString(),
      heartRate: _toInt(json['heart_rate']),
      spo2: _toInt(json['spo2']),
      temperature: _toDouble(json['temperature']),
      battery: _toInt(json['battery']),
      recordedAt: DateTime.parse(recordedAt).toLocal(),
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '')?.toLocal() ??
          DateTime.parse(recordedAt).toLocal(),
      isSynced: _toBool(json['is_synced']),
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

  static bool _toBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final n = value.trim().toLowerCase();
      return n == 'true' || n == '1';
    }
    return false;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HealthRecord &&
          other.id == id &&
          other.userId == userId &&
          other.recordedAt == recordedAt;

  @override
  int get hashCode => Object.hash(id, userId, recordedAt);

  @override
  String toString() =>
      'HealthRecord(id: $id, hr: $heartRate, spo2: $spo2, '
      'temp: $temperature, recordedAt: $recordedAt, synced: $isSynced)';
}
