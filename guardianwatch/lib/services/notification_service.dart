import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    InitializationSettings initialSettings = InitializationSettings(
      android: android,
      iOS: ios,
    );
    await _plugin.initialize(
      settings: initialSettings,
      onDidReceiveNotificationResponse: (NotificationResponse details) {
        // handle click logic here
      },
    );
    _initialized = true;
  }

  static const _alertChannel = AndroidNotificationChannel(
    'gw_alerts',
    'Health Alerts',
    description: 'Critical health metric alerts from GuardianWrist',
    importance: Importance.max,
    playSound: true,
  );

  static const _infoChannel = AndroidNotificationChannel(
    'gw_info',
    'General Notifications',
    description: 'Info notifications from GuardianWrist',
    importance: Importance.defaultImportance,
  );

  static Future<void> showHighHeartRate(int bpm) async => await _plugin.show(
    id: 1,
    title: '⚠️ High Heart Rate',
    body: 'Your heart rate is $bpm bpm, which is above your alert threshold.',
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _alertChannel.id,
        _alertChannel.name,
        channelDescription: _alertChannel.description,
        importance: Importance.max,
        priority: Priority.high,
        color: const Color(0xFFE63946),
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
      ),
    ),
  );

  static Future<void> showLowSpO2(int spo2) async => await _plugin.show(
    id: 2,
    title: '⚠️ Low Blood Oxygen',
    body: 'Your SpO₂ is $spo2%, which is below your alert threshold.',
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _alertChannel.id,
        _alertChannel.name,
        channelDescription: _alertChannel.description,
        importance: Importance.max,
        priority: Priority.high,
        color: const Color(0xFF0077B6),
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
      ),
    ),
  );

  static Future<void> showInsightReady() async => await _plugin.show(
    id: 3,
    title: '🧠 New Health Insight',
    body: 'Your weekly AI health analysis is ready. Tap to view.',
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _infoChannel.id,
        _infoChannel.name,
        channelDescription: _infoChannel.description,
      ),
      iOS: const DarwinNotificationDetails(presentAlert: true),
    ),
  );

  static Future<void> showWatchDisconnected() async => await _plugin.show(
    id: 4,
    title: 'GuardianWrist Disconnected',
    body: 'Your watch has lost connection. Open the app to reconnect.',
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _infoChannel.id,
        _infoChannel.name,
        channelDescription: _infoChannel.description,
      ),
      iOS: const DarwinNotificationDetails(presentAlert: true),
    ),
  );

  static Future<void> cancelAll() async => await _plugin.cancelAll();
}
