// ════════════════════════════════════════════════════════════════════════════
// lib/features/profile/screens/profile_screen.dart
// ════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/ble_provider.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  String _gender = 'Prefer not to say';
  bool _saving = false;
  bool _isDeleting = false;

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
    _loadProfile();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ageCtrl.dispose();
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

      final auth = context.read<AuthProvider>();
      await auth.updateUserProfile(displayName: _nameCtrl.text.trim());

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Profile saved'), backgroundColor: Colors.green),
        );
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
        title: const Text('Delete account?'),
        content: const Text(
          'This will permanently erase your account and all associated health data. '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
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
          const SnackBar(
              content: Text('Account deleted successfully'),
              backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      _showError('Failed to delete account: $e');
      setState(() => _isDeleting = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
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
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Profile'),
        actions: [
          TextButton(
            onPressed: _saving || _isDeleting ? null : _saveProfile,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
        ],
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Center(
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 40,
                      backgroundImage: auth.user?.photoURL != null
                          ? NetworkImage(auth.user!.photoURL!)
                          : null,
                      child: auth.user?.photoURL == null
                          ? Text(
                              (auth.user?.displayName ?? 'U')[0].toUpperCase(),
                              style: const TextStyle(fontSize: 32))
                          : null,
                    ),
                    const SizedBox(height: 12),
                    Text(auth.user?.email ?? '',
                        style: theme.textTheme.bodySmall),
                    if (!(auth.user?.emailVerified ?? true))
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.warning_amber,
                                size: 14, color: Colors.orange),
                            const SizedBox(width: 4),
                            TextButton(
                              onPressed: () async {
                                try {
                                  await auth.sendEmailVerification();
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text(
                                              'Verification email sent. Check your inbox.')),
                                    );
                                  }
                                } catch (e) {
                                  _showError('Failed to send verification: $e');
                                }
                              },
                              child: const Text('Verify email'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Display name',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value != null && value.trim().isEmpty)
                          return 'Name cannot be empty';
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _ageCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Age',
                        prefixIcon: Icon(Icons.cake_outlined),
                        border: OutlineInputBorder(),
                      ),
                      validator: _validateAge,
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: _gender,
                      decoration: const InputDecoration(
                        labelText: 'Biological sex',
                        prefixIcon: Icon(Icons.people_outline),
                        border: OutlineInputBorder(),
                      ),
                      items: _genders
                          .map(
                              (g) => DropdownMenuItem(value: g, child: Text(g)))
                          .toList(),
                      onChanged: (value) =>
                          setState(() => _gender = value ?? _gender),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Paired Watch', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                            ble.isConnected
                                ? Icons.bluetooth_connected
                                : Icons.bluetooth_disabled,
                            color: ble.isConnected ? Colors.green : Colors.grey,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(ble.isConnected
                                ? 'GuardianWrist (connected)'
                                : ble.status == BleStatus.error
                                    ? 'Connection error'
                                    : 'Not connected'),
                          ),
                          if (!ble.isConnected &&
                              ble.status != BleStatus.connecting)
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Connect'),
                            ),
                          if (ble.battery != null)
                            Chip(
                              avatar: const Icon(Icons.battery_full, size: 14),
                              label: Text('${ble.battery}%',
                                  style: const TextStyle(fontSize: 12)),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _isDeleting ? null : _deleteAccount,
                icon: _isDeleting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.delete_forever, color: Colors.red),
                label: const Text('Delete my account',
                    style: TextStyle(color: Colors.red)),
                style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.red)),
              ),
              const SizedBox(height: 20),
            ],
          ),
          if (_isDeleting)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Deleting account...',
                        style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
