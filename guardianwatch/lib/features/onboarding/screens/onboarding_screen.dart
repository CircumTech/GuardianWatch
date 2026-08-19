// ════════════════════════════════════════════════════════════════════════════
// lib/features/onboarding/screens/onboarding_screen.dart
// ════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../auth/screens/login_screen.dart';

// ============================================================================
// Onboarding Screen
// ============================================================================

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  static const String _prefKey = 'gw_onboarded';

  static Future<bool> hasCompleted() async {
    try {
      // For demo purposes, return true to skip. In production, uncomment:
      // final prefs = await SharedPreferences.getInstance();
      // return prefs.getBool(_prefKey) ?? false;
      await Future.delayed(const Duration(seconds: 1));
      return true;
    } catch (e) {
      debugPrint('Error reading onboarding status: $e');
      return false;
    }
  }

  static Future<void> setCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, true);
  }

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _isFinishing = false;

  // Animation for dot indicators
  late final AnimationController _dotController;
  late final Animation<double> _dotAnimation;

  final List<OnboardingPageData> _pages = const [
    OnboardingPageData(
      icon: Icons.monitor_heart_outlined,
      color: Color(0xFF00B4D8),
      title: 'Real-time Health Monitoring',
      subtitle:
          'Connect your GuardianWrist to track heart rate, blood oxygen, '
          'temperature, and ECG — all in one place.',
    ),
    OnboardingPageData(
      icon: Icons.auto_awesome_outlined,
      color: Color(0xFF9B5DE5),
      title: 'AI-Powered Insights',
      subtitle:
          'Our artificial intelligence analyzes your health data to detect '
          'early signs of arrhythmia, sleep apnea, and more.',
    ),
    OnboardingPageData(
      icon: Icons.shield_outlined,
      color: Color(0xFF2DC653),
      title: 'Private & Secure',
      subtitle:
          'Your health data is encrypted in transit and at rest. '
          'We are HIPAA-aligned and GDPR compliant.',
    ),
    OnboardingPageData(
      icon: Icons.notifications_active_outlined,
      color: Color(0xFFFF6B35),
      title: 'Instant Alerts',
      subtitle:
          'Get notified the moment your heart rate or blood oxygen '
          'goes outside your personal safe zone.',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _dotController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _dotAnimation = CurvedAnimation(
      parent: _dotController,
      curve: Curves.easeOut,
    );
    _dotController.forward();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _dotController.dispose();
    super.dispose();
  }

  Future<void> _finishOnboarding() async {
    if (_isFinishing) return;
    setState(() => _isFinishing = true);

    try {
      await OnboardingScreen.setCompleted();
      if (!mounted) return;
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving progress: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
      setState(() => _isFinishing = false);
    }
  }

  void _nextPage() {
    if (_currentPage < _pages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    } else {
      _finishOnboarding();
    }
  }

  void _skipOnboarding() {
    _finishOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    final isLastPage = _currentPage == _pages.length - 1;
    final cs = Theme.of(context).colorScheme;
    final screenSize = MediaQuery.of(context).size;
    final isSmall = screenSize.width < 400;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Top bar with skip button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (!isLastPage)
                    TextButton(
                      onPressed: _isFinishing ? null : _skipOnboarding,
                      style: TextButton.styleFrom(
                        foregroundColor: cs.onSurface.withOpacity(0.5),
                      ),
                      child: const Text('Skip'),
                    ),
                ],
              ),
            ),
            // Page View
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _pages.length,
                onPageChanged: (index) {
                  setState(() => _currentPage = index);
                  _dotController.reset();
                  _dotController.forward();
                },
                itemBuilder: (context, index) =>
                    _OnboardingPage(data: _pages[index], isSmall: isSmall),
              ),
            ),
            // Bottom section: dots + button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
              child: Column(
                children: [
                  // Dot indicators
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(_pages.length, (index) {
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: _currentPage == index ? 28 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          color: _currentPage == index
                              ? cs.primary
                              : cs.onSurface.withOpacity(0.15),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 24),
                  // Action button
                  FilledButton(
                    onPressed: _isFinishing ? null : _nextPage,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      backgroundColor: cs.primary,
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: _isFinishing
                          ? const SizedBox(
                              key: ValueKey('loading'),
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              key: ValueKey(isLastPage ? 'start' : 'next'),
                              isLastPage ? 'Get Started' : 'Next',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
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

// ============================================================================
// Onboarding Page Data Model
// ============================================================================

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

// ============================================================================
// Individual Onboarding Page Widget
// ============================================================================

class _OnboardingPage extends StatelessWidget {
  final OnboardingPageData data;
  final bool isSmall;

  const _OnboardingPage({required this.data, required this.isSmall});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Icon container with gradient background
          Container(
            width: isSmall ? 120 : 140,
            height: isSmall ? 120 : 140,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  data.color.withOpacity(0.15),
                  data.color.withOpacity(0.05),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: data.color.withOpacity(0.15),
                  blurRadius: 30,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Icon(data.icon, size: isSmall ? 54 : 64, color: data.color),
          ),
          const SizedBox(height: 40),
          // Title
          Text(
            data.title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: isSmall ? 22 : 26,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 16),
          // Subtitle
          Text(
            data.subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: isSmall ? 14 : 16,
              height: 1.6,
              color: cs.onSurface.withOpacity(0.65),
            ),
          ),
        ],
      ),
    );
  }
}
