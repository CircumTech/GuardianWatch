// ─── lib/services/health_export_service.dart ─────────────────────────────────

import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/constants.dart';

class HealthExportService {
  final _health = Health();
  bool _syncEnabled = false;

  Future<bool> get isOptedIn async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(AppConstants.keyHealthOptIn) ?? false;
  }

  Future<void> setOptIn(bool val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.keyHealthOptIn, val);
    if (val) await _authorize();
  }

  /// Request permissions for health data types
  Future<bool> requestPermissions() async {
    final types = [
      HealthDataType.HEART_RATE,
      HealthDataType.BLOOD_OXYGEN,
      HealthDataType.BODY_TEMPERATURE,
    ];
    final permissions = types.map((t) => HealthDataAccess.READ_WRITE).toList();
    final granted =
        await _health.requestAuthorization(types, permissions: permissions);
    return granted;
  }

  /// Enable sync (called after permission granted)
  Future<void> enableSync() async {
    _syncEnabled = true;
  }

  /// Disable sync
  Future<void> disableSync() async {
    _syncEnabled = false;
  }

  Future<void> _authorize() async {
    await _health.requestAuthorization([
      HealthDataType.HEART_RATE,
      HealthDataType.BLOOD_OXYGEN,
      HealthDataType.BODY_TEMPERATURE,
    ]);
  }

  Future<void> exportHeartRate(int bpm, DateTime ts) async {
    if (!await isOptedIn) return;
    await _health.writeHealthData(
      value: bpm.toDouble(),
      type: HealthDataType.HEART_RATE,
      startTime: ts.subtract(const Duration(seconds: 1)),
      endTime: ts,
    );
  }

  Future<void> exportSpO2(int pct, DateTime ts) async {
    if (!await isOptedIn) return;
    await _health.writeHealthData(
      value: pct.toDouble(),
      type: HealthDataType.BLOOD_OXYGEN,
      startTime: ts,
      endTime: ts,
    );
  }

  Future<void> exportTemperature(double celsius, DateTime ts) async {
    if (!await isOptedIn) return;
    await _health.writeHealthData(
      value: celsius,
      type: HealthDataType.BODY_TEMPERATURE,
      startTime: ts,
      endTime: ts,
    );
  }
}
