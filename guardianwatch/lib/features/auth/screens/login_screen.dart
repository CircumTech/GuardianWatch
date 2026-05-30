// ════════════════════════════════════════════════════════════════════════════
// lib/features/auth/screens/login_screen.dart
// ════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/auth_provider.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  bool _isLogin = true;
  bool _obscure = true;
  bool _isSubmitting = false;
  bool _isGoogleSigning = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSubmitting = true);

    try {
      final auth = context.read<AuthProvider>();
      if (_isLogin) {
        await auth.signInWithEmail(_emailCtrl.text.trim(), _pwCtrl.text.trim());
      } else {
        final displayName = _emailCtrl.text.trim().split('@')[0];
        await auth.register(
            _emailCtrl.text.trim(), _pwCtrl.text.trim(), displayName);
      }
    } catch (e) {
      _showError(e.toString());
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _resetPassword() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !_isValidEmail(email)) {
      _showError('Please enter a valid email address first.');
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      await context.read<AuthProvider>().sendPasswordResetEmail(email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Password reset email sent. Check your inbox.')),
        );
      }
    } catch (e) {
      _showError(e.toString());
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _isGoogleSigning = true);
    try {
      await context.read<AuthProvider>().signInWithGoogle();
    } catch (e) {
      _showError(e.toString());
    } finally {
      if (mounted) setState(() => _isGoogleSigning = false);
    }
  }

  bool _isValidEmail(String email) =>
      RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(email);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final auth = context.watch<AuthProvider>();
    final isLoading = auth.isLoading || _isSubmitting || _isGoogleSigning;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 40),
                Icon(Icons.monitor_heart_rounded, size: 72, color: cs.primary),
                const SizedBox(height: 12),
                Text(
                  'GuardianWrist',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                Text(
                  'Your health, always on your wrist',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 48),
                TextFormField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  enabled: !isLoading,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.email_outlined),
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Email is required';
                    }
                    if (!_isValidEmail(value.trim())) {
                      return 'Enter a valid email address';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _pwCtrl,
                  obscureText: _obscure,
                  enabled: !isLoading,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                          _obscure ? Icons.visibility_off : Icons.visibility),
                      onPressed: isLoading
                          ? null
                          : () => setState(() => _obscure = !_obscure),
                    ),
                  ),
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
                const SizedBox(height: 8),
                if (_isLogin)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: isLoading ? null : _resetPassword,
                      child: const Text('Forgot password?'),
                    ),
                  ),
                if (auth.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(auth.error!, style: TextStyle(color: cs.error)),
                  ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: isLoading ? null : _submit,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: isLoading && !_isGoogleSigning
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(_isLogin ? 'Sign in' : 'Create account'),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: isLoading
                      ? null
                      : () => setState(() {
                            _isLogin = !_isLogin;
                            _formKey.currentState?.reset();
                          }),
                  child: Text(_isLogin
                      ? "Don't have an account? Register"
                      : 'Already have an account? Sign in'),
                ),
                const Divider(),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: isLoading ? null : _signInWithGoogle,
                  icon: _isGoogleSigning
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.g_mobiledata, size: 28),
                  label: const Text('Continue with Google'),
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
