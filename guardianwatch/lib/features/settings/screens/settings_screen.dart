// ════════════════════════════════════════════════════════════════════════════
// lib/features/settings/screens/settings_screen.dart
// ════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../profile/screens/profile_screen.dart';
import '../../../config/constants.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/ble_provider.dart';
import '../../../services/health_export_service.dart';

// ============================================================================
// Settings Screen
// ============================================================================

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  final _healthExportService = HealthExportService();

  bool _healthOptIn = false;
  int _hrHighAlert = AppConstants.defaultHrHigh;
  int _spo2LowAlert = AppConstants.defaultSpo2Low;
  bool _isLoading = true;
  bool _isSavingHealthOpt = false;
  ThemeMode _themeMode = ThemeMode.system;

  // Animation for content fade-in
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

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
    _loadPrefs();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _healthOptIn = prefs.getBool(AppConstants.keyHealthOptIn) ?? false;
        _hrHighAlert =
            prefs.getInt(AppConstants.keyAlertHrHigh) ??
            AppConstants.defaultHrHigh;
        _spo2LowAlert =
            prefs.getInt(AppConstants.keyAlertSpo2Low) ??
            AppConstants.defaultSpo2Low;
        final themeModeIndex = prefs.getInt('gw_theme_mode') ?? 0;
        _themeMode = ThemeMode.values[themeModeIndex.clamp(0, 2)];
      });
      _fadeController.forward();
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
          SnackBar(
            content: const Text('Alert thresholds saved'),
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
              SnackBar(
                content: const Text('Health export permission denied'),
                backgroundColor: Colors.orange,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                margin: const EdgeInsets.all(16),
              ),
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
        SnackBar(
          content: const Text('Theme changed. Restart app to see full effect.'),
          backgroundColor: Colors.blue,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
    }
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Sign Out'),
          ),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Clear Local Data'),
        content: const Text(
          'This will remove all locally stored profile info and settings. '
          'Your account and cloud data will remain unchanged. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.orange,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Clear'),
          ),
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
          SnackBar(
            content: const Text('Local data cleared'),
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
      _showError('Failed to clear data: $e');
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

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final ble = context.watch<BleProvider>();
    final cs = Theme.of(context).colorScheme;

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          elevation: 0,
          backgroundColor: cs.surface,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        elevation: 0,
        backgroundColor: cs.surface,
      ),
      body: FadeTransition(
        opacity: _fadeAnimation,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Profile Card
            _buildProfileCard(auth, cs),
            const SizedBox(height: 20),

            // Watch Section
            _buildWatchSection(ble, cs),
            const SizedBox(height: 20),

            // Health Integration
            _buildHealthIntegrationSection(cs),
            const SizedBox(height: 20),

            // Alerts Section
            _buildAlertsSection(cs),
            const SizedBox(height: 20),

            // Appearance Section
            _buildAppearanceSection(cs),
            const SizedBox(height: 20),

            // Data Section
            _buildDataSection(cs),
            const SizedBox(height: 20),

            // Account Section
            _buildAccountSection(cs),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileCard(AuthProvider auth, ColorScheme cs) {
    final initial = (auth.user?.displayName ?? 'U')[0].toUpperCase();

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outline.withOpacity(0.08)),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: cs.primary.withOpacity(0.1),
          foregroundColor: cs.primary,
          child: Text(
            initial,
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
          ),
        ),
        title: Text(
          auth.user?.displayName ?? 'User',
          style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurface),
        ),
        subtitle: Text(
          auth.user?.email ?? '',
          style: TextStyle(color: cs.onSurface.withOpacity(0.5)),
        ),
        trailing: Icon(
          Icons.chevron_right,
          color: cs.onSurface.withOpacity(0.3),
        ),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ProfileScreen()),
          );
        },
      ),
    );
  }

  Widget _buildWatchSection(BleProvider ble, ColorScheme cs) {
    final isConnected = ble.status == BleStatus.connected;
    final statusText = ble.status.name;

    return _SectionCard(
      title: 'Watch',
      icon: Icons.watch_outlined,
      children: [
        ListTile(
          leading: Container(
            padding: const EdgeInsets.all(8),
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
              color: isConnected ? cs.primary : cs.onSurface.withOpacity(0.3),
              size: 20,
            ),
          ),
          title: Text(
            'Connection Status',
            style: TextStyle(fontWeight: FontWeight.w500, color: cs.onSurface),
          ),
          subtitle: Text(
            statusText,
            style: TextStyle(
              color: isConnected ? cs.primary : cs.onSurface.withOpacity(0.5),
              fontWeight: isConnected ? FontWeight.w500 : FontWeight.normal,
            ),
          ),
          trailing: isConnected
              ? TextButton(
                  onPressed: () => ble.disconnect(),
                  style: TextButton.styleFrom(foregroundColor: cs.error),
                  child: const Text('Disconnect'),
                )
              : ble.status == BleStatus.error
              ? TextButton(
                  onPressed: () => ble.reconnect(),
                  style: TextButton.styleFrom(foregroundColor: cs.primary),
                  child: const Text('Reconnect'),
                )
              : null,
        ),
      ],
    );
  }

  Widget _buildHealthIntegrationSection(ColorScheme cs) {
    return _SectionCard(
      title: 'Health Integration',
      icon: Icons.health_and_safety_outlined,
      children: [
        SwitchListTile(
          title: Text(
            'Sync with Apple Health / Google Fit',
            style: TextStyle(fontWeight: FontWeight.w500, color: cs.onSurface),
          ),
          subtitle: Text(
            'Export heart rate, SpO₂ and temperature',
            style: TextStyle(color: cs.onSurface.withOpacity(0.5)),
          ),
          value: _healthOptIn,
          onChanged: _isSavingHealthOpt ? null : _toggleHealthExport,
          activeColor: cs.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        if (_isSavingHealthOpt)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }

  Widget _buildAlertsSection(ColorScheme cs) {
    return _SectionCard(
      title: 'Alerts',
      icon: Icons.notifications_active_outlined,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'High heart rate alert',
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: cs.primaryContainer.withOpacity(0.15),
                    ),
                    child: Text(
                      '$_hrHighAlert bpm',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ),
                ],
              ),
              Slider(
                min: 90,
                max: 200,
                divisions: 11,
                value: _hrHighAlert.toDouble(),
                label: '$_hrHighAlert bpm',
                onChanged: (v) => setState(() => _hrHighAlert = v.toInt()),
                activeColor: cs.primary,
                inactiveColor: cs.outline.withOpacity(0.2),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Low SpO₂ alert',
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: cs.primaryContainer.withOpacity(0.15),
                    ),
                    child: Text(
                      '$_spo2LowAlert%',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ),
                ],
              ),
              Slider(
                min: 80,
                max: 95,
                divisions: 15,
                value: _spo2LowAlert.toDouble(),
                label: '$_spo2LowAlert%',
                onChanged: (v) => setState(() => _spo2LowAlert = v.toInt()),
                activeColor: cs.primary,
                inactiveColor: cs.outline.withOpacity(0.2),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saveThresholds,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: const Text('Save Alert Thresholds'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAppearanceSection(ColorScheme cs) {
    return _SectionCard(
      title: 'Appearance',
      icon: Icons.palette_outlined,
      children: [
        ListTile(
          leading: Icon(Icons.brightness_6_outlined, color: cs.primary),
          title: Text(
            'Theme Mode',
            style: TextStyle(fontWeight: FontWeight.w500, color: cs.onSurface),
          ),
          trailing: DropdownButton<ThemeMode>(
            value: _themeMode,
            onChanged: (mode) => mode != null ? _changeThemeMode(mode) : null,
            style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w500),
            dropdownColor: cs.surface,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
              DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
              DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDataSection(ColorScheme cs) {
    return _SectionCard(
      title: 'Data',
      icon: Icons.data_usage_outlined,
      children: [
        ListTile(
          leading: Icon(Icons.delete_sweep_outlined, color: Colors.orange),
          title: Text(
            'Clear Local Data',
            style: TextStyle(fontWeight: FontWeight.w500, color: Colors.orange),
          ),
          subtitle: Text(
            'Remove all local profile and settings data',
            style: TextStyle(color: cs.onSurface.withOpacity(0.5)),
          ),
          trailing: OutlinedButton(
            onPressed: _clearLocalData,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.orange,
              side: const BorderSide(color: Colors.orange, width: 1.2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Clear'),
          ),
        ),
      ],
    );
  }

  Widget _buildAccountSection(ColorScheme cs) {
    return _SectionCard(
      title: 'Account',
      icon: Icons.account_circle_outlined,
      children: [
        ListTile(
          leading: Icon(Icons.logout_outlined, color: Colors.redAccent),
          title: Text(
            'Sign Out',
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: Colors.redAccent,
            ),
          ),
          subtitle: Text(
            'Sign out from your account',
            style: TextStyle(color: cs.onSurface.withOpacity(0.5)),
          ),
          trailing: OutlinedButton(
            onPressed: _signOut,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              side: const BorderSide(color: Colors.redAccent, width: 1.2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Sign Out'),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// Section Card
// ============================================================================

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;

  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outline.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Icon(icon, size: 20, color: cs.primary),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
          ...children,
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
