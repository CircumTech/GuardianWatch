// ─── lib/services/notification_service.dart ──────────────────────────────────
//
// Guardian Watch local notifications.
//
// Responsibilities:
//   Initialize the local-notifications plugin
//   Create Android notification channels
//   Request OS permission (Android 13+, iOS)
//   Display alerts for HR, SpO2, temperature, battery, disconnect
//   Route notification taps to the app via a broadcast stream
//   Preserve the cold-start payload from a notification tap
//
// Design rules:
//   Taps are surfaced as a Stream<String> of payloads. The router in
//     the app layer consumes the stream and decides where to navigate.
//   Cold-start payloads (from a terminated app launch) are captured
//     once via consumeInitialPayload().
//   Init is deduplicated — concurrent callers share the same future.
//

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Background tap handler
//
// IMPORTANT:
// This MUST be a top-level function annotated with @pragma('vm:entry-point').
// The plugin runs it in a separate isolate when the app is terminated and the
// user taps a notification.
// ─────────────────────────────────────────────────────────────────────────────

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {
  // The background isolate has no access to the main isolate's streams.
  // The payload will be delivered to the main isolate via
  // getNotificationAppLaunchDetails() the next time the app starts.
  debugPrint('Guardian notification background tap: ${response.payload}');
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

class NotificationService {
  NotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;
  static Future<void>? _initializing;

  // ── Tap routing ─────────────────────────────────────────────────────────

  static final StreamController<String> _tapController =
      StreamController<String>.broadcast();

  /// Broadcast stream of notification payloads tapped while the app is
  /// running or was in the background.
  ///
  /// The app router should subscribe and dispatch to the correct screen.
  /// Example:
  ///
  ///   NotificationService.tapStream.listen((payload) {
  ///     router.handleDeepLink(payload);
  ///   });
  static Stream<String> get tapStream => _tapController.stream;

  /// Payload captured from a notification tap that launched the app from
  /// a terminated state. Read once and cleared.
  static String? _pendingInitialPayload;

  /// Returns the payload that launched the app (if any), then clears it.
  ///
  /// Call this once, right after the router is ready, on cold start.
  static String? consumeInitialPayload() {
    final payload = _pendingInitialPayload;
    _pendingInitialPayload = null;
    return payload;
  }

  // ─────────────────────────────────────────────────────────────
  // Notification IDs
  // ─────────────────────────────────────────────────────────────

  static const int highHeartRateId = 1001;
  static const int lowSpO2Id = 1002;
  static const int insightReadyId = 1003;
  static const int watchDisconnectedId = 1004;
  static const int lowBatteryId = 1005;
  static const int criticalBatteryId = 1006;
  static const int highTemperatureId = 1007;

  // ─────────────────────────────────────────────────────────────
  // Android notification icon
  //
  //  Android masks notification icons as a white silhouette.
  //    The launcher icon is typically colored and will render as a
  //    white blob on Android 5+.
  //
  //    Before release, add a dedicated monochrome icon at
  //    android/app/src/main/res/drawable/ic_notification.png and
  //    change this constant to:
  //
  //        '@drawable/ic_notification'
  // ─────────────────────────────────────────────────────────────

  static const String _androidIcon = '@drawable/ic_notification';

  // ─────────────────────────────────────────────────────────────
  // Android channels
  // ─────────────────────────────────────────────────────────────

  static const AndroidNotificationChannel alertChannel =
      AndroidNotificationChannel(
        'guardian_alerts',
        'Guardian Health Alerts',
        description: 'Important alerts generated from Guardian Watch readings.',
        importance: Importance.high,
        playSound: true,
      );

  static const AndroidNotificationChannel infoChannel =
      AndroidNotificationChannel(
        'guardian_info',
        'Guardian Notifications',
        description: 'General Guardian Watch notifications and status updates.',
        importance: Importance.defaultImportance,
        playSound: false,
      );

  static const AndroidNotificationChannel batteryChannel =
      AndroidNotificationChannel(
        'guardian_battery',
        'Guardian Battery',
        description: 'Guardian Watch battery and charging notifications.',
        importance: Importance.defaultImportance,
        playSound: true,
      );

  // ─────────────────────────────────────────────────────────────
  // Initialization
  // ─────────────────────────────────────────────────────────────

  /// Initializes the notification plugin.
  ///
  /// Safe to call multiple times — concurrent callers share the same future.
  /// Throws [NotificationServiceException] if initialization fails on a
  /// supported platform.
  static Future<void> init() async {
    if (_initialized) return;

    final inFlight = _initializing;
    if (inFlight != null) return inFlight;

    final future = _doInit();
    _initializing = future;

    try {
      await future;
    } finally {
      if (identical(_initializing, future)) {
        _initializing = null;
      }
    }
  }

  static Future<void> _doInit() async {
    const androidSettings = AndroidInitializationSettings(_androidIcon);

    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initializationSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    try {
      await _plugin.initialize(
        settings: initializationSettings,
        onDidReceiveNotificationResponse: _onNotificationTap,
        onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
      );

      await _createAndroidChannels();

      // Capture cold-start payload from a notification tap.
      await _captureLaunchPayload();

      // Request OS permission on first init. Denial does not throw.
      await _requestPermissions();

      _initialized = true;
    } catch (e, stack) {
      debugPrint('Guardian notifications init failed: $e');
      debugPrintStack(stackTrace: stack);
      rethrow;
    }
  }

  /// Reads the payload that launched the app (from a notification tap).
  static Future<void> _captureLaunchPayload() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details == null) return;
      if (!details.didNotificationLaunchApp) return;

      final payload = details.notificationResponse?.payload;
      if (payload != null && payload.isNotEmpty) {
        _pendingInitialPayload = payload;
        debugPrint('Guardian launched from notification: $payload');
      }
    } catch (e) {
      debugPrint('Guardian launch payload capture failed: $e');
    }
  }

  static Future<void> _createAndroidChannels() async {
    if (kIsWeb || !Platform.isAndroid) return;

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    if (androidPlugin == null) return;

    await androidPlugin.createNotificationChannel(alertChannel);
    await androidPlugin.createNotificationChannel(infoChannel);
    await androidPlugin.createNotificationChannel(batteryChannel);
  }

  /// Requests OS notification permission.
  ///
  /// Returns true if permission was granted or is not required on this OS.
  static Future<bool> _requestPermissions() async {
    if (kIsWeb) return false;

    try {
      if (Platform.isAndroid) {
        final androidPlugin = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();

        // No-op on Android < 13. Returns true if granted.
        final granted = await androidPlugin?.requestNotificationsPermission();
        return granted ?? true;
      }

      if (Platform.isIOS) {
        final iosPlugin = _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();

        final granted = await iosPlugin?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
        return granted ?? true;
      }
    } catch (e) {
      debugPrint('Guardian notification permission request failed: $e');
    }

    return false;
  }

  // ─────────────────────────────────────────────────────────────
  // Tap routing
  // ─────────────────────────────────────────────────────────────

  static void _onNotificationTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;

    if (_tapController.isClosed) return;

    debugPrint('Guardian notification tap: $payload');
    _tapController.add(payload);
  }

  // ─────────────────────────────────────────────────────────────
  // High heart rate
  // ─────────────────────────────────────────────────────────────

  static Future<void> showHighHeartRate(int bpm) async {
    await _ensureInitialized();

    await _showSafely(
      id: highHeartRateId,
      title: 'High Heart Rate Reading',
      body:
          'Guardian Watch reported $bpm BPM, above your configured alert '
          'threshold. This is not a medical diagnosis.',
      channel: alertChannel,
      iosPresentAlert: true,
      iosPresentSound: true,
      iosPresentBadge: true,
      payload: 'guardian://dashboard?alert=heart_rate',
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Low SpO₂
  // ─────────────────────────────────────────────────────────────

  static Future<void> showLowSpO2(int spo2) async {
    await _ensureInitialized();

    await _showSafely(
      id: lowSpO2Id,
      title: 'Low SpO₂ Reading',
      body:
          'Guardian Watch reported SpO₂ at $spo2%, below your configured '
          'alert threshold. This is not a medical diagnosis.',
      channel: alertChannel,
      iosPresentAlert: true,
      iosPresentSound: true,
      iosPresentBadge: true,
      payload: 'guardian://dashboard?alert=spo2',
    );
  }

  // ─────────────────────────────────────────────────────────────
  // High temperature
  //
  // IMPORTANT:
  // This is a wellness alert, not a medical diagnosis. The body text
  // deliberately frames the reading as "elevated relative to your
  // configured threshold," not as "you have a fever."
  // ─────────────────────────────────────────────────────────────

  static Future<void> showHighTemperature(double celsius) async {
    await _ensureInitialized();

    await _showSafely(
      id: highTemperatureId,
      title: 'Elevated Temperature Reading',
      body:
          'Guardian Watch reported ${celsius.toStringAsFixed(1)} °C, above '
          'your configured alert threshold. This is not a medical diagnosis.',
      channel: alertChannel,
      iosPresentAlert: true,
      iosPresentSound: true,
      iosPresentBadge: true,
      payload: 'guardian://dashboard?alert=temperature',
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Insight ready
  // ─────────────────────────────────────────────────────────────

  static Future<void> showInsightReady() async {
    await _ensureInitialized();

    await _showSafely(
      id: insightReadyId,
      title: 'New Guardian Insight',
      body: 'Your latest wellness analysis is ready to review.',
      channel: infoChannel,
      iosPresentAlert: true,
      iosPresentBadge: true,
      payload: 'guardian://insights',
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Watch disconnected
  // ─────────────────────────────────────────────────────────────

  static Future<void> showWatchDisconnected() async {
    await _ensureInitialized();

    await _showSafely(
      id: watchDisconnectedId,
      title: 'Guardian Watch Disconnected',
      body:
          'Your watch is no longer connected. Open Guardian Watch to '
          'reconnect.',
      channel: infoChannel,
      iosPresentAlert: true,
      iosPresentBadge: true,
      // Distinct URI so routing can tell disconnect apart from battery.
      payload: 'guardian://device?reason=disconnected',
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Low battery
  // ─────────────────────────────────────────────────────────────

  static Future<void> showLowBattery(int battery) async {
    await _ensureInitialized();

    await _showSafely(
      id: lowBatteryId,
      title: 'Guardian Watch Battery Low',
      body: 'Your watch battery is at $battery%. Consider charging it soon.',
      channel: batteryChannel,
      iosPresentAlert: true,
      iosPresentSound: true,
      payload: 'guardian://device?section=battery&level=low',
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Critical battery
  // ─────────────────────────────────────────────────────────────

  static Future<void> showCriticalBattery(int battery) async {
    await _ensureInitialized();

    await _showSafely(
      id: criticalBatteryId,
      title: 'Guardian Watch Battery Critical',
      body:
          'Your watch battery is critically low at $battery%. Charge the '
          'device now.',
      channel: batteryChannel,
      importance: Importance.high,
      priority: Priority.high,
      iosPresentAlert: true,
      iosPresentSound: true,
      payload: 'guardian://device?section=battery&level=critical',
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Unified show helper
  // ─────────────────────────────────────────────────────────────

  static Future<void> _showSafely({
    required int id,
    required String title,
    required String body,
    required AndroidNotificationChannel channel,
    required String payload,
    Importance importance = Importance.high,
    Priority priority = Priority.high,
    bool iosPresentAlert = true,
    bool iosPresentSound = false,
    bool iosPresentBadge = true,
  }) async {
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channel.id,
            channel.name,
            channelDescription: channel.description,
            importance: importance,
            priority: priority,
            category: AndroidNotificationCategory.reminder,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: iosPresentAlert,
            presentSound: iosPresentSound,
            presentBadge: iosPresentBadge,
            presentBanner: true,
            presentList: true,
          ),
        ),
        payload: payload,
      );
    } catch (e, stack) {
      debugPrint('Guardian notification $id failed to show: $e');
      debugPrintStack(stackTrace: stack);
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Cancel
  // ─────────────────────────────────────────────────────────────

  static Future<void> cancel(int id) async {
    await _ensureInitialized();

    try {
      await _plugin.cancel(id: id);
    } catch (e) {
      debugPrint('Guardian notification $id cancel failed: $e');
    }
  }

  static Future<void> cancelAll() async {
    await _ensureInitialized();

    try {
      await _plugin.cancelAll();
    } catch (e) {
      debugPrint('Guardian notification cancel-all failed: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────────────────────

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await init();
  }

  /// Releases the tap stream. Call only during full app shutdown.
  static Future<void> dispose() async {
    if (!_tapController.isClosed) {
      await _tapController.close();
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exception
// ─────────────────────────────────────────────────────────────────────────────

class NotificationServiceException implements Exception {
  final String message;
  final Object? cause;

  const NotificationServiceException(this.message, {this.cause});

  @override
  String toString() {
    final suffix = cause != null ? ' (cause: $cause)' : '';
    return 'NotificationServiceException: $message$suffix';
  }
}
