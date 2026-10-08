// ─── lib/services/api_service.dart ───────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config/constants.dart';
import '../models/health_record.dart';
import '../models/insight.dart';
import '../models/sensor_data.dart';

// ════════════════════════════════════════════════════════════════════════════
// Session expired callback
// ════════════════════════════════════════════════════════════════════════════
//
// AuthService registers a handler via [onSessionExpired]. When a 401 cannot
// be recovered by refreshing the Firebase to Guardian token exchange, the
// handler is invoked so the app can sign out cleanly instead of looping on
// unauthorized requests.

typedef SessionExpiredHandler = Future<void> Function();

// ════════════════════════════════════════════════════════════════════════════
// API Exception
// ════════════════════════════════════════════════════════════════════════════

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final String? endpoint;
  final Object? cause;

  const ApiException({
    required this.message,
    this.statusCode,
    this.endpoint,
    this.cause,
  });

  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;
  bool get isNotFound => statusCode == 404;
  bool get isValidationError => statusCode == 400 || statusCode == 422;
  bool get isServerError => statusCode != null && statusCode! >= 500;

  bool get isTransient {
    return statusCode == null ||
        statusCode == 408 || // Request Timeout
        statusCode == 429 || // Too Many Requests
        (statusCode != null && statusCode! >= 500);
  }

  @override
  String toString() {
    final code = statusCode != null ? ' [HTTP $statusCode]' : '';
    final where = endpoint != null ? ' ($endpoint)' : '';
    return 'ApiException$code$where: $message';
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Subscription verification response
// ════════════════════════════════════════════════════════════════════════════

class SubscriptionVerification {
  final bool valid;
  final bool active;
  final String? productId;
  final String? platform;
  final DateTime? expiresAt;
  final bool? autoRenewing;
  final String? message;

  const SubscriptionVerification({
    required this.valid,
    required this.active,
    this.productId,
    this.platform,
    this.expiresAt,
    this.autoRenewing,
    this.message,
  });

  factory SubscriptionVerification.fromJson(Map<String, dynamic> json) {
    DateTime? expiry;
    final rawExpiry = json['expires_at'];
    if (rawExpiry is String && rawExpiry.isNotEmpty) {
      expiry = DateTime.tryParse(rawExpiry);
    }

    return SubscriptionVerification(
      valid: _toBool(json['valid']),
      active: _toBool(json['active']),
      productId: json['product_id']?.toString(),
      platform: json['platform']?.toString(),
      expiresAt: expiry,
      autoRenewing: json['auto_renewing'] == null
          ? null
          : _toBool(json['auto_renewing']),
      message: json['message']?.toString(),
    );
  }

  static bool _toBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final v = value.trim().toLowerCase();
      return v == 'true' || v == '1';
    }
    return false;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// API Service
// ════════════════════════════════════════════════════════════════════════════

class ApiService {
  ApiService({http.Client? client, FlutterSecureStorage? storage})
    : _client = client ?? http.Client(),
      _storage = storage ?? const FlutterSecureStorage();

  // ──────────────────────────────────────────────────────────────────────
  // Shared instance
  // ──────────────────────────────────────────────────────────────────────

  static final ApiService shared = ApiService();

  final http.Client _client;
  final FlutterSecureStorage _storage;

  String get _base => AppConstants.apiBaseUrl;

  bool _disposed = false;

  /// Registered by AuthService. Invoked when session cannot be recovered.
  SessionExpiredHandler? onSessionExpired;

  Future<void>? _activeJwtRefresh;
  bool _notifyingSessionExpired = false;

  // ══════════════════════════════════════════════════════════════════════════
  // Configuration
  // ══════════════════════════════════════════════════════════════════════════

  bool get isConfigured {
    final value = _base.trim();
    return value.isNotEmpty &&
        !value.contains('xxxxxxxx') &&
        value.startsWith('http');
  }

  Uri _uri(String path, {Map<String, String>? queryParameters}) {
    if (!isConfigured) {
      throw const ApiException(
        message: 'Guardian API is not configured.',
        endpoint: '/',
      );
    }

    final normalizedBase = _base.endsWith('/')
        ? _base.substring(0, _base.length - 1)
        : _base;
    final normalizedPath = path.startsWith('/') ? path : '/$path';

    return Uri.parse(
      '$normalizedBase$normalizedPath',
    ).replace(queryParameters: queryParameters);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Headers
  // ══════════════════════════════════════════════════════════════════════════

  Future<String?> _jwt() => _storage.read(key: AppConstants.keyJwt);

  Future<Map<String, String>> _headers({bool authenticated = true}) async {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'X-Request-ID': _generateRequestId(),
    };

    if (authenticated) {
      final jwt = await _jwt();
      if (jwt != null && jwt.isNotEmpty) {
        headers['Authorization'] = 'Bearer $jwt';
      }
    }

    return headers;
  }

  static final Random _rng = Random.secure();

  String _generateRequestId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(16, (_) => chars[_rng.nextInt(chars.length)]).join();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Firebase → Guardian JWT exchange
  // ══════════════════════════════════════════════════════════════════════════

  Future<String> exchangeToken(String firebaseIdToken) async {
    if (firebaseIdToken.trim().isEmpty) {
      throw const ApiException(
        message: 'Firebase ID token is empty.',
        endpoint: '/auth/token',
      );
    }

    const endpoint = '/auth/token';

    try {
      final response = await _client
          .post(
            _uri(endpoint),
            headers: await _headers(authenticated: false),
            body: jsonEncode({'id_token': firebaseIdToken}),
          )
          .timeout(AppConstants.apiTimeout);

      _checkResponse(response, endpoint, acceptedStatuses: const {200});

      final decoded = _decodeJson(response, endpoint);
      if (decoded is! Map<String, dynamic>) {
        throw const ApiException(
          message: 'Invalid authentication response from Guardian API.',
          statusCode: 200,
          endpoint: endpoint,
        );
      }

      final accessToken = decoded['access_token']?.toString();
      if (accessToken == null || accessToken.isEmpty) {
        throw const ApiException(
          message: 'Guardian API did not return an access token.',
          statusCode: 200,
          endpoint: endpoint,
        );
      }

      await _storage.write(key: AppConstants.keyJwt, value: accessToken);
      return accessToken;
    } catch (e) {
      final exception = _networkException(e, endpoint);
      debugPrint('Guardian token exchange failed: $exception');
      throw exception;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Guardian JWT refresh
  // ══════════════════════════════════════════════════════════════════════════

  Future<String?> _refreshGuardianJwt() async {
    // Deduplicate concurrent refresh attempts.
    if (_activeJwtRefresh != null) {
      await _activeJwtRefresh!;
      return _jwt();
    }

    final completer = Completer<void>();
    _activeJwtRefresh = completer.future;

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        await _notifySessionExpired();
        return null;
      }

      final firebaseToken = await user.getIdToken(true);
      if (firebaseToken == null || firebaseToken.isEmpty) {
        await _notifySessionExpired();
        return null;
      }

      await exchangeToken(firebaseToken);
      return _jwt();
    } catch (e) {
      debugPrint('Guardian JWT refresh failed: $e');
      await _notifySessionExpired();
      return null;
    } finally {
      if (!completer.isCompleted) completer.complete();
      _activeJwtRefresh = null;
    }
  }

  Future<void> _notifySessionExpired() async {
    if (_notifyingSessionExpired) return;
    _notifyingSessionExpired = true;
    try {
      final handler = onSessionExpired;
      if (handler != null) {
        await handler();
      }
    } catch (e) {
      debugPrint('Session-expired handler failed: $e');
    } finally {
      _notifyingSessionExpired = false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Error processing
  // ══════════════════════════════════════════════════════════════════════════

  ApiException _networkException(Object error, String endpoint) {
    if (error is ApiException) return error;

    if (error is TimeoutException) {
      return ApiException(
        message: 'The Guardian server took too long to respond.',
        endpoint: endpoint,
        cause: error,
      );
    }

    if (error is HandshakeException) {
      return ApiException(
        message: 'Secure connection to Guardian could not be established.',
        endpoint: endpoint,
        cause: error,
      );
    }

    if (error is SocketException) {
      return ApiException(
        message:
            'Unable to connect to the Guardian server. Check your internet connection.',
        endpoint: endpoint,
        cause: error,
      );
    }

    return ApiException(
      message: 'A network error occurred while contacting Guardian.',
      endpoint: endpoint,
      cause: error,
    );
  }

  String _extractErrorMessage(http.Response response) {
    if (response.body.isEmpty) {
      return 'The server returned HTTP ${response.statusCode}.';
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final detail = decoded['detail'];
        if (detail != null) return detail.toString();

        final message = decoded['message'];
        if (message != null) return message.toString();

        final error = decoded['error'];
        if (error != null) return error.toString();
      }

      if (decoded is String && decoded.isNotEmpty) {
        return decoded;
      }
    } catch (_) {
      // Fall through to a generic message.
    }

    // Don't leak raw HTML/error pages to the UI.
    return 'The Guardian server returned HTTP ${response.statusCode}.';
  }

  void _checkResponse(
    http.Response response,
    String endpoint, {
    Set<int> acceptedStatuses = const {200},
  }) {
    if (acceptedStatuses.contains(response.statusCode)) return;

    throw ApiException(
      message: _extractErrorMessage(response),
      statusCode: response.statusCode,
      endpoint: endpoint,
    );
  }

  dynamic _decodeJson(http.Response response, String endpoint) {
    if (response.body.trim().isEmpty) return null;

    try {
      return jsonDecode(response.body);
    } catch (e) {
      throw ApiException(
        message: 'The server returned invalid JSON.',
        statusCode: response.statusCode,
        endpoint: endpoint,
        cause: e,
      );
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Health record upload
  // ══════════════════════════════════════════════════════════════════════════

  /// Uploads canonical health records to the backend.
  ///
  /// On success returns the count of records accepted by the server.
  /// On failure throws [ApiException] so the sync engine can classify the
  /// error (transient vs permanent) and decide whether to retry.
  Future<int> uploadHealthRecords(
    List<HealthRecord> records, {
    bool retryAfterUnauthorized = true,
  }) async {
    if (records.isEmpty) return 0;

    const endpoint = '/readings';

    final payload = {'records': records.map((r) => r.toJson()).toList()};

    try {
      final response = await _client
          .post(
            _uri(endpoint),
            headers: await _headers(),
            body: jsonEncode(payload),
          )
          .timeout(AppConstants.apiTimeout);

      if (response.statusCode == 401 && retryAfterUnauthorized) {
        final refreshed = await _refreshGuardianJwt();
        if (refreshed != null && refreshed.isNotEmpty) {
          return uploadHealthRecords(records, retryAfterUnauthorized: false);
        }
      }

      _checkResponse(response, endpoint, acceptedStatuses: const {200, 201});

      // If backend returns a count, use it; otherwise assume all accepted.
      final decoded = _decodeJson(response, endpoint);
      if (decoded is Map<String, dynamic>) {
        final accepted = decoded['accepted'] ?? decoded['count'];
        if (accepted is int) return accepted;
      }

      return records.length;
    } catch (e) {
      final exception = _networkException(e, endpoint);
      debugPrint('Guardian health-record upload failed: $exception');
      throw exception;
    }
  }

  /// Legacy raw-sensor upload path.
  ///
  /// Deprecated: prefer [uploadHealthRecords].
  @Deprecated('Use uploadHealthRecords instead. Will be removed.')
  Future<bool> uploadReadings(
    List<SensorData> readings, {
    bool retryAfterUnauthorized = true,
  }) async {
    if (readings.isEmpty) return true;

    const endpoint = '/readings';

    try {
      final response = await _client
          .post(
            _uri(endpoint),
            headers: await _headers(),
            body: jsonEncode({
              'readings': readings.map((r) => r.toJson()).toList(),
            }),
          )
          .timeout(AppConstants.apiTimeout);

      if (response.statusCode == 401 && retryAfterUnauthorized) {
        final refreshed = await _refreshGuardianJwt();
        if (refreshed != null && refreshed.isNotEmpty) {
          return uploadReadings(readings, retryAfterUnauthorized: false);
        }
      }

      _checkResponse(response, endpoint, acceptedStatuses: const {200, 201});
      return true;
    } catch (e) {
      final exception = _networkException(e, endpoint);
      debugPrint('Guardian sensor upload failed: $exception');
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // History
  // ══════════════════════════════════════════════════════════════════════════

  Future<List<HealthRecord>> fetchHistory({
    DateTime? from,
    DateTime? to,
    int page = 0,
    int limit = 20,
    bool retryAfterUnauthorized = true,
  }) async {
    if (page < 0) {
      throw ArgumentError.value(page, 'page', 'Page cannot be negative.');
    }
    if (limit <= 0) {
      throw ArgumentError.value(
        limit,
        'limit',
        'Limit must be greater than zero.',
      );
    }
    if (from != null && to != null && from.isAfter(to)) {
      throw ArgumentError(
        'The history start date cannot be after the end date.',
      );
    }

    const endpoint = '/readings';

    final params = <String, String>{
      'page': page.toString(),
      'limit': limit.toString(),
      if (from != null) 'from': from.toUtc().toIso8601String(),
      if (to != null) 'to': to.toUtc().toIso8601String(),
    };

    try {
      final response = await _client
          .get(
            _uri(endpoint, queryParameters: params),
            headers: await _headers(),
          )
          .timeout(AppConstants.apiTimeout);

      if (response.statusCode == 401 && retryAfterUnauthorized) {
        final refreshed = await _refreshGuardianJwt();
        if (refreshed != null && refreshed.isNotEmpty) {
          return fetchHistory(
            from: from,
            to: to,
            page: page,
            limit: limit,
            retryAfterUnauthorized: false,
          );
        }
      }

      _checkResponse(response, endpoint, acceptedStatuses: const {200});

      final decoded = _decodeJson(response, endpoint);
      if (decoded is! List) {
        throw ApiException(
          message: 'Invalid health-history response from Guardian API.',
          statusCode: response.statusCode,
          endpoint: endpoint,
        );
      }

      final records = <HealthRecord>[];
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        try {
          records.add(HealthRecord.fromJson(item));
        } catch (e) {
          debugPrint('Skipping invalid health record: $e');
        }
      }
      return records;
    } catch (e) {
      final exception = _networkException(e, endpoint);
      debugPrint('Guardian history request failed: $exception');
      throw exception;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Insights
  // ══════════════════════════════════════════════════════════════════════════

  Future<List<Insight>> fetchInsights({
    bool retryAfterUnauthorized = true,
  }) async {
    const endpoint = '/insights/latest';

    try {
      final response = await _client
          .get(_uri(endpoint), headers: await _headers())
          .timeout(AppConstants.apiTimeout);

      if (response.statusCode == 401 && retryAfterUnauthorized) {
        final refreshed = await _refreshGuardianJwt();
        if (refreshed != null && refreshed.isNotEmpty) {
          return fetchInsights(retryAfterUnauthorized: false);
        }
      }

      _checkResponse(response, endpoint, acceptedStatuses: const {200});

      final decoded = _decodeJson(response, endpoint);
      if (decoded is! List) {
        throw ApiException(
          message: 'Invalid insights response from Guardian API.',
          statusCode: response.statusCode,
          endpoint: endpoint,
        );
      }

      return _parseInsightList(decoded);
    } catch (e) {
      final exception = _networkException(e, endpoint);
      debugPrint('Guardian insight request failed: $exception');
      throw exception;
    }
  }

  Future<List<Insight>> generateInsights({
    bool retryAfterUnauthorized = true,
  }) async {
    const endpoint = '/insights/generate';

    try {
      final response = await _client
          .post(_uri(endpoint), headers: await _headers())
          .timeout(AppConstants.apiTimeout);

      if (response.statusCode == 401 && retryAfterUnauthorized) {
        final refreshed = await _refreshGuardianJwt();
        if (refreshed != null && refreshed.isNotEmpty) {
          return generateInsights(retryAfterUnauthorized: false);
        }
      }

      _checkResponse(response, endpoint, acceptedStatuses: const {200});

      final decoded = _decodeJson(response, endpoint);
      if (decoded is! List) {
        throw ApiException(
          message: 'Invalid generated-insights response.',
          statusCode: response.statusCode,
          endpoint: endpoint,
        );
      }

      return _parseInsightList(decoded);
    } catch (e) {
      final exception = _networkException(e, endpoint);
      debugPrint('Guardian insight generation failed: $exception');
      throw exception;
    }
  }

  List<Insight> _parseInsightList(List<dynamic> raw) {
    final insights = <Insight>[];
    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      try {
        insights.add(Insight.fromJson(item));
      } catch (e) {
        debugPrint('Skipping invalid insight: $e');
      }
    }
    return insights;
  }

  Future<void> saveInsights(
    List<Insight> insights, {
    bool retryAfterUnauthorized = true,
  }) async {
    if (insights.isEmpty) return;

    if (!isConfigured) {
      debugPrint(
        'Guardian API is not configured. '
        'Insights remain locally available.',
      );
      return;
    }

    const endpoint = '/insights/save';

    try {
      final response = await _client
          .post(
            _uri(endpoint),
            headers: await _headers(),
            body: jsonEncode({
              'insights': insights.map((i) => i.toJson()).toList(),
            }),
          )
          .timeout(AppConstants.apiTimeout);

      if (response.statusCode == 401 && retryAfterUnauthorized) {
        final refreshed = await _refreshGuardianJwt();
        if (refreshed != null && refreshed.isNotEmpty) {
          await saveInsights(insights, retryAfterUnauthorized: false);
          return;
        }
      }

      _checkResponse(response, endpoint, acceptedStatuses: const {200, 201});
    } catch (e) {
      final exception = _networkException(e, endpoint);
      debugPrint('Guardian insight save failed: $exception');
      throw exception;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Subscription
  // ══════════════════════════════════════════════════════════════════════════

  /// Verifies a fresh purchase receipt with the backend.
  ///
  /// Returns a [SubscriptionVerification] describing the current state,
  /// including expiry and auto-renew status when provided by the backend.
  Future<SubscriptionVerification> verifySubscription({
    required String receipt,
    required String productId,
    String? platform,
    bool retryAfterUnauthorized = true,
  }) async {
    if (receipt.trim().isEmpty) {
      throw const ApiException(
        message: 'Purchase verification data is empty.',
        endpoint: '/subscription/verify',
      );
    }
    if (productId.trim().isEmpty) {
      throw const ApiException(
        message: 'Purchase product ID is empty.',
        endpoint: '/subscription/verify',
      );
    }

    const endpoint = '/subscription/verify';

    final body = {
      'receipt': receipt,
      'product_id': productId,
      if (platform != null && platform.isNotEmpty) 'platform': platform,
    };

    try {
      final response = await _client
          .post(
            _uri(endpoint),
            headers: await _headers(),
            body: jsonEncode(body),
          )
          .timeout(AppConstants.apiTimeout);

      if (response.statusCode == 401 && retryAfterUnauthorized) {
        final refreshed = await _refreshGuardianJwt();
        if (refreshed != null && refreshed.isNotEmpty) {
          return verifySubscription(
            receipt: receipt,
            productId: productId,
            platform: platform,
            retryAfterUnauthorized: false,
          );
        }
      }

      _checkResponse(response, endpoint, acceptedStatuses: const {200});

      final decoded = _decodeJson(response, endpoint);
      if (decoded is! Map<String, dynamic>) {
        throw const ApiException(
          message: 'Invalid subscription verification response.',
          statusCode: 200,
          endpoint: endpoint,
        );
      }

      return SubscriptionVerification.fromJson(decoded);
    } catch (e) {
      final exception = _networkException(e, endpoint);
      debugPrint('Guardian subscription verification failed: $exception');
      throw exception;
    }
  }

  /// Fetches the current server-side subscription status for the signed-in
  /// user without submitting a new receipt.
  Future<SubscriptionVerification> fetchSubscriptionStatus({
    bool retryAfterUnauthorized = true,
  }) async {
    const endpoint = '/subscription/status';

    try {
      final response = await _client
          .get(_uri(endpoint), headers: await _headers())
          .timeout(AppConstants.apiTimeout);

      if (response.statusCode == 401 && retryAfterUnauthorized) {
        final refreshed = await _refreshGuardianJwt();
        if (refreshed != null && refreshed.isNotEmpty) {
          return fetchSubscriptionStatus(retryAfterUnauthorized: false);
        }
      }

      _checkResponse(response, endpoint, acceptedStatuses: const {200});

      final decoded = _decodeJson(response, endpoint);
      if (decoded is! Map<String, dynamic>) {
        throw const ApiException(
          message: 'Invalid subscription status response.',
          statusCode: 200,
          endpoint: endpoint,
        );
      }

      return SubscriptionVerification.fromJson(decoded);
    } catch (e) {
      final exception = _networkException(e, endpoint);
      debugPrint('Guardian subscription status request failed: $exception');
      throw exception;
    }
  }

  /// Deprecated bool-only receipt verification.
  @Deprecated('Use verifySubscription instead — it returns expiry info.')
  Future<bool> verifyReceipt(String receipt, String productId) async {
    try {
      final v = await verifySubscription(
        receipt: receipt,
        productId: productId,
        platform: defaultTargetPlatform.name,
      );
      return v.valid && v.active;
    } catch (e) {
      debugPrint('Guardian receipt verification failed: $e');
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Session
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> clearSession() async {
    await _storage.delete(key: AppConstants.keyJwt);
  }

  /// True if a stored JWT exists with plausible JWT structure.
  ///
  /// This does not verify signature or expiry — the backend does that.
  /// It only filters obviously malformed values before making requests.
  Future<bool> hasSession() async {
    final token = await _jwt();
    if (token == null) return false;

    final trimmed = token.trim();
    if (trimmed.isEmpty) return false;

    // JWTs are three base64url segments separated by dots.
    final parts = trimmed.split('.');
    return parts.length == 3 && parts.every((p) => p.isNotEmpty);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Cleanup
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> deleteAccount({bool retryAfterUnauthorized = true}) async {
    const endpoint = '/me';
    try {
      final response = await _client
          .delete(_uri(endpoint), headers: await _headers())
          .timeout(AppConstants.apiTimeout);

      if (response.statusCode == 401 && retryAfterUnauthorized) {
        final refreshed = await _refreshGuardianJwt();
        if (refreshed != null && refreshed.isNotEmpty) {
          return deleteAccount(retryAfterUnauthorized: false);
        }
      }

      if (response.statusCode != 204 && response.statusCode != 200) {
        _checkResponse(response, endpoint, acceptedStatuses: {204, 200});
      }
    } catch (e) {
      throw _networkException(e, endpoint);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _client.close();
  }
}
