// ════════════════════════════════════════════════════════════════════════════
// lib/features/auth/screens/login_screen.dart
// ════════════════════════════════════════════════════════════════════════════
//
// ROUTING
// -------
// This screen does NOT navigate anywhere after a successful sign-in.
// The _RootGate in app.dart watches AuthProvider.isAuthenticated and
// swaps to DashboardScreen automatically. Calling Navigator here would
// fight the gate and put a second Dashboard on the stack.
//

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/auth_provider.dart' as auth_provider;
import '../../../services/auth_service.dart' show AuthServiceException;

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  final FocusNode _nameFocus = FocusNode();
  final FocusNode _emailFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  bool _isLogin = true;
  bool _obscurePassword = true;

  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );

    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );

    _fadeController.forward();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();

    _nameFocus.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();

    _fadeController.dispose();

    super.dispose();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _showSnackBar(String message, {bool isError = true}) {
    if (!mounted) return;

    final theme = Theme.of(context);
    final messenger = ScaffoldMessenger.of(context);

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? theme.colorScheme.error
            : theme.colorScheme.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  bool _isValidEmail(String email) {
    if (email.length > 254) return false;
    final pattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    return pattern.hasMatch(email);
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    final formState = _formKey.currentState;
    if (formState == null || !formState.validate()) return;

    FocusScope.of(context).unfocus();

    final auth = context.read<auth_provider.AuthProvider>();
    auth.clearError();

    final email = _emailController.text.trim().toLowerCase();
    final password = _passwordController.text;
    final wasLoginMode = _isLogin;

    try {
      if (wasLoginMode) {
        await auth.signInWithEmail(email, password);
      } else {
        final name = _nameController.text.trim();
        await auth.register(email, password, name);
      }

      if (!mounted) return;

      if (!auth.isAuthenticated) {
        // Sign-in resolved but no user — surface the provider's error.
        final error = auth.error;
        _showSnackBar(
          error?.message ?? 'Authentication failed. Please try again.',
        );
        return;
      }

      if (!wasLoginMode) {
        _showSnackBar(
          'Account created successfully. Welcome to Guardian Watch!',
          isError: false,
        );
      }

      // No navigation. The _RootGate watches auth.isAuthenticated and
      // swaps this screen for DashboardScreen on its next rebuild.
    } catch (e) {
      if (!mounted) return;
      _showSnackBar(_displayError(context, e));
    }
  }

  Future<void> _resetPassword() async {
    final email = _emailController.text.trim().toLowerCase();

    if (email.isEmpty || !_isValidEmail(email)) {
      _showSnackBar('Please enter a valid email address first.');
      return;
    }

    FocusScope.of(context).unfocus();

    final auth = context.read<auth_provider.AuthProvider>();
    auth.clearError();

    try {
      await auth.sendPasswordResetEmail(email);

      if (!mounted) return;

      _showSnackBar(
        'Password reset instructions have been sent to your email.',
        isError: false,
      );
    } catch (e) {
      if (!mounted) return;
      _showSnackBar(_displayError(context, e));
    }
  }

  Future<void> _signInWithGoogle() async {
    FocusScope.of(context).unfocus();

    final auth = context.read<auth_provider.AuthProvider>();
    auth.clearError();

    try {
      await auth.signInWithGoogle();

      if (!mounted) return;

      if (!auth.isAuthenticated) {
        final error = auth.error;
        _showSnackBar(error?.message ?? 'Google sign-in did not complete.');
        return;
      }

      // No navigation — the _RootGate handles the transition.
    } catch (e) {
      if (!mounted) return;
      _showSnackBar(_displayError(context, e));
    }
  }

  /// Extracts a user-safe message from any error.
  ///
  /// Prefers the provider's own error state when set, since that has
  /// already been mapped by `AuthProvider._firebaseMessage()`. Falls
  /// back to a generic message for unexpected errors.
  String _displayError(BuildContext context, Object error) {
    final providerError = context.read<auth_provider.AuthProvider>().error;
    if (providerError != null && providerError.cause == error) {
      return providerError.message;
    }

    if (error is AuthServiceException) {
      return error.message;
    }

    if (error is FirebaseAuthException) {
      // Fallback path — normally the provider has already mapped this.
      return error.message ?? 'Authentication failed. Please try again.';
    }

    return 'Something went wrong. Please try again.';
  }

  void _setMode(bool loginMode) {
    if (_isLogin == loginMode) return;

    context.read<auth_provider.AuthProvider>().clearError();

    setState(() {
      _isLogin = loginMode;
      _nameController.clear();
      _passwordController.clear();
      _formKey.currentState?.reset();
    });

    _fadeController
      ..reset()
      ..forward();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isLogin) {
        _emailFocus.requestFocus();
      } else {
        _nameFocus.requestFocus();
      }
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final auth = context.watch<auth_provider.AuthProvider>();

    // Only gate the form on the auth operation itself — not on
    // "app is initializing". The gate is responsible for waiting until
    // the initial auth state is resolved.
    final busy = auth.isAuthenticating;

    return Scaffold(
      body: SafeArea(
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 24),
                    _buildBrandSection(colorScheme),
                    const SizedBox(height: 36),
                    _buildModeToggle(colorScheme, busy),
                    const SizedBox(height: 24),
                    if (!_isLogin) ...[
                      TextFormField(
                        controller: _nameController,
                        focusNode: _nameFocus,
                        textInputAction: TextInputAction.next,
                        enabled: !busy,
                        textCapitalization: TextCapitalization.words,
                        style: const TextStyle(fontSize: 16),
                        decoration: _inputDecoration(
                          colorScheme,
                          label: 'Full Name',
                          hint: 'Enter your full name',
                          icon: Icons.person_outline,
                        ),
                        onFieldSubmitted: (_) => _emailFocus.requestFocus(),
                        validator: (value) {
                          final name = value?.trim() ?? '';
                          if (name.isEmpty) return 'Your name is required';
                          if (name.length < 2) return 'Enter a valid name';
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextFormField(
                      controller: _emailController,
                      focusNode: _emailFocus,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      enabled: !busy,
                      style: const TextStyle(fontSize: 16),
                      decoration: _inputDecoration(
                        colorScheme,
                        label: 'Email Address',
                        hint: 'Enter your email address',
                        icon: Icons.mail_outline,
                      ),
                      onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
                      validator: (value) {
                        final email = value?.trim() ?? '';
                        if (email.isEmpty) return 'Email is required';
                        if (!_isValidEmail(email)) {
                          return 'Enter a valid email address';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      focusNode: _passwordFocus,
                      obscureText: _obscurePassword,
                      enabled: !busy,
                      textInputAction: TextInputAction.done,
                      autofillHints: _isLogin
                          ? const [AutofillHints.password]
                          : const [AutofillHints.newPassword],
                      style: const TextStyle(fontSize: 16),
                      decoration: _inputDecoration(
                        colorScheme,
                        label: 'Password',
                        hint: 'Enter your password',
                        icon: Icons.lock_outline,
                        suffix: IconButton(
                          tooltip: _obscurePassword
                              ? 'Show password'
                              : 'Hide password',
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            color: colorScheme.onSurface.withValues(
                              alpha: 0.55,
                            ),
                          ),
                          onPressed: busy
                              ? null
                              : () {
                                  setState(() {
                                    _obscurePassword = !_obscurePassword;
                                  });
                                },
                        ),
                      ),
                      onFieldSubmitted: (_) => _submit(),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Password is required';
                        }
                        if (!_isLogin && value.length < 6) {
                          return 'Password must be at least 6 characters';
                        }
                        return null;
                      },
                    ),
                    if (_isLogin)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: busy ? null : _resetPassword,
                          style: TextButton.styleFrom(
                            foregroundColor: colorScheme.primary,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                          ),
                          child: const Text('Forgot password?'),
                        ),
                      ),
                    if (auth.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _buildErrorBanner(
                          colorScheme,
                          auth.error!.message,
                        ),
                      ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: busy ? null : _submit,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: busy
                            ? SizedBox(
                                key: const ValueKey('auth-loading'),
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: colorScheme.onPrimary,
                                ),
                              )
                            : Text(
                                _isLogin ? 'Sign In' : 'Create Account',
                                key: ValueKey(_isLogin ? 'signin' : 'register'),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: busy ? null : () => _setMode(!_isLogin),
                      child: Text(
                        _isLogin
                            ? "Don't have an account? Create one"
                            : 'Already have an account? Sign in',
                        style: TextStyle(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildDividerWithText('or continue with', colorScheme),
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      onPressed: busy ? null : _signInWithGoogle,
                      icon: busy
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: colorScheme.primary,
                              ),
                            )
                          : const Icon(Icons.account_circle_outlined, size: 24),
                      label: Text(
                        busy ? 'Signing in...' : 'Continue with Google',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        side: BorderSide(
                          color: colorScheme.outlineVariant.withValues(
                            alpha: 0.7,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildTermsText(colorScheme),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── UI pieces ─────────────────────────────────────────────────────────────

  Widget _buildTermsText(ColorScheme colorScheme) {
    // TODO(compliance):
    //   Replace plain text with tappable links to the Terms of Service and
    //   Privacy Policy. The Nigeria Data Protection Act 2023 requires that
    //   users can read the privacy policy before consenting. Wire these to
    //   in-app pages or external URLs.
    return Text(
      'By continuing, you agree to the Guardian Watch Terms of Service '
      'and Privacy Policy.',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 12,
        height: 1.4,
        color: colorScheme.onSurface.withValues(alpha: 0.55),
      ),
    );
  }

  InputDecoration _inputDecoration(
    ColorScheme colorScheme, {
    required String label,
    required String hint,
    required IconData icon,
    Widget? suffix,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(
        icon,
        color: colorScheme.primary.withValues(alpha: 0.75),
      ),
      suffixIcon: suffix,
      filled: true,
      fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: colorScheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: colorScheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: colorScheme.error, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );
  }

  Widget _buildErrorBanner(ColorScheme colorScheme, String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: colorScheme.errorContainer.withValues(alpha: 0.65),
        border: Border.all(color: colorScheme.error.withValues(alpha: 0.20)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 20, color: colorScheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: colorScheme.onErrorContainer,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Dismiss',
            icon: Icon(
              Icons.close,
              size: 18,
              color: colorScheme.onErrorContainer,
            ),
            onPressed: () =>
                context.read<auth_provider.AuthProvider>().clearError(),
          ),
        ],
      ),
    );
  }

  Widget _buildBrandSection(ColorScheme colorScheme) {
    return Column(
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [colorScheme.primary, colorScheme.secondary],
            ),
            boxShadow: [
              BoxShadow(
                color: colorScheme.primary.withValues(alpha: 0.22),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Icon(
            Icons.monitor_heart_outlined,
            size: 42,
            color: colorScheme.onPrimary,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Guardian Watch',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Your health, always on your wrist',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: colorScheme.onSurface.withValues(alpha: 0.60),
          ),
        ),
      ],
    );
  }

  Widget _buildModeToggle(ColorScheme colorScheme, bool busy) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildModeButton(
              title: 'Sign In',
              selected: _isLogin,
              enabled: !busy,
              colorScheme: colorScheme,
              onTap: () => _setMode(true),
            ),
          ),
          Expanded(
            child: _buildModeButton(
              title: 'Register',
              selected: !_isLogin,
              enabled: !busy,
              colorScheme: colorScheme,
              onTap: () => _setMode(false),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeButton({
    required String title,
    required bool selected,
    required bool enabled,
    required ColorScheme colorScheme,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          color: selected ? colorScheme.primary : Colors.transparent,
        ),
        child: Center(
          child: Text(
            title,
            style: TextStyle(
              color: selected
                  ? colorScheme.onPrimary
                  : colorScheme.onSurface.withValues(alpha: 0.60),
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDividerWithText(String text, ColorScheme colorScheme) {
    return Row(
      children: [
        Expanded(
          child: Divider(
            thickness: 1,
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            text,
            style: TextStyle(
              color: colorScheme.onSurface.withValues(alpha: 0.50),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Divider(
            thickness: 1,
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }
}
