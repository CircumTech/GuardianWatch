// ─── lib/models/insight.dart ─────────────────────────────────────────────────

enum InsightSeverity { normal, caution, warning, critical }

class Insight {
  final String id;

  /// Owner of the insight. Local-only; not sent to the backend.
  final String? userId;

  final String title;
  final String summary;
  final String detail;

  final InsightSeverity severity;

  final bool isPremium;

  /// Timestamp in local time.
  final DateTime generatedAt;

  final String? recommendation;
  final String? healthRecordId;
  final String? algorithmVersion;

  /// Whether this insight has been synchronized. Local-only.
  final bool isSynced;

  const Insight({
    required this.id,
    this.userId,
    required this.title,
    required this.summary,
    required this.detail,
    required this.severity,
    required this.isPremium,
    required this.generatedAt,
    this.recommendation,
    this.healthRecordId,
    this.algorithmVersion,
    this.isSynced = false,
  });

  Insight copyWith({
    String? id,
    String? userId,
    String? title,
    String? summary,
    String? detail,
    InsightSeverity? severity,
    bool? isPremium,
    DateTime? generatedAt,
    String? recommendation,
    String? healthRecordId,
    String? algorithmVersion,
    bool? isSynced,
    bool clearRecommendation = false,
    bool clearHealthRecordId = false,
    bool clearAlgorithmVersion = false,
  }) {
    return Insight(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      title: title ?? this.title,
      summary: summary ?? this.summary,
      detail: detail ?? this.detail,
      severity: severity ?? this.severity,
      isPremium: isPremium ?? this.isPremium,
      generatedAt: generatedAt ?? this.generatedAt,
      recommendation: clearRecommendation
          ? null
          : recommendation ?? this.recommendation,
      healthRecordId: clearHealthRecordId
          ? null
          : healthRecordId ?? this.healthRecordId,
      algorithmVersion: clearAlgorithmVersion
          ? null
          : algorithmVersion ?? this.algorithmVersion,
      isSynced: isSynced ?? this.isSynced,
    );
  }

  // ── JSON / API ──────────────────────────────────────────────────────────
  //
  // user_id and is_synced are intentionally omitted — the backend derives
  // the user from the authenticated JWT, and sync state is client-only.

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'summary': summary,
    'detail': detail,
    'severity': severity.name,
    'is_premium': isPremium,
    'generated_at': generatedAt.toUtc().toIso8601String(),
    if (recommendation != null) 'recommendation': recommendation,
    if (healthRecordId != null) 'health_record_id': healthRecordId,
    if (algorithmVersion != null) 'algorithm_version': algorithmVersion,
  };

  factory Insight.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    if (id == null || id.isEmpty) {
      throw const FormatException('Insight is missing an id.');
    }

    return Insight(
      id: id,
      userId: json['user_id']?.toString(),
      title: _stringOr(json['title'], 'Insight'),
      summary: _stringOr(json['summary'], ''),
      detail: _stringOr(json['detail'], ''),
      severity: _parseSeverity(json['severity']),
      isPremium: _toBool(json['is_premium']),
      generatedAt: _dateOr(json['generated_at'], DateTime.now()),
      recommendation: json['recommendation']?.toString(),
      healthRecordId: json['health_record_id']?.toString(),
      algorithmVersion: json['algorithm_version']?.toString(),
      isSynced: _toBool(json['is_synced']),
    );
  }

  // ── SQLite ──────────────────────────────────────────────────────────────

  Map<String, dynamic> toMap() => {
    'id': id,
    'user_id': userId,
    'title': title,
    'summary': summary,
    'detail': detail,
    'severity': severity.name,
    'is_premium': isPremium ? 1 : 0,
    'generated_at': generatedAt.toUtc().toIso8601String(),
    'recommendation': recommendation,
    'health_record_id': healthRecordId,
    'algorithm_version': algorithmVersion,
    'is_synced': isSynced ? 1 : 0,
  };

  factory Insight.fromMap(Map<String, dynamic> map) {
    final id = map['id']?.toString();
    if (id == null || id.isEmpty) {
      throw const FormatException('Insight row is missing an id.');
    }

    return Insight(
      id: id,
      userId: map['user_id']?.toString(),
      title: _stringOr(map['title'], 'Insight'),
      summary: _stringOr(map['summary'], ''),
      detail: _stringOr(map['detail'], ''),
      severity: _parseSeverity(map['severity']),
      isPremium: _toBool(map['is_premium']),
      generatedAt: _dateOr(map['generated_at'], DateTime.now()),
      recommendation: map['recommendation']?.toString(),
      healthRecordId: map['health_record_id']?.toString(),
      algorithmVersion: map['algorithm_version']?.toString(),
      isSynced: _toBool(map['is_synced']),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  static String _stringOr(dynamic value, String fallback) {
    final s = value?.toString();
    if (s == null || s.isEmpty) return fallback;
    return s;
  }

  static DateTime _dateOr(dynamic value, DateTime fallback) {
    if (value == null) return fallback;
    final parsed = DateTime.tryParse(value.toString());
    return parsed?.toLocal() ?? fallback;
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

  /// Maps the wire/DB severity string onto the enum.
  ///
  /// Kept explicit so renaming an enum member does not silently break
  /// stored records or API payloads.
  static InsightSeverity _parseSeverity(dynamic value) {
    switch (value?.toString().toLowerCase()) {
      case 'caution':
        return InsightSeverity.caution;
      case 'warning':
        return InsightSeverity.warning;
      case 'critical':
        return InsightSeverity.critical;
      default:
        return InsightSeverity.normal;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Insight && other.id == id && other.generatedAt == generatedAt;

  @override
  int get hashCode => Object.hash(id, generatedAt);

  @override
  String toString() =>
      'Insight(id: $id, severity: ${severity.name}, title: $title)';
}
