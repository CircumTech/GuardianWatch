// ════════════════════════════════════════════════════════════════════════════
// lib/features/settings/screens/settings_screen.dart
// ════════════════════════════════════════════════════════════════════════════
//
// Settings — watch, alerts, health integration, appearance, account.
//
// BACKEND SYNC
// ------------
// After saving alert thresholds, BackgroundBridge.notifySettingsChanged()
// is invoked so the background isolate refreshes its cached thresholds
// without waiting for a service restart.
//
// SIGN-OUT
// --------
// Sign-out disconnects BLE, resets InsightProvider's model buffers, and
// clears the Health-export opt-in. The _RootGate observes the resulting
// auth change and swaps to Login.
//

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../config/constants.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/ble_provider.dart';
import '../../../providers/insight_provider.dart';
import '../../../providers/theme_provider.dart';
import '../../../services/background_service.dart';
import '../../../services/health_export_service.dart';
import '../../profile/screens/profile_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  /// Single shared instance — the service owns its own lifecycle.
  final HealthExportService _healthExportService = HealthExportService.shared();

  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  bool _isLoading = true;
  bool _isHealthSyncChanging = false;
  bool _isSavingAlerts = false;
  bool _isResetting = false;
  bool _isSigningOut = false;

  bool _healthOptIn = false;

  int _hrHighAlert = AppConstants.defaultHrHigh;
  int _spo2LowAlert = AppConstants.defaultSpo2Low;

  static const int _minHrAlert = 90;
  static const int _maxHrAlert = 200;
  static const int _minSpo2Alert = 80;
  static const int _maxSpo2Alert = 95;

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

    _loadSettings();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Load settings
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;

      final healthOptIn = prefs.getBool(AppConstants.keyHealthOptIn) ?? false;
      final hrAlert =
          prefs.getInt(AppConstants.keyAlertHrHigh) ??
          AppConstants.defaultHrHigh;
      final spo2Alert =
          prefs.getInt(AppConstants.keyAlertSpo2Low) ??
          AppConstants.defaultSpo2Low;

      // Reconcile the stored preference with the actual platform
      // authorization state. checkOptedIn() reads the preference
      // without prompting the OS.
      final actuallyOptedIn = await _healthExportService.checkOptedIn();
      if (!mounted) return;

      setState(() {
        _healthOptIn = healthOptIn && actuallyOptedIn;
        _hrHighAlert = hrAlert.clamp(_minHrAlert, _maxHrAlert);
        _spo2LowAlert = spo2Alert.clamp(_minSpo2Alert, _maxSpo2Alert);
        _isLoading = false;
      });

      _fadeController.forward();

      // Push persisted thresholds into the live BLE provider so its
      // cached values are current.
      try {
        await context.read<BleProvider>().updateAlertThresholds(
          hrHigh: _hrHighAlert,
          spo2Low: _spo2LowAlert,
        );
      } catch (e) {
        debugPrint('Guardian settings: BLE threshold sync failed: $e');
      }
    } catch (e, stack) {
      debugPrint('Guardian settings load error: $e');
      debugPrintStack(stackTrace: stack);

      if (!mounted) return;
      setState(() => _isLoading = false);
      _showError('Unable to load settings.');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Health integration
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _toggleHealthSync(bool enabled) async {
    if (_isHealthSyncChanging) return;

    setState(() => _isHealthSyncChanging = true);

    try {
      final status = await _healthExportService.setOptIn(enabled);
      if (!mounted) return;

      switch (status) {
        case HealthIntegrationStatus.authorized:
          setState(() => _healthOptIn = true);
          _showSuccess('Health data export enabled.');
          break;

        case HealthIntegrationStatus.disabled:
          setState(() => _healthOptIn = false);
          _showSuccess('Health data export disabled.');
          break;

        case HealthIntegrationStatus.permissionRequired:
          setState(() => _healthOptIn = false);
          _showWarning(
            'Health-platform permission was not granted. You can enable '
            'it later from your device settings.',
          );
          break;

        case HealthIntegrationStatus.unavailable:
          setState(() => _healthOptIn = false);
          _showWarning(
            'This device does not have a supported health platform '
            'available.',
          );
          break;

        case HealthIntegrationStatus.error:
        case HealthIntegrationStatus.unknown:
          setState(() => _healthOptIn = false);
          _showError('Unable to update health integration.');
          break;
      }
    } catch (e, stack) {
      debugPrint('Guardian health sync update error: $e');
      debugPrintStack(stackTrace: stack);

      if (mounted) {
        _showError('Unable to update health integration.');
      }
    } finally {
      if (mounted) setState(() => _isHealthSyncChanging = false);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Alert thresholds
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _saveAlertThresholds() async {
    if (_isSavingAlerts) return;

    setState(() => _isSavingAlerts = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(AppConstants.keyAlertHrHigh, _hrHighAlert);
      await prefs.setInt(AppConstants.keyAlertSpo2Low, _spo2LowAlert);

      // Push to the live BLE provider.
      try {
        await context.read<BleProvider>().updateAlertThresholds(
          hrHigh: _hrHighAlert,
          spo2Low: _spo2LowAlert,
        );
      } catch (e) {
        debugPrint('Guardian settings: BLE threshold update failed: $e');
      }

      // Tell the background isolate to refresh its cached thresholds.
      // Without this, alerts continue using the old values until the
      // service restarts.
      try {
        BackgroundBridge.notifySettingsChanged();
      } catch (e) {
        debugPrint('Guardian settings: background notify failed: $e');
      }

      if (!mounted) return;
      _showSuccess('Alert thresholds saved.');
    } catch (e, stack) {
      debugPrint('Guardian alert threshold save error: $e');
      debugPrintStack(stackTrace: stack);
      if (mounted) {
        _showError('Unable to save alert thresholds.');
      }
    } finally {
      if (mounted) setState(() => _isSavingAlerts = false);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Theme
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _changeTheme(ThemeMode mode) async {
    try {
      await context.read<ThemeProvider>().setThemeMode(mode);
    } catch (e) {
      if (mounted) {
        _showError('Unable to save theme preference.');
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Sign out
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _signOut() async {
    if (_isSigningOut) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Sign out?'),
        content: const Text(
          'You will be signed out of Guardian Watch. Your cloud account '
          'and health records will not be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isSigningOut = true);

    try {
      // 1. Stop Bluetooth monitoring.
      final ble = context.read<BleProvider>();
      if (ble.isConnected) {
        try {
          await ble.disconnect();
        } catch (e) {
          debugPrint('Guardian sign-out: BLE disconnect failed: $e');
        }
      }

      // 2. Reset the insight model buffers so the next signed-in user
      //    does not inherit the previous user's samples.
      try {
        context.read<InsightProvider>().resetSession();
      } catch (e) {
        debugPrint('Guardian sign-out: insight reset failed: $e');
      }

      // 3. Clear the health-export opt-in so the next user starts opted out.
      try {
        await HealthExportService.shared().clearOptIn();
      } catch (e) {
        debugPrint('Guardian sign-out: health opt-in clear failed: $e');
      }

      // 4. Sign out via Firebase. The _RootGate observes the auth change
      //    and swaps to LoginScreen.
      await context.read<AuthProvider>().signOut();
    } catch (e, stack) {
      debugPrint('Guardian sign-out error: $e');
      debugPrintStack(stackTrace: stack);

      if (mounted) {
        setState(() => _isSigningOut = false);
        _showError('Unable to sign out. Please try again.');
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Reset local settings
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _resetLocalSettings() async {
    if (_isResetting) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Reset local settings?'),
        content: const Text(
          'This resets Guardian settings stored on this device, including '
          'health export preference, alert thresholds and theme. It does '
          'not delete your Guardian account or cloud health records.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isResetting = true);

    try {
      final prefs = await SharedPreferences.getInstance();

      // Remove only the settings owned by this screen. Never prefs.clear().
      await prefs.remove(AppConstants.keyHealthOptIn);
      await prefs.remove(AppConstants.keyAlertHrHigh);
      await prefs.remove(AppConstants.keyAlertSpo2Low);
      await prefs.remove(AppConstants.keyThemeMode);

      // Additional alert thresholds introduced with the background service.
      await prefs.remove(AppConstants.keyAlertTempHigh);
      await prefs.remove(AppConstants.keyAlertBatteryLow);
      await prefs.remove(AppConstants.keyAlertBatteryCritical);

      // Cloud sync and retention keys, if present.
      await prefs.remove(AppConstants.keyCloudSyncEnabled);
      await prefs.remove(AppConstants.keyRetentionDays);

      // Reset service state.
      try {
        await _healthExportService.setOptIn(false);
      } catch (e) {
        debugPrint('Guardian settings: health opt-out failed: $e');
      }

      // Reset theme to system.
      try {
        await context.read<ThemeProvider>().setThemeMode(ThemeMode.system);
      } catch (e) {
        debugPrint('Guardian settings: theme reset failed: $e');
      }

      // Reset alert thresholds to defaults.
      try {
        await context.read<BleProvider>().updateAlertThresholds(
          hrHigh: AppConstants.defaultHrHigh,
          spo2Low: AppConstants.defaultSpo2Low,
        );
      } catch (e) {
        debugPrint('Guardian settings: threshold reset failed: $e');
      }

      // Notify the background service so its cached thresholds update.
      try {
        BackgroundBridge.notifySettingsChanged();
      } catch (e) {
        debugPrint('Guardian settings: background notify failed: $e');
      }

      if (!mounted) return;

      setState(() {
        _healthOptIn = false;
        _hrHighAlert = AppConstants.defaultHrHigh;
        _spo2LowAlert = AppConstants.defaultSpo2Low;
      });

      _showSuccess('Local settings reset.');
    } catch (e, stack) {
      debugPrint('Guardian local settings reset error: $e');
      debugPrintStack(stackTrace: stack);
      if (mounted) {
        _showError('Unable to reset local settings.');
      }
    } finally {
      if (mounted) setState(() => _isResetting = false);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Feedback
  // ══════════════════════════════════════════════════════════════════════════

  void _showSuccess(String message) {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: cs.primary,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
  }

  void _showWarning(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.orange.shade700,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
  }

  void _showError(String message) {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: cs.error,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
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
    final themeProvider = context.watch<ThemeProvider>();
    final cs = Theme.of(context).colorScheme;

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return PopScope(
      // Block the OS back gesture while a blocking operation is running.
      canPop: !_isSigningOut && !_isResetting,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          elevation: 0,
          backgroundColor: cs.surface,
          surfaceTintColor: cs.surface,
        ),
        body: Stack(
          children: [
            AbsorbPointer(
              absorbing: _isSigningOut || _isResetting,
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    _buildProfileCard(auth, cs),
                    const SizedBox(height: 18),
                    _buildWatchSection(ble, cs),
                    const SizedBox(height: 18),
                    _buildHealthSection(cs),
                    const SizedBox(height: 18),
                    _buildAlertsSection(cs),
                    const SizedBox(height: 18),
                    _buildAppearanceSection(themeProvider, cs),
                    const SizedBox(height: 18),
                    _buildDataSection(cs),
                    const SizedBox(height: 18),
                    _buildAccountSection(cs),
                  ],
                ),
              ),
            ),

            if (_isSigningOut || _isResetting)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.45),
                  child: Center(
                    child: Container(
                      margin: const EdgeInsets.all(32),
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 18),
                          Text(
                            _isSigningOut
                                ? 'Signing out...'
                                : 'Resetting settings...',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface,
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
  // Profile
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildProfileCard(AuthProvider auth, ColorScheme cs) {
    final name = auth.user?.displayName?.trim().isNotEmpty == true
        ? auth.user!.displayName!
        : 'Guardian User';
    final email = auth.user?.email ?? '';
    final photoURL = auth.user?.photoURL;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'U';

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.55)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const ProfileScreen()));
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: cs.primaryContainer,
                backgroundImage: photoURL != null && photoURL.isNotEmpty
                    ? NetworkImage(photoURL)
                    : null,
                child: photoURL == null || photoURL.isEmpty
                    ? Text(
                        initial,
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                          color: cs.primary,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.50),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Edit profile',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: cs.onSurface.withValues(alpha: 0.30),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Watch
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildWatchSection(BleProvider ble, ColorScheme cs) {
    final connected = ble.isConnected;
    final connecting =
        ble.status == BleStatus.connecting || ble.status == BleStatus.scanning;

    final statusColor = connected
        ? cs.primary
        : ble.status == BleStatus.error
        ? cs.error
        : cs.onSurface.withValues(alpha: 0.50);

    final statusText = connected
        ? (ble.battery != null
              ? 'Connected • ${ble.battery}% battery'
              : 'Connected')
        : connecting
        ? 'Connecting...'
        : ble.status == BleStatus.error
        ? 'Connection error'
        : 'Not connected';

    return _SectionCard(
      title: 'Watch',
      icon: Icons.watch_outlined,
      children: [
        ListTile(
          leading: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: statusColor.withValues(alpha: 0.10),
            ),
            child: Icon(
              connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
              size: 20,
              color: statusColor,
            ),
          ),
          title: Text(
            'Connection Status',
            style: TextStyle(fontWeight: FontWeight.w500, color: cs.onSurface),
          ),
          subtitle: Text(
            statusText,
            style: TextStyle(fontSize: 12, color: statusColor),
          ),
          trailing: connected
              ? TextButton(
                  onPressed: () => ble.disconnect(),
                  child: const Text('Disconnect'),
                )
              : ble.status == BleStatus.error
              ? TextButton(
                  onPressed: connecting ? null : () => ble.reconnect(),
                  child: const Text('Reconnect'),
                )
              : null,
        ),
        if (ble.lastConnectedDeviceId != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Icon(
                  Icons.fingerprint_outlined,
                  size: 15,
                  color: cs.onSurface.withValues(alpha: 0.40),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'Device ID: ${ble.lastConnectedDeviceId}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: cs.onSurface.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Health integration
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildHealthSection(ColorScheme cs) {
    final platform = Theme.of(context).platform;

    final platformName = platform == TargetPlatform.iOS
        ? 'Apple Health'
        : platform == TargetPlatform.android
        ? 'Health Connect'
        : 'Health platform';

    return _SectionCard(
      title: 'Health Integration',
      icon: Icons.health_and_safety_outlined,
      children: [
        SwitchListTile(
          value: _healthOptIn,
          onChanged: _isHealthSyncChanging ? null : _toggleHealthSync,
          activeColor: cs.primary,
          title: Text(
            'Export to $platformName',
            style: TextStyle(fontWeight: FontWeight.w500, color: cs.onSurface),
          ),
          subtitle: Text(
            'Export Guardian heart rate, SpO₂ and temperature readings.',
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.50),
            ),
          ),
        ),
        if (_isHealthSyncChanging)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Alerts
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildAlertsSection(ColorScheme cs) {
    return _SectionCard(
      title: 'Alerts',
      icon: Icons.notifications_active_outlined,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'High heart rate',
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  _ValuePill(text: '$_hrHighAlert bpm', colorScheme: cs),
                ],
              ),
              Slider(
                min: _minHrAlert.toDouble(),
                max: _maxHrAlert.toDouble(),
                divisions: 11,
                value: _hrHighAlert.toDouble(),
                label: '$_hrHighAlert bpm',
                onChanged: _isSavingAlerts
                    ? null
                    : (value) {
                        setState(() => _hrHighAlert = value.round());
                      },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _RangeLabel('$_minHrAlert bpm'),
                  _RangeLabel('$_maxHrAlert bpm'),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Low SpO₂',
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  _ValuePill(text: '$_spo2LowAlert%', colorScheme: cs),
                ],
              ),
              Slider(
                min: _minSpo2Alert.toDouble(),
                max: _maxSpo2Alert.toDouble(),
                divisions: _maxSpo2Alert - _minSpo2Alert,
                value: _spo2LowAlert.toDouble(),
                label: '$_spo2LowAlert%',
                onChanged: _isSavingAlerts
                    ? null
                    : (value) {
                        setState(() => _spo2LowAlert = value.round());
                      },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _RangeLabel('$_minSpo2Alert%'),
                  _RangeLabel('$_maxSpo2Alert%'),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _isSavingAlerts ? null : _saveAlertThresholds,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(11),
                ),
              ),
              child: _isSavingAlerts
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : const Text('Save Alert Thresholds'),
            ),
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Appearance
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildAppearanceSection(ThemeProvider themeProvider, ColorScheme cs) {
    return _SectionCard(
      title: 'Appearance',
      icon: Icons.palette_outlined,
      children: [
        ListTile(
          leading: Icon(Icons.brightness_6_outlined, color: cs.primary),
          title: Text(
            'Theme',
            style: TextStyle(fontWeight: FontWeight.w500, color: cs.onSurface),
          ),
          subtitle: Text(
            _themeDescription(themeProvider.themeMode),
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.50),
            ),
          ),
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<ThemeMode>(
              value: themeProvider.themeMode,
              dropdownColor: cs.surface,
              items: const [
                DropdownMenuItem(
                  value: ThemeMode.system,
                  child: Text('System'),
                ),
                DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
              ],
              onChanged: (mode) {
                if (mode != null) _changeTheme(mode);
              },
            ),
          ),
        ),
      ],
    );
  }

  String _themeDescription(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'Follow your device setting';
      case ThemeMode.light:
        return 'Light mode';
      case ThemeMode.dark:
        return 'Dark mode';
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Data
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildDataSection(ColorScheme cs) {
    return _SectionCard(
      title: 'Data',
      icon: Icons.storage_outlined,
      children: [
        ListTile(
          leading: Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.orange.withValues(alpha: 0.10),
            ),
            child: const Icon(
              Icons.restore_outlined,
              color: Colors.orange,
              size: 20,
            ),
          ),
          title: Text(
            'Reset Local Settings',
            style: TextStyle(fontWeight: FontWeight.w500, color: cs.onSurface),
          ),
          subtitle: Text(
            'Reset alerts, theme and health-export preference.',
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.50),
            ),
          ),
          trailing: OutlinedButton(
            onPressed: _isResetting ? null : _resetLocalSettings,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.orange,
              side: const BorderSide(color: Colors.orange),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Reset'),
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Account
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildAccountSection(ColorScheme cs) {
    return _SectionCard(
      title: 'Account',
      icon: Icons.account_circle_outlined,
      children: [
        ListTile(
          leading: Icon(Icons.logout_outlined, color: cs.error),
          title: Text(
            'Sign Out',
            style: TextStyle(fontWeight: FontWeight.w500, color: cs.onSurface),
          ),
          subtitle: Text(
            'Sign out from this Guardian account.',
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.50),
            ),
          ),
          trailing: OutlinedButton(
            onPressed: _isSigningOut ? null : _signOut,
            style: OutlinedButton.styleFrom(
              foregroundColor: cs.error,
              side: BorderSide(color: cs.error),
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

// ════════════════════════════════════════════════════════════════════════════
// Reusable section card
// ════════════════════════════════════════════════════════════════════════════

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
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.55)),
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

// ════════════════════════════════════════════════════════════════════════════
// Threshold pill
// ════════════════════════════════════════════════════════════════════════════

class _ValuePill extends StatelessWidget {
  final String text;
  final ColorScheme colorScheme;

  const _ValuePill({required this.text, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: colorScheme.primaryContainer.withValues(alpha: 0.45),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: colorScheme.primary,
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Range label
// ════════════════════════════════════════════════════════════════════════════

class _RangeLabel extends StatelessWidget {
  final String text;

  const _RangeLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Text(
      text,
      style: TextStyle(
        fontSize: 10,
        color: cs.onSurface.withValues(alpha: 0.40),
      ),
    );
  }
}
