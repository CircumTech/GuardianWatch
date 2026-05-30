// ─── lib/services/api_service.dart ───────────────────────────────────────────

import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../config/constants.dart';
import '../models/health_record.dart';
import '../models/insight.dart';
import '../models/sensor_data.dart';

class ApiService {
  final _storage = const FlutterSecureStorage();
  final _base = AppConstants.apiBaseUrl;

  Future<String?> _jwt() => _storage.read(key: AppConstants.keyJwt);

  Future<Map<String, String>> _headers() async {
    final jwt = await _jwt();
    return {
      'Content-Type': 'application/json',
      if (jwt != null) 'Authorization': 'Bearer $jwt',
    };
  }

  // Exchange Firebase ID token → custom JWT
  Future<String?> exchangeToken(String firebaseIdToken) async {
    final res = await http.post(
      Uri.parse('$_base/auth/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'id_token': firebaseIdToken}),
    );
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final jwt = data['access_token'] as String;
      await _storage.write(key: AppConstants.keyJwt, value: jwt);
      return jwt;
    }
    return null;
  }

  // Batch-upload sensor readings
  Future<bool> uploadReadings(List<SensorData> readings) async {
    final res = await http.post(
      Uri.parse('$_base/readings'),
      headers: await _headers(),
      body: jsonEncode({'readings': readings.map((r) => r.toJson()).toList()}),
    );
    return res.statusCode == 201;
  }

  // Fetch historical records with pagination
  Future<List<HealthRecord>> fetchHistory({
    DateTime? from,
    DateTime? to,
    int page = 0,
    int limit = 20,
  }) async {
    final params = <String, String>{};
    if (from != null) params['from'] = from.toIso8601String();
    if (to != null) params['to'] = to.toIso8601String();
    params['page'] = page.toString();
    params['limit'] = limit.toString();
    final uri = Uri.parse('$_base/readings').replace(queryParameters: params);
    final res = await http.get(uri, headers: await _headers());
    if (res.statusCode == 200) {
      final list = jsonDecode(res.body) as List<dynamic>;
      return list
          .map((e) => HealthRecord.fromMap(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  // Fetch latest AI insights
  Future<List<Insight>> fetchInsights() async {
    final res = await http.get(
      Uri.parse('$_base/insights/latest'),
      headers: await _headers(),
    );
    if (res.statusCode == 200) {
      final list = jsonDecode(res.body) as List<dynamic>;
      return list
          .map((e) => Insight.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  // Verify IAP receipt with backend
  Future<bool> verifyReceipt(String receipt, String productId) async {
    final res = await http.post(
      Uri.parse('$_base/subscription/verify'),
      headers: await _headers(),
      body: jsonEncode({'receipt': receipt, 'product_id': productId}),
    );
    return res.statusCode == 200;
  }
  // Add to lib/services/api_service.dart

  Future<List<Insight>> generateInsights() async {
    final res = await http.post(
      Uri.parse('$_base/insights/generate'),
      headers: await _headers(),
    );
    if (res.statusCode == 200) {
      final list = jsonDecode(res.body) as List<dynamic>;
      return list
          .map((e) => Insight.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  Future<void> clearSession() => _storage.delete(key: AppConstants.keyJwt);
}
