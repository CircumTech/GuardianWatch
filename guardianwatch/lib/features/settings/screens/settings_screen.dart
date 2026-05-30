// ════════════════════════════════════════════════════════════════════════════
// lib/features/settings/screens/settings_screen.dart
// ════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../config/constants.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/ble_provider.dart';
import '../../../services/health_export_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _healthExportService = HealthExportService();
  bool _healthOptIn = false;
  int _hrHighAlert = AppConstants.defaultHrHigh;
  int _spo2LowAlert = AppConstants.defaultSpo2Low;
  bool _isLoading = true;
  bool _isSavingHealthOpt = false;
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _healthOptIn = prefs.getBool(AppConstants.keyHealthOptIn) ?? false;
        _hrHighAlert = prefs.getInt(AppConstants.keyAlertHrHigh) ??
            AppConstants.defaultHrHigh;
        _spo2LowAlert = prefs.getInt(AppConstants.keyAlertSpo2Low) ??
            AppConstants.defaultSpo2Low;
        final themeModeIndex = prefs.getInt('gw_theme_mode') ?? 0;
        _themeMode = ThemeMode.values[themeModeIndex.clamp(0, 2)];
      });
    } catch (e) {
      _showError('Failed to load settings: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveThresholds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(AppConstants.keyAlertHrHigh, _hrHighAlert);
      await prefs.setInt(AppConstants.keyAlertSpo2Low, _spo2LowAlert);

      final ble = context.read<BleProvider>();
      ble.updateAlertThresholds(hrHigh: _hrHighAlert, spo2Low: _spo2LowAlert);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Alert thresholds saved'),
              backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      _showError('Failed to save thresholds: $e');
    }
  }

  Future<void> _toggleHealthExport(bool value) async {
    setState(() => _isSavingHealthOpt = true);
    try {
      if (value) {
        final granted = await _healthExportService.requestPermissions();
        if (granted) {
          await _healthExportService.enableSync();
          setState(() => _healthOptIn = true);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('Health export permission denied'),
                  backgroundColor: Colors.orange),
            );
          }
          return;
        }
      } else {
        await _healthExportService.disableSync();
        setState(() => _healthOptIn = false);
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(AppConstants.keyHealthOptIn, _healthOptIn);
    } catch (e) {
      _showError('Failed to update health export: $e');
    } finally {
      if (mounted) setState(() => _isSavingHealthOpt = false);
    }
  }

  Future<void> _changeThemeMode(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('gw_theme_mode', ThemeMode.values.indexOf(mode));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Theme changed. Restart app to see full effect.')),
      );
    }
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sign out')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final auth = context.read<AuthProvider>();
      final ble = context.read<BleProvider>();
      if (ble.isConnected) await ble.disconnect();
      await auth.signOut();
    } catch (e) {
      _showError('Sign out failed: $e');
    }
  }

  Future<void> _clearLocalData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear local data'),
        content: const Text(
          'This will remove all locally stored profile info and settings. '
          'Your account and cloud data will remain unchanged. Continue?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      setState(() {
        _healthOptIn = false;
        _hrHighAlert = AppConstants.defaultHrHigh;
        _spo2LowAlert = AppConstants.defaultSpo2Low;
        _themeMode = ThemeMode.system;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Local data cleared'),
              backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      _showError('Failed to clear data: $e');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final ble = context.watch<BleProvider>();
    final theme = Theme.of(context);

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            leading: CircleAvatar(
              child: Text(
                  auth.user?.displayName?.substring(0, 1).toUpperCase() ?? 'U'),
            ),
            title: Text(auth.user?.displayName ?? 'User'),
            subtitle: Text(auth.user?.email ?? ''),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // Navigate to profile screen (if separate)
            },
          ),
          const Divider(),
          _SectionHeader('Watch'),
          ListTile(
            leading: const Icon(Icons.watch),
            title: const Text('Connection status'),
            subtitle: Text(ble.status.name),
            trailing: ble.status == BleStatus.connected
                ? TextButton(
                    onPressed: () => ble.disconnect(),
                    child: const Text('Disconnect'))
                : (ble.status == BleStatus.error
                    ? TextButton(
                        onPressed: () => ble.reconnect(),
                        child: const Text('Reconnect'))
                    : null),
          ),
          const Divider(),
          _SectionHeader('Health Integration'),
          SwitchListTile(
            title: const Text('Sync with Apple Health / Google Fit'),
            subtitle: const Text('Export heart rate, SpO₂ and temperature'),
            value: _healthOptIn,
            onChanged: _isSavingHealthOpt ? null : _toggleHealthExport,
          ),
          if (_isSavingHealthOpt)
            const Padding(
              padding: EdgeInsets.only(left: 16, bottom: 8),
              child: LinearProgressIndicator(),
            ),
          const Divider(),
          _SectionHeader('Alerts'),
          ListTile(
            title: const Text('High heart rate alert'),
            subtitle: Text('Alert above $_hrHighAlert bpm'),
            trailing: SizedBox(
              width: 140,
              child: Slider(
                min: 90,
                max: 200,
                divisions: 11,
                value: _hrHighAlert.toDouble(),
                label: '$_hrHighAlert',
                onChanged: (v) => setState(() => _hrHighAlert = v.toInt()),
              ),
            ),
          ),
          ListTile(
            title: const Text('Low SpO₂ alert'),
            subtitle: Text('Alert below $_spo2LowAlert%'),
            trailing: SizedBox(
              width: 140,
              child: Slider(
                min: 80,
                max: 95,
                divisions: 15,
                value: _spo2LowAlert.toDouble(),
                label: '$_spo2LowAlert',
                onChanged: (v) => setState(() => _spo2LowAlert = v.toInt()),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ElevatedButton(
              onPressed: _saveThresholds,
              child: const Text('Save Alert Thresholds'),
            ),
          ),
          const Divider(),
          _SectionHeader('Appearance'),
          ListTile(
            leading: const Icon(Icons.brightness_6),
            title: const Text('Theme mode'),
            trailing: DropdownButton<ThemeMode>(
              value: _themeMode,
              onChanged: (mode) => mode != null ? _changeThemeMode(mode) : null,
              items: const [
                DropdownMenuItem(
                    value: ThemeMode.system, child: Text('System default')),
                DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
              ],
            ),
          ),
          const Divider(),
          _SectionHeader('Data'),
          ListTile(
            leading: const Icon(Icons.delete_sweep, color: Colors.orange),
            title: const Text('Clear local data',
                style: TextStyle(color: Colors.orange)),
            onTap: _clearLocalData,
          ),
          const Divider(),
          _SectionHeader('Account'),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.redAccent),
            title: const Text('Sign out',
                style: TextStyle(color: Colors.redAccent)),
            onTap: _signOut,
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ============================================================================
// Section Header
// ============================================================================

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}
