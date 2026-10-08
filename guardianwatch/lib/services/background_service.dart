// ─── lib/services/background_service.dart ────────────────────────────────────
//
// Guardian Watch background execution.
//
// ARCHITECTURE NOTE
// -----------------
// The main isolate owns the BLE connection. This background service runs as
// a separate isolate and:
//
//   receives parsed sensor values from the main isolate
//   evaluates alert thresholds (HR, SpO2, temperature, battery)
//   fires local notifications with hysteresis + cooldown
//   exposes a bridge (BackgroundBridge) for the main isolate to talk to it
//
// IMPORTANT:
//   The report requires offline-first capture. This service does NOT persist
//   sensor data to SQLite — the main isolate's LocalDbService owns the
//   database. If the main isolate is suspended, samples delivered here may
//   not be persisted. Real offline capture requires either a second write
//   path or moving BLE ownership into the background isolate. That is a
//   larger refactor and out of scope for this fix.
//

import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/constants.dart';
import 'notification_service.dart';

// ════════════════════════════════════════════════════════════════════════════
// Typed exception
// ════════════════════════════════════════════════════════════════════════════

class BackgroundServiceException implements Exception {
  final String message;
  final Object? cause;

  const BackgroundServiceException(this.message, {this.cause});

  @override
  String toString() => 'BackgroundServiceException: $message';
}

// ════════════════════════════════════════════════════════════════════════════
// Event names — shared between main isolate and background isolate
// ════════════════════════════════════════════════════════════════════════════

abstract final class BackgroundEvent {
  static const String setAsForeground = 'setAsForeground';
  static const String setAsBackground = 'setAsBackground';
  static const String stopService = 'stopService';
  static const String sensorData = 'sensorData';
  static const String settingsChanged = 'settingsChanged';
  static const String heartbeat = 'heartbeat';
}

// ════════════════════════════════════════════════════════════════════════════
// Initialization
// ════════════════════════════════════════════════════════════════════════════

/// Initializes Guardian Watch background execution.
///
/// Call this ONCE from main() before runApp().
Future<void> initBackgroundService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: AppConstants.bgForegroundChannelId,
      initialNotificationTitle: 'Guardian Watch',
      initialNotificationContent:
          'Guardian Watch background monitoring is active.',
      foregroundServiceNotificationId: AppConstants.bgForegroundNotificationId,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

// ════════════════════════════════════════════════════════════════════════════
// iOS background entry point
// ════════════════════════════════════════════════════════════════════════════
//
// This is invoked by the OS for background fetch slots on iOS. It must
// return promptly. Returning `true` indefinitely drains battery for no work.
// We return `false` after lightweight initialization.

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  try {
    await NotificationService.init();
  } catch (e) {
    debugPrint('iOS background notification init failed: $e');
  }

  // Returning false tells iOS the background slot is finished.
  return false;
}

// ════════════════════════════════════════════════════════════════════════════
// Main background service entry point
// ════════════════════════════════════════════════════════════════════════════

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  await NotificationService.init();

  final subscriptions = <StreamSubscription<dynamic>>[];
  Timer? heartbeat;

  // ── Android service controls ────────────────────────────────────────────

  if (service is AndroidServiceInstance) {
    subscriptions.add(
      service.on(BackgroundEvent.setAsForeground).listen((_) async {
        await service.setAsForegroundService();
      }),
    );

    subscriptions.add(
      service.on(BackgroundEvent.setAsBackground).listen((_) async {
        await service.setAsBackgroundService();
      }),
    );
  }

  // ── Stop service ────────────────────────────────────────────────────────

  subscriptions.add(
    service.on(BackgroundEvent.stopService).listen((_) async {
      debugPrint('Guardian background service stopping.');

      heartbeat?.cancel();
      heartbeat = null;

      for (final sub in subscriptions) {
        await sub.cancel();
      }
      subscriptions.clear();

      await service.stopSelf();
    }),
  );

  // ── Sensor telemetry ────────────────────────────────────────────────────

  subscriptions.add(
    service.on(BackgroundEvent.sensorData).listen((dynamic event) async {
      if (event is! Map) return;
      try {
        await _processSensorData(Map<String, dynamic>.from(event));
      } catch (e, stack) {
        debugPrint('Guardian background sensor processing failed: $e');
        debugPrintStack(stackTrace: stack);
      }
    }),
  );

  // ── Settings changed — invalidate cached thresholds ─────────────────────

  subscriptions.add(
    service.on(BackgroundEvent.settingsChanged).listen((_) {
      _invalidateSettingsCache();
    }),
  );

  // ── Heartbeat ───────────────────────────────────────────────────────────

  heartbeat = Timer.periodic(AppConstants.bgHeartbeatInterval, (_) async {
    if (service is AndroidServiceInstance) {
      try {
        final enabled = await service.isForegroundService();
        if (enabled) {
          service.setForegroundNotificationInfo(
            title: 'Guardian Watch Active',
            content: 'Health monitoring is running in the background.',
          );
        }
      } catch (e) {
        debugPrint('Foreground notification refresh failed: $e');
      }
    }

    service.invoke(BackgroundEvent.heartbeat, {
      'timestamp': DateTime.now().toIso8601String(),
    });
  });
}

// ════════════════════════════════════════════════════════════════════════════
// Settings cache
// ════════════════════════════════════════════════════════════════════════════
//
// Reading SharedPreferences on every BLE packet is wasteful. We cache the
// alert thresholds in the isolate's memory and invalidate on demand.

class _AlertSettings {
  final int hrHigh;
  final int spo2Low;
  final double tempHigh;
  final int batteryLow;
  final int batteryCritical;

  const _AlertSettings({
    required this.hrHigh,
    required this.spo2Low,
    required this.tempHigh,
    required this.batteryLow,
    required this.batteryCritical,
  });
}

_AlertSettings? _cachedSettings;

void _invalidateSettingsCache() {
  _cachedSettings = null;
}

Future<_AlertSettings> _loadSettings() async {
  final cached = _cachedSettings;
  if (cached != null) return cached;

  final prefs = await SharedPreferences.getInstance();

  final settings = _AlertSettings(
    hrHigh:
        prefs.getInt(AppConstants.keyAlertHrHigh) ?? AppConstants.defaultHrHigh,
    spo2Low:
        prefs.getInt(AppConstants.keyAlertSpo2Low) ??
        AppConstants.defaultSpo2Low,
    tempHigh:
        prefs.getDouble(AppConstants.keyAlertTempHigh) ??
        AppConstants.defaultTempHigh,
    batteryLow:
        prefs.getInt(AppConstants.keyAlertBatteryLow) ??
        AppConstants.defaultBatteryLow,
    batteryCritical:
        prefs.getInt(AppConstants.keyAlertBatteryCritical) ??
        AppConstants.defaultBatteryCritical,
  );

  _cachedSettings = settings;
  return settings;
}

// ════════════════════════════════════════════════════════════════════════════
// Sensor processing
// ════════════════════════════════════════════════════════════════════════════

Future<void> _processSensorData(Map<String, dynamic> data) async {
  final settings = await _loadSettings();
  final prefs = await SharedPreferences.getInstance();

  final heartRate = _plausibleInt(data['heart_rate'], 20, 240);
  final spo2 = _plausibleInt(data['spo2'], 50, 100);
  final temperature = _plausibleDouble(data['temperature'], 0, 60);
  final battery = _plausibleInt(data['battery'], 0, 100);

  // ── Heart-rate alerts ──────────────────────────────────────────────────

  if (heartRate != null) {
    final active = prefs.getBool(AppConstants.keyBgHighHrActive) ?? false;

    if (heartRate >= settings.hrHigh) {
      await _handleHighHeartRate(heartRate, settings, prefs);
    } else if (active &&
        heartRate < settings.hrHigh - AppConstants.hrAlertClearOffset) {
      await _clearHighHeartRateAlert(prefs);
    }
  }

  // ── SpO₂ alerts ────────────────────────────────────────────────────────

  if (spo2 != null) {
    final active = prefs.getBool(AppConstants.keyBgLowSpo2Active) ?? false;

    if (spo2 <= settings.spo2Low) {
      await _handleLowSpo2(spo2, settings, prefs);
    } else if (active &&
        spo2 > settings.spo2Low + AppConstants.spo2AlertClearOffset) {
      await _clearLowSpo2Alert(prefs);
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // High temperature
  // ════════════════════════════════════════════════════════════════════════════

  Future<void> _handleHighTemperature(
    double temperature,
    _AlertSettings settings,
    SharedPreferences prefs,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final lastAlert = prefs.getInt(AppConstants.keyBgLastHighTempAlert);
    final cooldown = AppConstants.bgAlertCooldown.inMilliseconds;

    if (lastAlert != null && (now - lastAlert) < cooldown) {
      return;
    }

    await NotificationService.showHighTemperature(temperature);

    await prefs.setInt(AppConstants.keyBgLastHighTempAlert, now);
    await prefs.setBool(AppConstants.keyBgHighTempActive, true);
  }

  Future<void> _clearHighTemperatureAlert(SharedPreferences prefs) async {
    await prefs.setBool(AppConstants.keyBgHighTempActive, false);
  }

  // ── Temperature alerts ─────────────────────────────────────────────────
  if (temperature != null) {
    final active = prefs.getBool(AppConstants.keyBgHighTempActive) ?? false;

    if (temperature >= settings.tempHigh) {
      await _handleHighTemperature(temperature, settings, prefs);
    } else if (active &&
        temperature < settings.tempHigh - AppConstants.tempAlertClearOffset) {
      await _clearHighTemperatureAlert(prefs);
    }
  }

  // ── Battery alerts ─────────────────────────────────────────────────────

  if (battery != null) {
    final active = prefs.getBool(AppConstants.keyBgLowBatteryActive) ?? false;

    if (battery <= settings.batteryCritical) {
      await _handleCriticalBattery(battery, prefs);
    } else if (battery <= settings.batteryLow) {
      await _handleLowBattery(battery, prefs);
    } else if (active &&
        battery > settings.batteryLow + AppConstants.batteryAlertClearOffset) {
      await _clearLowBatteryAlert(prefs);
    }
  }
}

// ════════════════════════════════════════════════════════════════════════════
// High heart rate
// ════════════════════════════════════════════════════════════════════════════

Future<void> _handleHighHeartRate(
  int heartRate,
  _AlertSettings settings,
  SharedPreferences prefs,
) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final lastAlert = prefs.getInt(AppConstants.keyBgLastHighHrAlert);
  final cooldown = AppConstants.bgAlertCooldown.inMilliseconds;

  if (lastAlert != null && (now - lastAlert) < cooldown) {
    return;
  }

  await NotificationService.showHighHeartRate(heartRate);

  await prefs.setInt(AppConstants.keyBgLastHighHrAlert, now);
  await prefs.setBool(AppConstants.keyBgHighHrActive, true);
}

Future<void> _clearHighHeartRateAlert(SharedPreferences prefs) async {
  await prefs.setBool(AppConstants.keyBgHighHrActive, false);
}

// ════════════════════════════════════════════════════════════════════════════
// Low SpO₂
// ════════════════════════════════════════════════════════════════════════════

Future<void> _handleLowSpo2(
  int spo2,
  _AlertSettings settings,
  SharedPreferences prefs,
) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final lastAlert = prefs.getInt(AppConstants.keyBgLastLowSpo2Alert);
  final cooldown = AppConstants.bgAlertCooldown.inMilliseconds;

  if (lastAlert != null && (now - lastAlert) < cooldown) {
    return;
  }

  await NotificationService.showLowSpO2(spo2);

  await prefs.setInt(AppConstants.keyBgLastLowSpo2Alert, now);
  await prefs.setBool(AppConstants.keyBgLowSpo2Active, true);
}

Future<void> _clearLowSpo2Alert(SharedPreferences prefs) async {
  await prefs.setBool(AppConstants.keyBgLowSpo2Active, false);
}

// ════════════════════════════════════════════════════════════════════════════
// Low / critical battery
// ════════════════════════════════════════════════════════════════════════════

Future<void> _handleLowBattery(int battery, SharedPreferences prefs) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final lastAlert = prefs.getInt(AppConstants.keyBgLastLowBatteryAlert);
  final cooldown = AppConstants.bgAlertCooldown.inMilliseconds;

  if (lastAlert != null && (now - lastAlert) < cooldown) {
    return;
  }

  await NotificationService.showLowBattery(battery);

  await prefs.setInt(AppConstants.keyBgLastLowBatteryAlert, now);
  await prefs.setBool(AppConstants.keyBgLowBatteryActive, true);
}

Future<void> _handleCriticalBattery(
  int battery,
  SharedPreferences prefs,
) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final lastAlert = prefs.getInt(AppConstants.keyBgLastCritBatteryAlert);
  final cooldown = AppConstants.bgAlertCooldown.inMilliseconds;

  if (lastAlert != null && (now - lastAlert) < cooldown) {
    return;
  }

  await NotificationService.showCriticalBattery(battery);

  await prefs.setInt(AppConstants.keyBgLastCritBatteryAlert, now);
  await prefs.setBool(AppConstants.keyBgLowBatteryActive, true);
}

Future<void> _clearLowBatteryAlert(SharedPreferences prefs) async {
  await prefs.setBool(AppConstants.keyBgLowBatteryActive, false);
}

// ════════════════════════════════════════════════════════════════════════════
// Safe number parsing
// ════════════════════════════════════════════════════════════════════════════

int? _plausibleInt(dynamic value, int min, int max) {
  final parsed = _toInt(value);
  if (parsed == null) return null;
  if (parsed < min || parsed > max) return null;
  return parsed;
}

double? _plausibleDouble(dynamic value, double min, double max) {
  final parsed = _toDouble(value);
  if (parsed == null) return null;
  if (!parsed.isFinite) return null;
  if (parsed < min || parsed > max) return null;
  return parsed;
}

int? _toInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

double? _toDouble(dynamic value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

// ════════════════════════════════════════════════════════════════════════════
// Background bridge (main isolate → background isolate)
// ════════════════════════════════════════════════════════════════════════════

class BackgroundBridge {
  BackgroundBridge._();

  static final FlutterBackgroundService _service = FlutterBackgroundService();

  /// Starts the background service if it is not already running.
  ///
  /// Throws [BackgroundServiceException] if the service cannot be started
  /// within [AppConstants.bgServiceStartTimeout].
  static Future<void> start() async {
    try {
      final running = await _service.isRunning();
      if (running) return;

      await _service.startService().timeout(AppConstants.bgServiceStartTimeout);

      debugPrint('Guardian background service started.');
    } on TimeoutException catch (e) {
      throw BackgroundServiceException(
        'Background service did not start within the timeout.',
        cause: e,
      );
    } catch (e) {
      throw BackgroundServiceException(
        'Failed to start the Guardian background service.',
        cause: e,
      );
    }
  }

  /// Stops the background service. Best-effort — never throws.
  static Future<void> stop() async {
    try {
      final running = await _service.isRunning();
      if (!running) return;

      _service.invoke(BackgroundEvent.stopService);
      debugPrint('Guardian background service stop requested.');
    } catch (e) {
      debugPrint('Guardian background service stop failed: $e');
    }
  }

  /// Checks whether the background service is currently running.
  ///
  /// Named as a method (not a getter) to make the async nature obvious.
  static Future<bool> checkRunning() => _service.isRunning();

  /// Forwards a parsed sensor packet to the background isolate.
  static void sendSensorData(Map<String, dynamic> data) {
    _service.invoke(BackgroundEvent.sensorData, data);
  }

  /// Tells the background isolate that alert thresholds have changed.
  ///
  /// Call this whenever the user updates HR / SpO2 / temperature / battery
  /// thresholds so the background service refreshes its cached settings.
  static void notifySettingsChanged() {
    _service.invoke(BackgroundEvent.settingsChanged, {
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  /// Forwards a heartbeat to the main isolate for health monitoring.
  static void sendHeartbeat() {
    _service.invoke(BackgroundEvent.heartbeat, {
      'timestamp': DateTime.now().toIso8601String(),
    });
  }
}
