import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'providers/auth_provider.dart';
import 'providers/ble_provider.dart';
import 'providers/dashboard_provider.dart';
import 'providers/insight_provider.dart';
import 'services/iap_service.dart';
import 'services/notification_service.dart';
import 'services/background_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Global error handling for Flutter framework errors
  FlutterError.onError = (FlutterErrorDetails details) {
    // In production, send to crash reporting service (e.g., Firebase Crashlytics)
    debugPrint('Flutter error: ${details.toString()}');
    // Optionally show a user-friendly error screen
    if (kReleaseMode) {
      // You can call a custom error screen handler here
    }
  };

  // Initialize Firebase with error handling
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint('Firebase initialization failed: $e');
    // In a real app, you might show an error screen and retry.
    // For simplicity, we rethrow to let the error handler catch it.
    rethrow;
  }

  // Initialize notifications (should have internal error handling)
  await NotificationService.init();

  // Initialize background service (mobile only)
  if (!kIsWeb) {
    try {
      await initBackgroundService();
    } catch (e) {
      debugPrint('Background service init failed: $e');
    }
  } else {
    debugPrint('Web: skipping background services');
  }

  // Initialize IAP service (optional, uncomment when needed)
  final iap = IAPService();
  await iap.init();

  // Create auth provider and initialize it (starts listening to Firebase Auth)
  final authProvider = AuthProvider();


  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: authProvider),
        ChangeNotifierProvider(create: (_) => BleProvider()),
        ChangeNotifierProvider(create: (_) => DashboardProvider()),
        ChangeNotifierProvider(create: (_) => InsightProvider(iap)),
      ],
      child: const GuardianWristApp(),
    ),
  );
}
