// ════════════════════════════════════════════════════════════════════════════
// lib/features/profile/screens/profile_screen.dart
// ════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart' as cloud_firestore;
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../../../providers/auth_provider.dart';
import '../../../providers/ble_provider.dart';

// ============================================================================
// Profile Screen
// ============================================================================

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  String _gender = 'Prefer not to say';
  bool _saving = false;
  bool _isDeleting = false;

  // Animation for content fade-in
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  static const String _prefName = 'gw_profile_name';
  static const String _prefAge = 'gw_profile_age';
  static const String _prefGender = 'gw_profile_gender';

  static const List<String> _genders = [
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
    _nameCtrl.dispose();
    _ageCtrl.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _nameCtrl.text = prefs.getString(_prefName) ?? '';
        _ageCtrl.text = prefs.getString(_prefAge) ?? '';
        _gender = prefs.getString(_prefGender) ?? 'Prefer not to say';
      });
      _fadeController.forward();
    } catch (e) {
      if (mounted) _showError('Failed to load profile: $e');
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefName, _nameCtrl.text.trim());
      await prefs.setString(_prefAge, _ageCtrl.text.trim());
      await prefs.setString(_prefGender, _gender);

      // Update Firebase Auth display name
      final auth = context.read<AuthProvider>();
      await auth.updateUserProfile(displayName: _nameCtrl.text.trim());

      final user = firebase_auth.FirebaseAuth.instance.currentUser;
      if (user != null) {
        await cloud_firestore.FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .set({
              'age': int.tryParse(_ageCtrl.text.trim()),
              'gender': _gender,
            }, cloud_firestore.SetOptions(merge: true));
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Profile saved successfully'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
        _fadeController.reset();
        _fadeController.forward();
      }
    } catch (e) {
      _showError('Failed to save profile: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Account?'),
        content: const Text(
          'This will permanently erase your account and all associated health data. '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isDeleting = true);
    try {
      final auth = context.read<AuthProvider>();
      final ble = context.read<BleProvider>();
      if (ble.isConnected) await ble.disconnect();
      await auth.deleteAccount();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Account deleted successfully'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    } catch (e) {
      _showError('Failed to delete account: $e');
      setState(() => _isDeleting = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  String? _validateAge(String? value) {
    if (value == null || value.isEmpty) return null;
    final age = int.tryParse(value);
    if (age == null) return 'Please enter a valid number';
    if (age < 0 || age > 120) return 'Age must be between 0 and 120';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final ble = context.watch<BleProvider>();
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        elevation: 0,
        backgroundColor: cs.surface,
        actions: [
          TextButton(
            onPressed: _saving || _isDeleting ? null : _saveProfile,
            style: TextButton.styleFrom(foregroundColor: cs.primary),
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
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // User Avatar Section
                _buildAvatarSection(auth, cs),
                const SizedBox(height: 28),

                // Profile Form
                _buildProfileForm(cs),
                const SizedBox(height: 28),

                // Watch Status Card
                _buildWatchStatusCard(ble, cs),
                const SizedBox(height: 16),

                // Danger Zone
                _buildDangerZone(cs),
                const SizedBox(height: 20),
              ],
            ),
          ),
          // Delete overlay
          if (_isDeleting)
            Container(
              color: Colors.black54,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      'Deleting account...',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAvatarSection(AuthProvider auth, ColorScheme cs) {
    final hasPhoto = auth.user?.photoURL != null;

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
              colors: [
                cs.primary.withOpacity(0.3),
                cs.primary.withOpacity(0.1),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: cs.primary.withOpacity(0.15),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipOval(
            child: hasPhoto
                ? Image.network(
                    auth.user!.photoURL!,
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        _buildAvatarPlaceholder(auth, cs),
                  )
                : _buildAvatarPlaceholder(auth, cs),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          auth.user?.displayName ?? 'User',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
          ),
        ),
        Text(
          auth.user?.email ?? '',
          style: TextStyle(fontSize: 14, color: cs.onSurface.withOpacity(0.5)),
        ),
        if (!(auth.user?.emailVerified ?? true))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.info_outline, size: 14, color: Colors.orange),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: () async {
                    try {
                      await auth.sendEmailVerification();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text(
                              'Verification email sent. Check your inbox.',
                            ),
                            backgroundColor: Colors.green,
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            margin: const EdgeInsets.all(16),
                          ),
                        );
                      }
                    } catch (e) {
                      _showError('Failed to send verification: $e');
                    }
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.orange,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('Verify email'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildAvatarPlaceholder(AuthProvider auth, ColorScheme cs) {
    final initial = (auth.user?.displayName ?? 'U')[0].toUpperCase();
    return Container(
      color: cs.primary.withOpacity(0.08),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w600,
            color: cs.primary,
          ),
        ),
      ),
    );
  }

  Widget _buildProfileForm(ColorScheme cs) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outline.withOpacity(0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              // Display Name
              TextFormField(
                controller: _nameCtrl,
                style: TextStyle(fontSize: 16, color: cs.onSurface),
                decoration: InputDecoration(
                  labelText: 'Display Name',
                  hintText: 'Your full name',
                  prefixIcon: Icon(
                    Icons.person_outline,
                    color: cs.primary.withOpacity(0.6),
                    size: 20,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: cs.surfaceContainerHighest.withOpacity(0.3),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                validator: (value) {
                  if (value != null && value.trim().isEmpty) {
                    return 'Name cannot be empty';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Age
              TextFormField(
                controller: _ageCtrl,
                keyboardType: TextInputType.number,
                style: TextStyle(fontSize: 16, color: cs.onSurface),
                decoration: InputDecoration(
                  labelText: 'Age',
                  hintText: 'Your age in years',
                  prefixIcon: Icon(
                    Icons.cake_outlined,
                    color: cs.primary.withOpacity(0.6),
                    size: 20,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: cs.surfaceContainerHighest.withOpacity(0.3),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                validator: _validateAge,
              ),
              const SizedBox(height: 16),

              // Gender
              DropdownButtonFormField<String>(
                value: _gender,
                style: TextStyle(fontSize: 16, color: cs.onSurface),
                decoration: InputDecoration(
                  labelText: 'Biological Sex',
                  prefixIcon: Icon(
                    Icons.people_outline,
                    color: cs.primary.withOpacity(0.6),
                    size: 20,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: cs.surfaceContainerHighest.withOpacity(0.3),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 2,
                  ),
                ),
                items: _genders
                    .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                    .toList(),
                onChanged: (value) =>
                    setState(() => _gender = value ?? _gender),
                dropdownColor: cs.surface,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWatchStatusCard(BleProvider ble, ColorScheme cs) {
    final isConnected = ble.isConnected;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outline.withOpacity(0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paired Device',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isConnected
                        ? cs.primary.withOpacity(0.12)
                        : cs.outline.withOpacity(0.08),
                  ),
                  child: Icon(
                    isConnected
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth_disabled,
                    color: isConnected
                        ? cs.primary
                        : cs.onSurface.withOpacity(0.3),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isConnected ? 'GuardianWrist' : 'No device connected',
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          color: cs.onSurface,
                        ),
                      ),
                      Text(
                        isConnected
                            ? 'Connected • ${ble.battery != null ? '${ble.battery}% battery' : ''}'
                            : ble.status == BleStatus.error
                            ? 'Connection error'
                            : 'Tap to connect',
                        style: TextStyle(
                          fontSize: 13,
                          color: isConnected
                              ? cs.onSurface.withOpacity(0.5)
                              : cs.error,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!isConnected && ble.status != BleStatus.connecting)
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: cs.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text('Connect'),
                  )
                else if (isConnected && ble.battery != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: cs.primaryContainer.withOpacity(0.2),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.battery_full, size: 14, color: cs.primary),
                        const SizedBox(width: 4),
                        Text(
                          '${ble.battery}%',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: cs.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDangerZone(ColorScheme cs) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.red.withOpacity(0.15), width: 1),
      ),
      color: Colors.red.withOpacity(0.04),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.red.withOpacity(0.1),
              ),
              child: const Icon(
                Icons.delete_forever_outlined,
                color: Colors.red,
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Delete Account',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.red,
                    ),
                  ),
                  Text(
                    'Permanently delete your account and all health data',
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            ),
            OutlinedButton(
              onPressed: _isDeleting ? null : _deleteAccount,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red, width: 1.2),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
  }
}
