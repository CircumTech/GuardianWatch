// ════════════════════════════════════════════════════════════════════════════
// lib/features/profile/screens/profile_screen.dart
// ════════════════════════════════════════════════════════════════════════════
//
// Guardian Watch user profile.
//
// DATA SOURCES
// ------------
//   - Firebase Authentication — display name, photo URL, email, emailVerified
//   - Local SharedPreferences — age and gender (namespaced by user ID)
//
// NOTE ON CLOUD PROFILE:
// Firebase Firestore is intentionally NOT used by this screen. The project
// is architected around FastAPI + Firebase Auth. When the backend exposes
// a profile endpoint, replace the local-only age/gender writes with an API
// call. Until then age and gender persist locally per account on this
// device only.
//
// ACCOUNT DELETION
// ----------------
// Firebase account deletion is handled by AuthProvider.deleteAccount,
// which is wired to AuthService.deleteAccount. That method removes the
// account, clears the local SQLite database for the user, and clears the
// session token. Additional provider state cleanup happens here.
//

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../providers/auth_provider.dart';
import '../../../providers/ble_provider.dart';
import '../../../services/health_export_service.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _ageController = TextEditingController();

  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  bool _saving = false;
  bool _deleting = false;
  bool _sendingVerification = false;
  bool _loading = true;

  String _gender = 'Prefer not to say';

  /// Local keys. Namespaced by user ID at read/write time so account A's
  /// profile does not appear when account B signs in on the same device.
  static const String _localNameKey = 'gw_profile_name';
  static const String _localAgeKey = 'gw_profile_age';
  static const String _localGenderKey = 'gw_profile_gender';

  static const List<String> _genderOptions = [
    'Male',
    'Female',
    'Non-binary',
    'Prefer not to say',
  ];

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );

    _loadProfile();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _ageController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Profile loading
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _loadProfile() async {
    try {
      final authUser = firebase_auth.FirebaseAuth.instance.currentUser;

      if (authUser == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }

      final uid = authUser.uid;
      final prefs = await SharedPreferences.getInstance();

      final localName = prefs.getString(_keyForUser(_localNameKey, uid));
      final localAge = prefs.getString(_keyForUser(_localAgeKey, uid));
      final localGender = prefs.getString(_keyForUser(_localGenderKey, uid));

      _nameController.text = localName ?? authUser.displayName ?? '';
      _ageController.text = localAge ?? '';
      _gender = _genderOptions.contains(localGender)
          ? localGender!
          : 'Prefer not to say';
    } catch (e, stack) {
      debugPrint('Guardian profile load failed: $e');
      debugPrintStack(stackTrace: stack);

      if (mounted) {
        _showError('Unable to load your profile.');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _fadeController.forward();
      }
    }
  }

  String _keyForUser(String baseKey, String uid) => '${baseKey}_$uid';

  // ══════════════════════════════════════════════════════════════════════════
  // Profile save
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _saveProfile() async {
    if (_saving || _deleting) return;

    if (!(_formKey.currentState?.validate() ?? false)) return;

    final user = firebase_auth.FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showError('You are no longer signed in.');
      return;
    }

    final name = _nameController.text.trim();
    final age = int.tryParse(_ageController.text.trim());

    setState(() => _saving = true);

    try {
      // 1. Firebase Authentication display name.
      await context.read<AuthProvider>().updateUserProfile(
        displayName: name.isEmpty ? null : name,
      );

      // 2. Local namespaced cache for age and gender.
      //
      // TODO(backend):
      //   Replace with a POST to the FastAPI profile endpoint when it
      //   exists. Today age and gender are local-only.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyForUser(_localNameKey, user.uid), name);
      await prefs.setString(
        _keyForUser(_localAgeKey, user.uid),
        _ageController.text.trim(),
      );
      await prefs.setString(_keyForUser(_localGenderKey, user.uid), _gender);

      if (!mounted) return;

      _showSuccess('Profile saved successfully.');

      _fadeController
        ..reset()
        ..forward();
    } catch (e, stack) {
      debugPrint('Guardian profile save failed: $e');
      debugPrintStack(stackTrace: stack);
      if (mounted) {
        _showError('Unable to save your profile. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Email verification
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _sendVerificationEmail() async {
    if (_saving || _deleting || _sendingVerification) return;

    setState(() => _sendingVerification = true);

    try {
      await context.read<AuthProvider>().sendEmailVerification();
      if (!mounted) return;
      _showSuccess('Verification email sent. Check your inbox.');
    } catch (e, stack) {
      debugPrint('Guardian email verification failed: $e');
      debugPrintStack(stackTrace: stack);
      if (mounted) {
        _showError('Unable to send the verification email.');
      }
    } finally {
      if (mounted) setState(() => _sendingVerification = false);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Account deletion
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _deleteAccount() async {
    if (_deleting) return;

    final confirmed = await _showDeleteConfirmation();
    if (confirmed != true || !mounted) return;

    final user = firebase_auth.FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showError('No signed-in account was found.');
      return;
    }

    final uid = user.uid;

    setState(() => _deleting = true);

    try {
      // 1. Stop Bluetooth so no new health records are generated.
      final ble = context.read<BleProvider>();
      if (ble.isConnected) {
        await ble.disconnect();
      }

      // 2. Delete the Firebase account + local DB + session token.
      await context.read<AuthProvider>().deleteAccount();

      // 3. Remove this user's local profile cache.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyForUser(_localNameKey, uid));
      await prefs.remove(_keyForUser(_localAgeKey, uid));
      await prefs.remove(_keyForUser(_localGenderKey, uid));

      // 4. Clear Health-export opt-in. Firebase remains signed out;
      //    the _RootGate observes the auth change and swaps to login.
      try {
        await HealthExportService.shared().clearOptIn();
      } catch (e) {
        debugPrint('Guardian health-export opt-in clear failed: $e');
      }

      if (!mounted) return;

      _showSuccess('Your Guardian account has been deleted.');
    } catch (e, stack) {
      debugPrint('Guardian account deletion failed: $e');
      debugPrintStack(stackTrace: stack);

      if (!mounted) return;

      setState(() => _deleting = false);
      _showError(_friendlyDeleteError(e));
    }
  }

  String _friendlyDeleteError(Object error) {
    if (error is firebase_auth.FirebaseAuthException) {
      switch (error.code) {
        case 'requires-recent-login':
          return 'For security, please sign in again before deleting '
              'your account.';
        case 'network-request-failed':
          return 'Network connection failed. Please try again.';
      }
    }
    return 'We could not delete your account. Please try again.';
  }

  Future<bool?> _showDeleteConfirmation() {
    final colorScheme = Theme.of(context).colorScheme;

    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Delete account?'),
        content: const Text(
          'This permanently deletes your Guardian account and removes '
          'your local health records from this device. '
          'Cloud health records associated with your account will be '
          'removed according to the retention policy. This action cannot '
          'be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colorScheme.error,
              foregroundColor: colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete Account'),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Validation
  // ══════════════════════════════════════════════════════════════════════════

  String? _validateAge(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;

    final age = int.tryParse(text);
    if (age == null) return 'Enter a valid age.';
    if (age < 13 || age > 120) return 'Enter an age between 13 and 120.';
    return null;
  }

  String? _validateName(String? value) {
    final name = value?.trim() ?? '';
    if (name.isEmpty) return 'Enter your name.';
    if (name.length < 2) return 'Enter a valid name.';
    return null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Feedback
  // ══════════════════════════════════════════════════════════════════════════

  void _showSuccess(String message) {
    if (!mounted) return;
    final colorScheme = Theme.of(context).colorScheme;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: colorScheme.primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
  }

  void _showError(String message) {
    if (!mounted) return;
    final colorScheme = Theme.of(context).colorScheme;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: colorScheme.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Build
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final ble = context.watch<BleProvider>();
    final colorScheme = Theme.of(context).colorScheme;

    final disabled = _saving || _deleting;

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return PopScope(
      // Block the OS back gesture while deletion is in progress.
      canPop: !_deleting,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Profile'),
          elevation: 0,
          backgroundColor: colorScheme.surface,
          surfaceTintColor: colorScheme.surface,
          actions: [
            TextButton(
              onPressed: disabled ? null : _saveProfile,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : const Text(
                      'Save',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
            ),
          ],
        ),
        body: Stack(
          children: [
            FadeTransition(
              opacity: _fadeAnimation,
              child: Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    _buildAvatarSection(auth, colorScheme),
                    const SizedBox(height: 28),
                    _buildProfileForm(colorScheme, disabled),
                    const SizedBox(height: 20),
                    _buildWatchStatusCard(ble, colorScheme, disabled),
                    const SizedBox(height: 20),
                    _buildSecurityCard(auth, colorScheme, disabled),
                    const SizedBox(height: 20),
                    _buildDangerZone(colorScheme, disabled),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),

            if (_deleting)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.55),
                  child: Center(
                    child: Container(
                      margin: const EdgeInsets.all(32),
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: colorScheme.surface,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 18),
                          Text(
                            'Deleting your account...',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Please do not close the app.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurface.withValues(
                                alpha: 0.55,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Avatar
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildAvatarSection(AuthProvider auth, ColorScheme colorScheme) {
    final user = auth.user;
    final photoUrl = user?.photoURL;
    final displayName = user?.displayName?.trim();
    final email = user?.email ?? '';

    final initial = (displayName != null && displayName.isNotEmpty)
        ? displayName[0].toUpperCase()
        : (email.isNotEmpty ? email[0].toUpperCase() : 'U');

    return Column(
      children: [
        Container(
          width: 92,
          height: 92,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colorScheme.primaryContainer,
            border: Border.all(
              color: colorScheme.primary.withValues(alpha: 0.18),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: colorScheme.primary.withValues(alpha: 0.15),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipOval(
            child: photoUrl != null && photoUrl.isNotEmpty
                ? Image.network(
                    photoUrl,
                    fit: BoxFit.cover,
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) return child;
                      return _AvatarLetter(
                        letter: initial,
                        colorScheme: colorScheme,
                      );
                    },
                    errorBuilder: (context, error, stack) => _AvatarLetter(
                      letter: initial,
                      colorScheme: colorScheme,
                    ),
                  )
                : _AvatarLetter(letter: initial, colorScheme: colorScheme),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          displayName?.isNotEmpty == true ? displayName! : 'Guardian User',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          email,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: colorScheme.onSurface.withValues(alpha: 0.50),
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Profile form
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildProfileForm(ColorScheme colorScheme, bool disabled) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Personal Information',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _nameController,
              enabled: !disabled,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: _inputDecoration(
                colorScheme,
                label: 'Display Name',
                hint: 'Your full name',
                icon: Icons.person_outline,
              ),
              validator: _validateName,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _ageController,
              enabled: !disabled,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
              decoration: _inputDecoration(
                colorScheme,
                label: 'Age',
                hint: 'Optional',
                icon: Icons.cake_outlined,
              ),
              validator: _validateAge,
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _gender,
              decoration: _inputDecoration(
                colorScheme,
                label: 'Gender',
                hint: 'Select an option',
                icon: Icons.person_outline,
              ),
              items: _genderOptions
                  .map(
                    (value) => DropdownMenuItem<String>(
                      value: value,
                      child: Text(value),
                    ),
                  )
                  .toList(),
              onChanged: disabled
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() => _gender = value);
                    },
            ),
            const SizedBox(height: 10),
            Text(
              'Optional profile information is used to personalize '
              'Guardian features. Age and gender are stored locally on '
              'this device only.',
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: colorScheme.onSurface.withValues(alpha: 0.50),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Watch status
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildWatchStatusCard(
    BleProvider ble,
    ColorScheme colorScheme,
    bool disabled,
  ) {
    final connected = ble.isConnected;
    final battery = ble.battery;

    final statusText = connected
        ? (battery != null ? 'Connected • $battery% battery' : 'Connected')
        : ble.status == BleStatus.error
        ? 'Connection error'
        : 'Not connected';

    final statusColor = connected
        ? colorScheme.primary
        : ble.status == BleStatus.error
        ? colorScheme.error
        : colorScheme.onSurface.withValues(alpha: 0.55);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: statusColor.withValues(alpha: 0.10),
              ),
              child: Icon(
                connected
                    ? Icons.bluetooth_connected
                    : Icons.bluetooth_disabled,
                color: statusColor,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Guardian Watch',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    statusText,
                    style: TextStyle(fontSize: 12, color: statusColor),
                  ),
                ],
              ),
            ),
            if (connected && battery != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  color: colorScheme.primaryContainer.withValues(alpha: 0.40),
                ),
                child: Text(
                  '$battery%',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                  ),
                ),
              )
            else if (!connected)
              // Watch connection is managed on the Dashboard. This
              // button just tells the user where to go — it does not
              // attempt to scan from this screen.
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  'Manage on Dashboard',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Security
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildSecurityCard(
    AuthProvider auth,
    ColorScheme colorScheme,
    bool disabled,
  ) {
    final verified = auth.user?.emailVerified ?? true;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Account Security',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  verified
                      ? Icons.verified_outlined
                      : Icons.warning_amber_outlined,
                  size: 21,
                  color: verified ? colorScheme.primary : Colors.orange,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        verified ? 'Email verified' : 'Email not verified',
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      if (!verified)
                        Text(
                          'Verify your email to strengthen account '
                          'recovery.',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurface.withValues(
                              alpha: 0.55,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (!verified)
                  TextButton(
                    onPressed: disabled || _sendingVerification
                        ? null
                        : _sendVerificationEmail,
                    child: _sendingVerification
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Verify'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Danger zone
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildDangerZone(ColorScheme colorScheme, bool disabled) {
    final errorColor = colorScheme.error;

    return Card(
      elevation: 0,
      color: errorColor.withValues(alpha: 0.035),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: errorColor.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: errorColor.withValues(alpha: 0.10),
              ),
              child: Icon(
                Icons.delete_forever_outlined,
                color: errorColor,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Delete Account',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: errorColor,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Permanently remove your Guardian account.',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: colorScheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: disabled ? null : _deleteAccount,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: errorColor,
                      side: BorderSide(color: errorColor),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text('Delete Account'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Input decoration
  // ══════════════════════════════════════════════════════════════════════════

  InputDecoration _inputDecoration(
    ColorScheme colorScheme, {
    required String label,
    required String hint,
    required IconData icon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(
        icon,
        size: 20,
        color: colorScheme.primary.withValues(alpha: 0.65),
      ),
      filled: true,
      fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.30),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.50),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colorScheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colorScheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colorScheme.error, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Avatar placeholder
// ════════════════════════════════════════════════════════════════════════════

class _AvatarLetter extends StatelessWidget {
  final String letter;
  final ColorScheme colorScheme;

  const _AvatarLetter({required this.letter, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        letter,
        style: TextStyle(
          fontSize: 34,
          fontWeight: FontWeight.w700,
          color: colorScheme.primary,
        ),
      ),
    );
  }
}
