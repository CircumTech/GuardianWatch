// ════════════════════════════════════════════════════════════════════════════
// lib/features/onboarding/screens/onboarding_screen.dart
// ════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../auth/screens/login_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  static const String _prefKey = 'gw_onboarded';

  static Future<bool> hasCompleted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_prefKey) ?? false;
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

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _isFinishing = false;

  final List<OnboardingPageData> _pages = const [
    OnboardingPageData(
      icon: Icons.monitor_heart_rounded,
      color: Color(0xFF00B4D8),
      title: 'Real-time health monitoring',
      subtitle: 'Connect your GuardianWrist to track heart rate, SpO₂, '
          'temperature, and ECG — all in one place.',
    ),
    OnboardingPageData(
      icon: Icons.auto_awesome,
      color: Color(0xFF9B5DE5),
      title: 'AI-powered health insights',
      subtitle: 'Our AI analyses your data to detect early signs of '
          'arrhythmia, sleep apnea, and more — before they become problems.',
    ),
    OnboardingPageData(
      icon: Icons.shield_outlined,
      color: Color(0xFF2DC653),
      title: 'Private & secure',
      subtitle: 'Your health data is encrypted in transit and at rest. '
          'We are HIPAA-aligned and GDPR compliant. You own your data.',
    ),
    OnboardingPageData(
      icon: Icons.notifications_active_outlined,
      color: Color(0xFFFF6B35),
      title: 'Instant alerts',
      subtitle: 'Get notified the moment your heart rate or blood oxygen '
          'goes outside your personal safe zone — even in the background.',
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _finishOnboarding() async {
    if (_isFinishing) return;
    setState(() => _isFinishing = true);

    try {
      await OnboardingScreen.setCompleted();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Error saving progress: $e'),
              backgroundColor: Colors.red),
        );
      }
      setState(() => _isFinishing = false);
    }
  }

  void _nextPage() {
    if (_currentPage < _pages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 350),
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
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (!isLastPage)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _isFinishing ? null : _skipOnboarding,
                  child: const Text('Skip'),
                ),
              )
            else
              const SizedBox(height: 48),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _pages.length,
                onPageChanged: (index) => setState(() => _currentPage = index),
                itemBuilder: (context, index) =>
                    _OnboardingPage(data: _pages[index]),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_pages.length, (index) {
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: _currentPage == index ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: _currentPage == index
                        ? theme.colorScheme.primary
                        : Colors.grey.shade400,
                  ),
                );
              }),
            ),
            const SizedBox(height: 32),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: FilledButton(
                onPressed: _isFinishing ? null : _nextPage,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                child: _isFinishing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(isLastPage ? 'Get started' : 'Next'),
              ),
            ),
            const SizedBox(height: 32),
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
  const _OnboardingPage({required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 400;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: isSmallScreen ? 100 : 120,
            height: isSmallScreen ? 100 : 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: data.color.withOpacity(0.15),
            ),
            child: Icon(data.icon,
                size: isSmallScreen ? 50 : 60, color: data.color),
          ),
          const SizedBox(height: 40),
          Text(
            data.title,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              fontSize: isSmallScreen ? 22 : 24,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            data.subtitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.grey.shade600,
              height: 1.6,
              fontSize: isSmallScreen ? 14 : 16,
            ),
          ),
        ],
      ),
    );
  }
}
