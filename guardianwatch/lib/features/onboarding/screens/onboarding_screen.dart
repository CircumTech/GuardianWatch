// ════════════════════════════════════════════════════════════════════════════
// lib/features/onboarding/screens/onboarding_screen.dart
// ════════════════════════════════════════════════════════════════════════════
//
// Onboarding flow.
//
// ROUTING
// -------
// This screen does NOT push LoginScreen. When the user finishes or skips,
// it calls GuardianWristApp.markOnboardingCompleted() which updates the
// shared ValueNotifier. The _RootGate listens to that notifier and swaps
// to the appropriate screen.
//
// PERSISTENCE
// -----------
// Completion is stored under AppConstants.keyOnboardingCompleted, the
// same key used by the rest of the app.
//

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app.dart';
import '../../../config/constants.dart';

// ════════════════════════════════════════════════════════════════════════════
// Onboarding screen
// ════════════════════════════════════════════════════════════════════════════

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  /// Returns true if the user has already completed onboarding.
  static Future<bool> hasCompleted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(AppConstants.keyOnboardingCompleted) ?? false;
    } catch (e) {
      debugPrint('Guardian onboarding status read failed: $e');
      return false;
    }
  }

  /// Persists the completion flag.
  ///
  /// Does not notify the gate. Use
  /// [GuardianWristApp.markOnboardingCompleted] when you want the whole
  /// app to react as well.
  static Future<void> setCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.keyOnboardingCompleted, true);
  }

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();

  int _currentPage = 0;
  bool _isFinishing = false;

  final List<OnboardingPageData> _pages = const [
    OnboardingPageData(
      icon: Icons.monitor_heart_outlined,
      color: Color(0xFF00B4D8),
      title: 'Real-time Health Monitoring',
      subtitle:
          'Connect your Guardian Watch to monitor heart rate, blood oxygen, '
          'skin temperature, and ECG from one place.',
    ),
    OnboardingPageData(
      icon: Icons.auto_awesome_outlined,
      color: Color(0xFF9B5DE5),
      title: 'Wellness Insights',
      subtitle:
          'Track wellness trends and recovery patterns over time. '
          'Guardian Watch provides engineering indicators — not medical '
          'diagnoses.',
    ),
    OnboardingPageData(
      icon: Icons.shield_outlined,
      color: Color(0xFF2DC653),
      title: 'Private & Secure',
      subtitle:
          'Your Guardian account is protected with secure authentication, '
          'controlled data access, and encrypted network communication.',
    ),
    OnboardingPageData(
      icon: Icons.notifications_active_outlined,
      color: Color(0xFFFF6B35),
      title: 'Personalized Alerts',
      subtitle:
          'Receive notifications when monitored readings move outside the '
          'alert ranges you configure in Guardian Watch.',
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // ── Navigation within the flow ────────────────────────────────────────────

  Future<void> _finishOnboarding() async {
    if (_isFinishing) return;

    setState(() => _isFinishing = true);

    try {
      // Notifies the gate, which swaps to Login or Dashboard.
      await GuardianWristApp.markOnboardingCompleted();
      // No Navigator call — the gate rebuilds and this widget is disposed.
    } catch (e, stack) {
      debugPrint('Guardian onboarding completion failed: $e');
      debugPrintStack(stackTrace: stack);

      if (!mounted) return;

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text(
              'We could not save your onboarding progress. Please try again.',
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );

      setState(() => _isFinishing = false);
    }
  }

  Future<void> _nextPage() async {
    if (_isFinishing) return;

    if (_currentPage < _pages.length - 1) {
      await _pageController.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
      return;
    }

    await _finishOnboarding();
  }

  Future<void> _skipOnboarding() async {
    if (_isFinishing) return;
    await _finishOnboarding();
  }

  void _onPageChanged(int index) {
    if (!mounted) return;
    setState(() => _currentPage = index);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final mediaQuery = MediaQuery.of(context);
    final isSmallWidth = mediaQuery.size.width < 400;
    final isShortScreen = mediaQuery.size.height < 700;
    final isLastPage = _currentPage == _pages.length - 1;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Semantics(
                    label:
                        'Onboarding page ${_currentPage + 1} of ${_pages.length}',
                    child: Text(
                      '${_currentPage + 1}/${_pages.length}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                  if (!isLastPage)
                    TextButton(
                      onPressed: _isFinishing ? null : _skipOnboarding,
                      style: TextButton.styleFrom(
                        foregroundColor: colorScheme.primary,
                      ),
                      child: const Text('Skip'),
                    )
                  else
                    const SizedBox(width: 72),
                ],
              ),
            ),

            // ── Pages ──────────────────────────────────────────────────
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _pages.length,
                onPageChanged: _onPageChanged,
                itemBuilder: (context, index) => _OnboardingPage(
                  data: _pages[index],
                  isSmall: isSmallWidth,
                  compact: isShortScreen,
                ),
              ),
            ),

            // ── Bottom controls ────────────────────────────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(
                28,
                isShortScreen ? 10 : 20,
                28,
                isShortScreen ? 16 : 24,
              ),
              child: Column(
                children: [
                  Semantics(
                    label: 'Page ${_currentPage + 1} of ${_pages.length}',
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(_pages.length, (index) {
                        final selected = _currentPage == index;
                        return Semantics(
                          label: 'Go to page ${index + 1}',
                          selected: selected,
                          child: GestureDetector(
                            onTap: _isFinishing
                                ? null
                                : () => _pageController.animateToPage(
                                    index,
                                    duration: const Duration(milliseconds: 350),
                                    curve: Curves.easeInOut,
                                  ),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 250),
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              width: selected ? 28 : 8,
                              height: 8,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                color: selected
                                    ? colorScheme.primary
                                    : colorScheme.onSurface.withValues(
                                        alpha: 0.15,
                                      ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),

                  const SizedBox(height: 24),

                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _isFinishing ? null : _nextPage,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(54),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: _isFinishing
                            ? const SizedBox(
                                key: ValueKey('loading'),
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                ),
                              )
                            : Text(
                                isLastPage ? 'Get Started' : 'Next',
                                key: ValueKey(isLastPage ? 'start' : 'next'),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Onboarding page data
// ════════════════════════════════════════════════════════════════════════════

class OnboardingPageData {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;

  const OnboardingPageData({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
  });
}

// ════════════════════════════════════════════════════════════════════════════
// Individual onboarding page
// ════════════════════════════════════════════════════════════════════════════

class _OnboardingPage extends StatelessWidget {
  final OnboardingPageData data;
  final bool isSmall;
  final bool compact;

  const _OnboardingPage({
    required this.data,
    required this.isSmall,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final iconSize = isSmall ? 54.0 : 64.0;
    final circleSize = isSmall ? 120.0 : 140.0;

    // Scrollable so short screens can still view all content,
    // while minHeight keeps the content vertically centred on tall screens.
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isSmall ? 28 : 36,
                vertical: compact ? 24 : 40,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: circleSize,
                    height: circleSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          data.color.withValues(alpha: 0.15),
                          data.color.withValues(alpha: 0.05),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: data.color.withValues(alpha: 0.15),
                          blurRadius: 30,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Icon(data.icon, size: iconSize, color: data.color),
                  ),

                  SizedBox(height: compact ? 28 : 40),

                  Text(
                    data.title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: isSmall ? 22 : 26,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                      letterSpacing: 0.2,
                      height: 1.15,
                    ),
                  ),

                  SizedBox(height: compact ? 12 : 16),

                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Text(
                      data.subtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: isSmall ? 14 : 16,
                        height: 1.6,
                        color: colorScheme.onSurface.withValues(alpha: 0.65),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
