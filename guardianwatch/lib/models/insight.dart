// ─── lib/models/insight.dart ─────────────────────────────────────────────────

enum InsightSeverity { normal, caution, warning, critical }

class Insight {
  final String id;
  final String title;
  final String summary;
  final String detail;
  final InsightSeverity severity;
  final bool isPremium;
  final DateTime generatedAt;
  final String? recommendation; // optional AI recommendation

  Insight({
    required this.id,
    required this.title,
    required this.summary,
    required this.detail,
    required this.severity,
    required this.isPremium,
    required this.generatedAt,
    this.recommendation,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'summary': summary,
        'detail': detail,
        'severity': severity.name,
        'is_premium': isPremium,
        'generated_at': generatedAt.toIso8601String(),
        if (recommendation != null) 'recommendation': recommendation,
      };

  factory Insight.fromJson(Map<String, dynamic> j) => Insight(
        id: j['id'] as String,
        title: j['title'] as String,
        summary: j['summary'] as String,
        detail: j['detail'] as String,
        severity: InsightSeverity.values.firstWhere(
          (e) => e.name == j['severity'],
          orElse: () => InsightSeverity.normal,
        ),
        isPremium: j['is_premium'] as bool? ?? false,
        generatedAt: DateTime.parse(j['generated_at'] as String),
        recommendation: j['recommendation'] as String?,
      );

  // For SQLite
  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'summary': summary,
        'detail': detail,
        'severity': severity.name,
        'is_premium': isPremium ? 1 : 0,
        'generated_at': generatedAt.toIso8601String(),
        'recommendation': recommendation,
      };

  factory Insight.fromMap(Map<String, dynamic> m) => Insight(
        id: m['id'] as String,
        title: m['title'] as String,
        summary: m['summary'] as String,
        detail: m['detail'] as String,
        severity: InsightSeverity.values.firstWhere(
          (e) => e.name == m['severity'],
          orElse: () => InsightSeverity.normal,
        ),
        isPremium: (m['is_premium'] as int) == 1,
        generatedAt: DateTime.parse(m['generated_at'] as String),
        recommendation: m['recommendation'] as String?,
      );
}
