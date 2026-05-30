import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'config/theme.dart';
import 'providers/auth_provider.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/dashboard/screens/dashboard_screen.dart';
import 'features/onboarding/screens/onboarding_screen.dart';

class GuardianWristApp extends StatelessWidget {
  const GuardianWristApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GuardianWrist',
      debugShowCheckedModeBanner: false,
      theme:      AppTheme.light,
      darkTheme:  AppTheme.dark,
      themeMode:  ThemeMode.system,
      home: const _RootGate(),
    );
  }
}

/// Decides: onboarding → login → dashboard in that order.
class _RootGate extends StatefulWidget {
  const _RootGate();
  @override
  State<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<_RootGate> {
  late Future<bool> _onboardedFuture;

  @override
  void initState() {
    super.initState();
    _onboardedFuture = OnboardingScreen.hasCompleted();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _onboardedFuture,
      builder: (ctx, snap) {
        // Splash while checking prefs
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // First time? Show onboarding
        if (!snap.data!) return const OnboardingScreen();

        // Onboarded — now check Firebase auth state
        return Consumer<AuthProvider>(
          builder: (ctx, auth, _) {
            if (auth.isLoading) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            return auth.isAuthenticated
                ? const DashboardScreen()
                : const LoginScreen();
          },
        );
      },
    );
  }
}