import 'dart:async';
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
//import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/constants.dart';
import 'notification_service.dart';

/// Initialises the background service. Call once from main().
Future<void> initBackgroundService() async {
  final svc = FlutterBackgroundService();

  await svc.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      isForegroundMode: true,
      autoStart: false,
      notificationChannelId: 'gw_bg',
      initialNotificationTitle: 'GuardianWrist',
      initialNotificationContent: 'Monitoring your health in the background…',
      foregroundServiceNotificationId: 99,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

// Must be top-level — called by the background isolate on iOS
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance svc) async {
  DartPluginRegistrant.ensureInitialized();
  return true;
}

// Must be top-level — entry point for the background service
@pragma('vm:entry-point')
void onStart(ServiceInstance svc) async {
  DartPluginRegistrant.ensureInitialized();
  await NotificationService.init();

  if (svc is AndroidServiceInstance) {
    svc.on('setAsForeground').listen((_) => svc.setAsForegroundService());
    svc.on('setAsBackground').listen((_) => svc.setAsBackgroundService());
  }

  svc.on('stopService').listen((_) => svc.stopSelf());

  // Receive live sensor readings sent from the main isolate
  svc.on('sensorData').listen((data) async {
    if (data == null) return;
    final prefs = await SharedPreferences.getInstance();
    final hrHigh =
        prefs.getInt(AppConstants.keyAlertHrHigh) ?? AppConstants.defaultHrHigh;
    final spo2Low = prefs.getInt(AppConstants.keyAlertSpo2Low) ??
        AppConstants.defaultSpo2Low;

    final hr = data['heart_rate'] as int?;
    final spo2 = data['spo2'] as int?;

    if (hr != null && hr > hrHigh)
      await NotificationService.showHighHeartRate(hr);
    if (spo2 != null && spo2 < spo2Low)
      await NotificationService.showLowSpO2(spo2);
  });

  // Heartbeat: update foreground notification every minute
  Timer.periodic(const Duration(minutes: 1), (_) {
    if (svc is AndroidServiceInstance) {
      svc.setForegroundNotificationInfo(
        title: 'GuardianWrist Active',
        content: 'Monitoring heart rate & SpO₂',
      );
    }
    svc.invoke('heartbeat');
  });
}

/// Thin wrapper used by BleProvider to push data into the background isolate.
class BackgroundBridge {
  static final _svc = FlutterBackgroundService();

  static Future<void> start() => _svc.startService();
  static Future<void> stop() async => _svc.invoke('stopService');
  static void sendSensorData(Map<String, dynamic> data) =>
      _svc.invoke('sensorData', data);
  static Future<bool> get isRunning => _svc.isRunning();
}
