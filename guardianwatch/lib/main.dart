// ─── lib/main.dart ────────────────────────────────────────────────────────────
//
// Guardian Watch application entry point.
//
// BOOT ORDER
// ----------
//   1. Flutter bindings + native splash
//   2. Firebase
//   3. ThemeProvider (needs to be ready before MaterialApp builds)
//   4. AuthService + Google Sign-In
//   5. Notifications
//   6. Background service configuration
//   7. IAP service
//   8. Providers
//   9. runApp
//
// A single AuthService instance is created here and shared with the
// AuthProvider. This matters because AuthService registers a session-
// expired callback on ApiService.shared in its constructor — creating
// two instances would overwrite that handler.
//
// A single IAPService instance is created here and passed to
// InsightProvider. IAPService opens a platform purchase stream in its
// constructor; two instances would double-subscribe.
//

import 'dart:async';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'config/constants.dart';
import 'firebase_options.dart';

import 'providers/auth_provider.dart';
import 'providers/ble_provider.dart';
import 'providers/dashboard_provider.dart';
import 'providers/insight_provider.dart';
import 'providers/theme_provider.dart';

import 'services/auth_service.dart';
import 'services/background_service.dart';
import 'services/iap_service.dart';
import 'services/notification_service.dart';

// ════════════════════════════════════════════════════════════════════════════
// Entry point
// ════════════════════════════════════════════════════════════════════════════

Future<void> main() async {
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();

  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  // ── Global error handlers ───────────────────────────────────────────────

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
    debugPrint('Guardian Flutter error: ${details.exception}');
    if (details.stack != null) {
      debugPrintStack(stackTrace: details.stack!);
    }
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('Guardian platform error: $error');
    debugPrintStack(stackTrace: stack);
    return true;
  };

  // ── Firebase ────────────────────────────────────────────────────────────
  //
  // Hard requirement. If this fails, the app cannot function.

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    debugPrint('Guardian Firebase initialized.');
  } catch (e, stack) {
    debugPrint('Guardian Firebase init failed: $e');
    debugPrintStack(stackTrace: stack);
    FlutterNativeSplash.remove();
    runApp(const _StartupFailureApp());
    return;
  }

  // ── ThemeProvider ───────────────────────────────────────────────────────
  //
  // Loaded before runApp so the first frame renders with the correct theme.

  final themeProvider = ThemeProvider();
  try {
    await themeProvider.load();
    debugPrint('Guardian ThemeProvider initialized.');
  } catch (e, stack) {
    debugPrint('Guardian ThemeProvider load failed: $e');
    debugPrintStack(stackTrace: stack);
  }

  // ── AuthService + Google Sign-In ────────────────────────────────────────
  //
  // One instance, shared with AuthProvider.
  //
  // Google Sign-In failure is non-fatal — email/password still work.

  final authService = AuthService();

  if (!kIsWeb) {
    try {
      await authService.initGoogleSignIn(
        clientId: AppConstants.googleClientId,
        serverClientId: AppConstants.googleServerClientId.isEmpty
            ? null
            : AppConstants.googleServerClientId,
      );
      debugPrint('Guardian Google Sign-In initialized.');
    } catch (e, stack) {
      debugPrint('Guardian Google Sign-In init failed: $e');
      debugPrintStack(stackTrace: stack);
      // Continue — the login screen still allows email/password.
    }
  }

  // ── Notifications ───────────────────────────────────────────────────────
  //
  // Non-fatal. If initialization fails, alerts are silently unavailable.

  if (!kIsWeb) {
    try {
      await NotificationService.init();
      debugPrint('Guardian notifications initialized.');
    } catch (e, stack) {
      debugPrint('Guardian notification init failed: $e');
      debugPrintStack(stackTrace: stack);
    }
  }

  // ── Background service ──────────────────────────────────────────────────
  //
  // Non-fatal. Configures the service but does not start it.

  if (!kIsWeb) {
    try {
      await initBackgroundService();
      debugPrint('Guardian background service configured.');
    } catch (e, stack) {
      debugPrint('Guardian background service config failed: $e');
      debugPrintStack(stackTrace: stack);
    }
  }

  // ── IAPService ──────────────────────────────────────────────────────────
  //
  // One instance, shared with InsightProvider.
  // Non-fatal. If the store is unavailable, the paywall shows an error.

  final iapService = IAPService();

  if (!kIsWeb) {
    try {
      await iapService.init();
      debugPrint('Guardian IAP initialized.');
    } catch (e, stack) {
      debugPrint('Guardian IAP initialization failed: $e');
      debugPrintStack(stackTrace: stack);
    }
  }

  // ── Providers ───────────────────────────────────────────────────────────
  //
  // Constructed manually so the exact same instances are used throughout
  // the app.
  //
  // Dependency graph:
  //
  //   AuthService to AuthProvider
  //   IAPService  to InsightProvider to BleProvider
  //
  // All providers are provided via `.value` because they are constructed
  // here and therefore not owned by Provider for disposal.

  final authProvider = AuthProvider(service: authService);
  final insightProvider = InsightProvider(iapService);
  final bleProvider = BleProvider(insightProvider);
  final dashboardProvider = DashboardProvider();

  // ── Launch ──────────────────────────────────────────────────────────────

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
        ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
        ChangeNotifierProvider<InsightProvider>.value(value: insightProvider),
        ChangeNotifierProvider<BleProvider>.value(value: bleProvider),
        ChangeNotifierProvider<DashboardProvider>.value(
          value: dashboardProvider,
        ),
      ],
      child: const GuardianWristApp(),
    ),
  );

  // Remove the native splash after the first Flutter frame.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    FlutterNativeSplash.remove();
  });
}

// ════════════════════════════════════════════════════════════════════════════
// Startup failure UI
// ════════════════════════════════════════════════════════════════════════════
//
// Only shown when Firebase itself cannot initialize. That is the one
// startup step the app cannot recover from.

class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Guardian Watch',
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 64),
                  const SizedBox(height: 20),
                  const Text(
                    'Guardian Watch could not start',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'A required service failed to initialize. '
                    'Close the app and open it again. If the problem '
                    'persists, reinstall the app.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    // Exits the app. Flutter cannot programmatically
                    // restart a process; the user reopens from the launcher.
                    onPressed: () {
                      // ignore: deprecated_member_use
                      SystemNavigator.pop();
                    },
                    icon: const Icon(Icons.close),
                    label: const Text('Close App'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
