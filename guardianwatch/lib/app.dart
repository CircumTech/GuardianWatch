// ─── lib/app.dart ─────────────────────────────────────────────────────────────
//
// Guardian Watch application root.
//
// ROUTING MODEL
// -------------
// _RootGate is the single source of truth for which primary screen is
// visible. It owns three states:
//
//   1. Not yet onboarded       (OnboardingScreen)
//   2. Onboarded, not signed   (LoginScreen)
//   3. Onboarded, signed in    (DashboardScreen)
//
// Screens do NOT push each other for these three transitions.
// Onboarding just notifies the gate that it is done. Login just signs in.
// Sign-out just signs out. The gate rebuilds and swaps the screen.
//
// Secondary screens (ECG, Profile) are pushed by Dashboard and use
// MaterialPageRoute as normal. The gate does not interfere with those.
//
// NOTIFICATION ROUTING
// --------------------
// Notification tap payloads are delivered via NotificationService.tapStream
// and via NotificationService.consumeInitialPayload() on cold start.
// Both paths are handled here.
//

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'config/theme.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/dashboard/screens/dashboard_screen.dart';
import 'features/onboarding/screens/onboarding_screen.dart';
import 'providers/auth_provider.dart';
import 'providers/theme_provider.dart';
import 'services/notification_service.dart';

// ════════════════════════════════════════════════════════════════════════════
// GuardianWristApp
// ════════════════════════════════════════════════════════════════════════════

class GuardianWristApp extends StatelessWidget {
  const GuardianWristApp({super.key});

  /// Shared navigator key, exposed for future deep-link routing.
  ///
  /// Currently used only by [_RootGateState._routeFromPayload] as a
  /// placeholder for opening sub-screens. Kept public so notification
  /// handlers elsewhere can reference it.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// Emits `true` once onboarding has been completed or skipped.
  ///
  /// `_RootGate` listens to this notifier. `OnboardingScreen` updates it
  /// through [markOnboardingCompleted] rather than pushing a route.
  static final ValueNotifier<bool> _onboardingCompleted = ValueNotifier<bool>(
    false,
  );

  /// Read-only view for the gate.
  static ValueListenable<bool> get onboardingCompleted => _onboardingCompleted;

  /// Persists the completion flag and notifies the gate.
  ///
  /// Called by [OnboardingScreen] when the user finishes or skips.
  static Future<void> markOnboardingCompleted() async {
    await OnboardingScreen.setCompleted();

    if (!_onboardingCompleted.value) {
      _onboardingCompleted.value = true;
    }
  }

  /// Re-reads the persisted onboarding state from disk.
  ///
  /// The gate calls this once on cold start.
  static Future<void> refreshOnboardingState() async {
    final done = await OnboardingScreen.hasCompleted();
    if (_onboardingCompleted.value != done) {
      _onboardingCompleted.value = done;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch the ThemeProvider so theme changes take effect immediately.
    // Previously the theme was hardcoded to ThemeMode.system in this file.
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, _) {
        return MaterialApp(
          title: 'Guardian Watch',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: themeProvider.themeMode,
          home: const _RootGate(),
        );
      },
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Root gate — owns the primary screen decision
// ════════════════════════════════════════════════════════════════════════════

class _RootGate extends StatefulWidget {
  const _RootGate();

  @override
  State<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<_RootGate> {
  StreamSubscription<String>? _notificationTapSubscription;

  /// True once onboarding state has been loaded and any cold-start
  /// notification payload has been consumed.
  bool _ready = false;

  @override
  void initState() {
    super.initState();

    // Subscribe to live notification taps before doing anything else.
    _notificationTapSubscription = NotificationService.tapStream.listen(
      _onNotificationTap,
    );

    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _notificationTapSubscription?.cancel();
    _notificationTapSubscription = null;
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Bootstrap
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _bootstrap() async {
    // 1. Load persisted onboarding state.
    try {
      await GuardianWristApp.refreshOnboardingState();
    } catch (e, stack) {
      debugPrint('Guardian onboarding state load failed: $e');
      debugPrintStack(stackTrace: stack);
    }

    if (!mounted) return;

    // 2. Consume any cold-start notification payload.
    try {
      final payload = NotificationService.consumeInitialPayload();
      if (payload != null && payload.isNotEmpty) {
        await _routeFromPayload(payload);
      }
    } catch (e, stack) {
      debugPrint('Guardian cold-start payload handling failed: $e');
      debugPrintStack(stackTrace: stack);
    }

    if (!mounted) return;

    // 3. Reveal the gate.
    setState(() {
      _ready = true;
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Notification routing
  // ─────────────────────────────────────────────────────────────────────────

  void _onNotificationTap(String payload) {
    unawaited(_routeFromPayload(payload));
  }

  /// Routes a `guardian://...` payload.
  ///
  /// The gate already shows the correct top-level screen based on
  /// onboarding and auth state, so this method's job is limited to
  /// sub-screen navigation (e.g. opening the ECG detail screen for a
  /// specific alert). For now it logs the payload; the actual routing
  /// will be added when the dashboard exposes an alert-highlight
  /// mechanism.
  Future<void> _routeFromPayload(String payload) async {
    final uri = Uri.tryParse(payload);
    if (uri == null || uri.scheme != 'guardian') {
      debugPrint('Guardian ignored non-guardian payload: $payload');
      return;
    }

    debugPrint('Guardian notification payload received: $payload');

    // Placeholder for future deep-link behaviour. The gate already
    // displays the correct screen based on auth state.
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const _RootLoadingView();
    }

    return ValueListenableBuilder<bool>(
      valueListenable: GuardianWristApp.onboardingCompleted,
      builder: (context, onboarded, _) {
        if (!onboarded) {
          return const OnboardingScreen();
        }

        return Consumer<AuthProvider>(
          builder: (context, auth, _) {
            // Gate only on the initial Firebase resolution. During an
            // interactive sign-in the Login screen's own button owns
            // its loading state.
            if (auth.isInitializing) {
              return const _RootLoadingView();
            }

            if (auth.isAuthenticated) {
              return const DashboardScreen();
            }

            return const LoginScreen();
          },
        );
      },
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Root loading UI
// ════════════════════════════════════════════════════════════════════════════

class _RootLoadingView extends StatelessWidget {
  const _RootLoadingView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.favorite_outline,
                size: 36,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Guardian Watch',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
