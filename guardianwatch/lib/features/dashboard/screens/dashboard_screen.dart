// ════════════════════════════════════════════════════════════════════════════
// lib/features/dashboard/screens/dashboard_screen.dart
// ════════════════════════════════════════════════════════════════════════════
//
// Dashboard shell — hosts the four primary tabs.
//
// PERFORMANCE
// -----------
// Tabs are built lazily. Only the Home tab is built at launch. History,
// Insights, and Settings are only instantiated the first time the user
// visits them. Once visited they remain alive in the IndexedStack so their
// scroll position and state are preserved.
//
// ROUTING
// -------
// The shell is reached via the _RootGate in app.dart. It does not navigate
// away when the user signs out — the gate handles that transition. Sub-screens
// (ECG detail, scan sheet) are pushed locally and are the only navigation
// this file performs.
//

import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../../../providers/auth_provider.dart';
import '../../../providers/ble_provider.dart';

import '../../ecg/screens/ecg_detail_screen.dart';
import '../../history/screens/history_screen.dart';
import '../../insights/screens/insights_screen.dart';
import '../../settings/screens/settings_screen.dart';

// ════════════════════════════════════════════════════════════════════════════
// Main Dashboard shell
// ════════════════════════════════════════════════════════════════════════════

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;

  /// Indices that have been visited at least once.
  ///
  /// Tabs not in this set are rendered as empty placeholders, avoiding
  /// the cost of building their subtrees and initialising their providers.
  final Set<int> _visitedTabs = {0};

  static const List<NavigationDestination> _destinations = [
    NavigationDestination(
      icon: Icon(Icons.dashboard_outlined),
      selectedIcon: Icon(Icons.dashboard),
      label: 'Dashboard',
    ),
    NavigationDestination(
      icon: Icon(Icons.history_outlined),
      selectedIcon: Icon(Icons.history),
      label: 'History',
    ),
    NavigationDestination(
      icon: Icon(Icons.auto_awesome_outlined),
      selectedIcon: Icon(Icons.auto_awesome),
      label: 'Insights',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: 'Settings',
    ),
  ];

  Widget _buildTab(int index) {
    if (!_visitedTabs.contains(index)) {
      return const SizedBox.shrink();
    }

    switch (index) {
      case 0:
        return const _HomeTab();
      case 1:
        return const HistoryScreen();
      case 2:
        return const InsightsScreen();
      case 3:
        return const SettingsScreen();
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: List.generate(_destinations.length, _buildTab),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          if (_selectedIndex == index) return;

          setState(() {
            _selectedIndex = index;
            _visitedTabs.add(index);
          });
        },
        destinations: _destinations,
        animationDuration: const Duration(milliseconds: 250),
        height: 72,
        backgroundColor: colorScheme.surface,
        surfaceTintColor: colorScheme.surface,
        indicatorColor: colorScheme.primaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Home tab
// ════════════════════════════════════════════════════════════════════════════

class _HomeTab extends StatefulWidget {
  const _HomeTab();

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _metricsController;
  late final Animation<double> _metricsFade;

  StreamSubscription<List<double>>? _ecgSubscription;
  Timer? _ecgUiTimer;

  final List<double> _liveEcgSamples = [];

  DateTime? _lastSensorUpdate;

  bool _isInitializingConnection = false;
  bool _pendingEcgUiUpdate = false;

  String? _localError;

  @override
  void initState() {
    super.initState();

    _metricsController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );

    _metricsFade = CurvedAnimation(
      parent: _metricsController,
      curve: Curves.easeOut,
    );

    _metricsController.forward();

    _initialize();
  }

  Future<void> _initialize() async {
    final ble = context.read<BleProvider>();

    await _ecgSubscription?.cancel();

    _ecgSubscription = ble.ecgStream.listen(
      _handleEcgData,
      onError: (Object error) {
        debugPrint('Dashboard ECG stream error: $error');
      },
    );

    if (!mounted) return;

    // Only attempt to reconnect to a previously paired device. Do not
    // request Bluetooth permissions here — that happens on the user's
    // first tap of "Scan for Device".
    if (ble.lastConnectedDeviceId != null && !ble.isConnected) {
      await _autoReconnect();
    }
  }

  void _handleEcgData(List<double> samples) {
    if (!mounted || samples.isEmpty) return;

    _liveEcgSamples.addAll(samples);

    const maxPreviewSamples = 1000;
    if (_liveEcgSamples.length > maxPreviewSamples) {
      _liveEcgSamples.removeRange(
        0,
        _liveEcgSamples.length - maxPreviewSamples,
      );
    }

    _lastSensorUpdate = DateTime.now();

    if (_pendingEcgUiUpdate) return;
    _pendingEcgUiUpdate = true;

    _ecgUiTimer?.cancel();
    _ecgUiTimer = Timer(const Duration(milliseconds: 100), () {
      _pendingEcgUiUpdate = false;
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ecgUiTimer?.cancel();
    _ecgSubscription?.cancel();
    _metricsController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Auto-reconnect
  // ─────────────────────────────────────────────────────────────────────────

  /// Attempts to reconnect to the previously paired device.
  ///
  /// Assumes Bluetooth permission was granted in a prior session. If the
  /// reconnect fails, sets a local error so the user is prompted to scan.
  Future<void> _autoReconnect() async {
    if (_isInitializingConnection) return;

    final ble = context.read<BleProvider>();

    if (ble.status == BleStatus.connected ||
        ble.status == BleStatus.connecting ||
        ble.status == BleStatus.scanning) {
      return;
    }

    if (!mounted) return;

    setState(() {
      _isInitializingConnection = true;
      _localError = null;
    });

    try {
      // Verify permission silently. If it was revoked, requestPermissions
      // returns false without prompting on Android 12+ if the user has
      // permanently denied.
      final granted = await ble.requestPermissions();
      if (!mounted) return;

      if (!granted) {
        setState(() {
          _localError =
              'Bluetooth permission is required to connect to your Guardian Watch.';
        });
        return;
      }

      await ble.autoReconnect();
      if (!mounted) return;

      if (!ble.isConnected && ble.status != BleStatus.error) {
        setState(() {
          _localError =
              'Your previous Guardian Watch could not be found. Scan for it again.';
        });
      }
    } catch (e, stack) {
      debugPrint('Dashboard auto-reconnect error: $e');
      debugPrintStack(stackTrace: stack);

      if (!mounted) return;

      setState(() {
        _localError = 'Unable to reconnect to your Guardian Watch.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isInitializingConnection = false;
        });
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Manual scan
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _startScan() async {
    if (_isInitializingConnection) return;

    final ble = context.read<BleProvider>();
    if (!mounted) return;

    setState(() {
      _isInitializingConnection = true;
      _localError = null;
    });

    try {
      final granted = await ble.requestPermissions();
      if (!mounted) return;

      if (!granted) {
        setState(() {
          _localError =
              'Bluetooth permission is required to find your Guardian Watch.';
        });
        return;
      }

      await ble.startScan();
      if (!mounted) return;

      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (_) => _ScanSheet(
          ble: ble,
          onScanAgain: () {
            // Fire and forget — the sheet updates itself via the notifier.
            _scanAgain();
          },
        ),
      );
    } catch (e) {
      debugPrint('Guardian BLE scan error: $e');
      if (!mounted) return;
      _showErrorSnackBar('Unable to scan for Guardian Watch.');
    } finally {
      if (mounted) {
        setState(() {
          _isInitializingConnection = false;
        });
      }
    }
  }

  Future<void> _scanAgain() async {
    final ble = context.read<BleProvider>();

    try {
      await ble.startScan();
    } catch (e, stack) {
      debugPrint('Guardian scan retry error: $e');
      debugPrintStack(stackTrace: stack);
      if (!mounted) return;
      _showErrorSnackBar('Scan failed. Please try again.');
    }
  }

  void _showErrorSnackBar(String message) {
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

  // ─────────────────────────────────────────────────────────────────────────
  // Disconnect (with confirmation)
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _confirmDisconnect() async {
    final ble = context.read<BleProvider>();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Disconnect Guardian Watch?'),
        content: const Text(
          'Live heart rate, SpO₂, temperature and ECG readings will stop '
          'until you reconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    await ble.disconnect();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleProvider>();
    final auth = context.watch<AuthProvider>();
    final colorScheme = Theme.of(context).colorScheme;

    final isConnected = ble.isConnected;
    final isConnecting =
        _isInitializingConnection ||
        ble.status == BleStatus.connecting ||
        ble.status == BleStatus.scanning;

    final greetingName = _greetingName(
      auth.user?.displayName,
      auth.user?.email,
    );

    final error = _localError ?? ble.error;

    return RefreshIndicator(
      onRefresh: () async {
        // Do not re-animate the metrics grid — only reconnect if needed.
        if (!ble.isConnected && ble.lastConnectedDeviceId != null) {
          await _autoReconnect();
        } else if (mounted) {
          setState(() {});
        }
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverAppBar(
            floating: true,
            pinned: false,
            elevation: 0,
            backgroundColor: colorScheme.surface,
            surfaceTintColor: colorScheme.surface,
            title: Text(
              'Hello, $greetingName',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            actions: [
              _ConnectionIndicator(ble: ble, isConnecting: isConnecting),
              const SizedBox(width: 4),
              if (isConnected)
                IconButton(
                  tooltip: 'Open ECG monitor',
                  icon: const Icon(Icons.show_chart),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const EcgDetailScreen(),
                      ),
                    );
                  },
                ),
              const SizedBox(width: 8),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                if (error != null) ...[
                  _ErrorBanner(
                    message: error,
                    onRetry: () async {
                      if (mounted) {
                        setState(() {
                          _localError = null;
                        });
                      }
                      await _autoReconnect();
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                if (!isConnected) ...[
                  _ConnectBanner(
                    ble: ble,
                    isConnecting: isConnecting,
                    onScan: _startScan,
                  ),
                  const SizedBox(height: 20),
                ],
                FadeTransition(
                  opacity: _metricsFade,
                  child: _buildMetricsGrid(ble, colorScheme),
                ),
                const SizedBox(height: 18),
                _LastUpdatedLabel(
                  timestamp: _lastSensorUpdate ?? ble.latest?.timestamp,
                ),
                if (isConnected) ...[
                  const SizedBox(height: 20),
                  _buildEcgPreview(colorScheme),
                  const SizedBox(height: 20),
                  _buildDeviceStatusCard(ble, colorScheme),
                ],
              ]),
            ),
          ),
        ],
      ),
    );
  }

  /// Derives a friendly greeting name.
  ///
  /// Prefers the display name's first word. Falls back to the email prefix
  /// (capitalized), and finally to a neutral "there".
  String _greetingName(String? displayName, String? email) {
    final name = displayName?.trim() ?? '';
    if (name.isNotEmpty) {
      return name.split(RegExp(r'\s+')).first;
    }

    final emailPrefix = (email ?? '').split('@').first.trim();
    if (emailPrefix.isNotEmpty) {
      return emailPrefix[0].toUpperCase() + emailPrefix.substring(1);
    }

    return 'there';
  }

  Widget _buildMetricsGrid(BleProvider ble, ColorScheme colorScheme) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                icon: Icons.favorite_outline,
                label: 'Heart Rate',
                value: ble.heartRate?.toString() ?? '--',
                unit: 'bpm',
                color: const Color(0xFFE57373),
                onTap: ble.heartRate == null
                    ? null
                    : () => _showMetricDetail(
                        'Heart Rate',
                        ble.heartRate!.toString(),
                        'bpm',
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MetricCard(
                icon: Icons.air_outlined,
                label: 'SpO₂',
                value: ble.spo2?.toString() ?? '--',
                unit: '%',
                color: const Color(0xFF64B5F6),
                onTap: ble.spo2 == null
                    ? null
                    : () =>
                          _showMetricDetail('SpO₂', ble.spo2!.toString(), '%'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                icon: Icons.thermostat_outlined,
                label: 'Temperature',
                value: ble.temperature?.toStringAsFixed(1) ?? '--',
                unit: '°C',
                color: const Color(0xFFFFB74D),
                onTap: ble.temperature == null
                    ? null
                    : () => _showMetricDetail(
                        'Temperature',
                        ble.temperature!.toStringAsFixed(1),
                        '°C',
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MetricCard(
                icon: Icons.battery_std_outlined,
                label: 'Battery',
                value: ble.battery?.toString() ?? '--',
                unit: '%',
                color: const Color(0xFF81C784),
                onTap: ble.battery == null
                    ? null
                    : () => _showMetricDetail(
                        'Battery',
                        ble.battery!.toString(),
                        '%',
                      ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEcgPreview(ColorScheme colorScheme) {
    final hasData = _liveEcgSamples.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Text(
                    'Live ECG',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (hasData)
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colorScheme.primary,
                      ),
                    ),
                ],
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const EcgDetailScreen()),
                );
              },
              child: const Text('View Full'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: hasData
                ? SizedBox(
                    height: 160,
                    child: _EcgChart(
                      samples: _liveEcgSamples,
                      colorScheme: colorScheme,
                    ),
                  )
                : SizedBox(
                    height: 160,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.show_chart,
                            size: 32,
                            color: colorScheme.onSurface.withValues(alpha: 0.3),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Waiting for ECG signal...',
                            style: TextStyle(
                              color: colorScheme.onSurface.withValues(
                                alpha: 0.5,
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
    );
  }

  Widget _buildDeviceStatusCard(BleProvider ble, ColorScheme colorScheme) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.watch_outlined, color: colorScheme.primary),
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
                  const SizedBox(height: 3),
                  Text(
                    ble.lastConnectedDeviceId ?? 'Connected',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _confirmDisconnect,
              child: const Text('Disconnect'),
            ),
          ],
        ),
      ),
    );
  }

  void _showMetricDetail(String label, String value, String unit) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(label),
        content: Text(
          '$value $unit',
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Connection indicator
// ════════════════════════════════════════════════════════════════════════════

class _ConnectionIndicator extends StatelessWidget {
  final BleProvider ble;
  final bool isConnecting;

  const _ConnectionIndicator({required this.ble, required this.isConnecting});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (isConnecting) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2.3),
        ),
      );
    }

    final connected = ble.isConnected;
    final hasError = ble.status == BleStatus.error;

    final color = hasError
        ? colorScheme.error
        : connected
        ? colorScheme.primary
        : colorScheme.onSurface.withValues(alpha: 0.55);

    final text = hasError
        ? 'Error'
        : connected
        ? 'Connected'
        : 'Not connected';

    return Semantics(
      label: 'Guardian Watch connection status: $text',
      child: Container(
        margin: const EdgeInsets.only(right: 2),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              connected
                  ? Icons.bluetooth_connected
                  : hasError
                  ? Icons.error_outline
                  : Icons.bluetooth_disabled,
              size: 15,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              text,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Last sensor update
// ════════════════════════════════════════════════════════════════════════════

class _LastUpdatedLabel extends StatelessWidget {
  final DateTime? timestamp;

  const _LastUpdatedLabel({required this.timestamp});

  @override
  Widget build(BuildContext context) {
    if (timestamp == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final time = TimeOfDay.fromDateTime(timestamp!.toLocal());

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Icon(
          Icons.sync_outlined,
          size: 14,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
        ),
        const SizedBox(width: 5),
        Text(
          'Updated ${time.format(context)}',
          style: TextStyle(
            fontSize: 11,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Error banner
// ════════════════════════════════════════════════════════════════════════════

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      elevation: 0,
      color: colorScheme.errorContainer.withValues(alpha: 0.55),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: colorScheme.error),
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
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Connect banner
// ════════════════════════════════════════════════════════════════════════════

class _ConnectBanner extends StatelessWidget {
  final BleProvider ble;
  final bool isConnecting;
  final VoidCallback onScan;

  const _ConnectBanner({
    required this.ble,
    required this.isConnecting,
    required this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final connectionError = ble.status == BleStatus.error;

    final title = connectionError
        ? 'Connection problem'
        : isConnecting
        ? 'Connecting to Guardian Watch'
        : 'Connect your Guardian Watch';

    final subtitle = connectionError
        ? 'Check that Bluetooth is enabled and your watch is nearby.'
        : isConnecting
        ? 'Searching for your watch...'
        : 'Connect your watch to start receiving live health measurements.';

    return Card(
      color: connectionError
          ? colorScheme.errorContainer.withValues(alpha: 0.25)
          : colorScheme.primaryContainer.withValues(alpha: 0.22),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: connectionError
              ? colorScheme.error.withValues(alpha: 0.25)
              : colorScheme.primary.withValues(alpha: 0.20),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        (connectionError
                                ? colorScheme.error
                                : colorScheme.primary)
                            .withValues(alpha: 0.10),
                  ),
                  child: Icon(
                    connectionError
                        ? Icons.error_outline
                        : Icons.watch_outlined,
                    color: connectionError
                        ? colorScheme.error
                        : colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: connectionError
                          ? colorScheme.error
                          : colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              subtitle,
              style: TextStyle(
                color: colorScheme.onSurface.withValues(alpha: 0.70),
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: isConnecting ? null : onScan,
              icon: isConnecting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : const Icon(Icons.bluetooth_searching),
              label: Text(isConnecting ? 'Searching...' : 'Scan for Device'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Scan bottom sheet
// ════════════════════════════════════════════════════════════════════════════

class _ScanSheet extends StatelessWidget {
  final BleProvider ble;
  final VoidCallback onScanAgain;

  const _ScanSheet({required this.ble, required this.onScanAgain});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.60,
      minChildSize: 0.35,
      maxChildSize: 0.90,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Nearby Devices',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Select your Guardian Watch',
                          style: TextStyle(
                            fontSize: 13,
                            color: colorScheme.onSurface.withValues(
                              alpha: 0.60,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Scan again',
                    onPressed: onScanAgain,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ValueListenableBuilder<List<ScanResult>>(
                  valueListenable: ble.scanResultsNotifier,
                  builder: (context, results, _) {
                    if (results.isEmpty) {
                      return _EmptyScanState(onScanAgain: onScanAgain);
                    }

                    return ListView.builder(
                      controller: scrollController,
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final result = results[index];
                        return _DeviceTile(result: result, ble: ble);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Empty scan state
// ════════════════════════════════════════════════════════════════════════════

class _EmptyScanState extends StatelessWidget {
  final VoidCallback onScanAgain;

  const _EmptyScanState({required this.onScanAgain});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.bluetooth_searching,
            size: 52,
            color: colorScheme.onSurface.withValues(alpha: 0.30),
          ),
          const SizedBox(height: 14),
          Text(
            'No Guardian Watch found',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Make sure the watch is powered on and nearby.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: colorScheme.onSurface.withValues(alpha: 0.60),
            ),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: onScanAgain,
            icon: const Icon(Icons.refresh),
            label: const Text('Scan Again'),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Device tile
// ════════════════════════════════════════════════════════════════════════════

class _DeviceTile extends StatefulWidget {
  final ScanResult result;
  final BleProvider ble;

  const _DeviceTile({required this.result, required this.ble});

  @override
  State<_DeviceTile> createState() => _DeviceTileState();
}

class _DeviceTileState extends State<_DeviceTile> {
  bool _connecting = false;

  Future<void> _connect() async {
    if (_connecting) return;

    setState(() => _connecting = true);

    try {
      await widget.ble.connectTo(widget.result.device);
      if (!mounted) return;

      if (widget.ble.isConnected) {
        Navigator.of(context).pop();
      } else if (widget.ble.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.ble.error!),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } catch (e, stack) {
      debugPrint('Guardian device connection error: $e');
      debugPrintStack(stackTrace: stack);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Unable to connect to this device.'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _connecting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final device = widget.result.device;
    final advertisedName = widget.result.advertisementData.advName.trim();
    final platformName = device.platformName.trim();

    final name = platformName.isNotEmpty
        ? platformName
        : advertisedName.isNotEmpty
        ? advertisedName
        : 'Guardian Watch';

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colorScheme.primaryContainer.withValues(alpha: 0.5),
          ),
          child: Icon(Icons.watch_outlined, color: colorScheme.primary),
        ),
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
        subtitle: Text(
          'Signal ${widget.result.rssi} dBm',
          style: TextStyle(
            fontSize: 12,
            color: colorScheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
        trailing: FilledButton(
          onPressed: _connecting ? null : _connect,
          child: _connecting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Connect'),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Metric card
// ════════════════════════════════════════════════════════════════════════════

class _MetricCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String unit;
  final Color color;
  final VoidCallback? onTap;

  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.65),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color.withValues(alpha: 0.12),
                    ),
                    child: Icon(icon, color: color, size: 22),
                  ),
                  if (onTap != null)
                    Icon(
                      Icons.chevron_right,
                      color: colorScheme.onSurface.withValues(alpha: 0.30),
                      size: 18,
                    ),
                ],
              ),
              const SizedBox(height: 11),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.onSurface.withValues(alpha: 0.60),
                ),
              ),
              const SizedBox(height: 3),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Flexible(
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      unit,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurface.withValues(alpha: 0.50),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// ECG chart
// ════════════════════════════════════════════════════════════════════════════

class _EcgChart extends StatelessWidget {
  final List<double> samples;
  final ColorScheme colorScheme;

  const _EcgChart({required this.samples, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    if (samples.isEmpty) return const SizedBox.shrink();

    const maxDisplayPoints = 500;
    final displaySamples = _downsample(samples, maxDisplayPoints);

    final spots = List<FlSpot>.generate(
      displaySamples.length,
      (index) => FlSpot(index.toDouble(), displaySamples[index]),
    );

    var minY = displaySamples.reduce((a, b) => a < b ? a : b);
    var maxY = displaySamples.reduce((a, b) => a > b ? a : b);

    if (!minY.isFinite || !maxY.isFinite) {
      return const Center(child: Text('Invalid ECG signal'));
    }

    if (minY == maxY) {
      minY -= 1;
      maxY += 1;
    }

    final range = maxY - minY;
    final padding = range <= 0 ? 1.0 : range * 0.15;

    minY -= padding;
    maxY += padding;

    return RepaintBoundary(
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: math.max(0, spots.length - 1).toDouble(),
          minY: minY,
          maxY: maxY,
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: false,
              color: colorScheme.primary,
              barWidth: 1.5,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: colorScheme.primary.withValues(alpha: 0.05),
              ),
            ),
          ],
          gridData: FlGridData(
            show: true,
            drawHorizontalLine: true,
            drawVerticalLine: false,
            horizontalInterval: math.max(range / 4, 0.000001),
            getDrawingHorizontalLine: (value) => FlLine(
              color: colorScheme.outlineVariant.withValues(alpha: 0.30),
              strokeWidth: 0.6,
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: const FlTitlesData(show: false),
          clipData: const FlClipData.all(),
        ),
        duration: Duration.zero,
      ),
    );
  }

  static List<double> _downsample(List<double> input, int target) {
    if (input.length <= target) return List<double>.from(input);

    final result = <double>[];
    final step = input.length / target;

    for (var i = 0; i < target; i++) {
      final index = (i * step).floor();
      result.add(input[index.clamp(0, input.length - 1)]);
    }

    return result;
  }
}
