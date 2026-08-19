// ════════════════════════════════════════════════════════════════════════════
// lib/features/dashboard/screens/dashboard_screen.dart
// ════════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shimmer/shimmer.dart';
import '../../../providers/ble_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../history/screens/history_screen.dart';
import '../../insights/screens/insights_screen.dart';
import '../../settings/screens/settings_screen.dart';
import '../../ecg/screens/ecg_detail_screen.dart';

// ============================================================================
// Main Dashboard Screen (Bottom Navigation)
// ============================================================================

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin {
  int _selectedIndex = 0;

  late final List<Widget> _tabs;
  late final List<NavigationDestination> _destinations;

  @override
  void initState() {
    super.initState();
    _tabs = const [
      _HomeTab(),
      HistoryScreen(),
      InsightsScreen(),
      SettingsScreen(),
    ];
    _destinations = const [
      NavigationDestination(
        icon: Icon(Icons.dashboard_outlined),
        label: 'Dashboard',
      ),
      NavigationDestination(
        icon: Icon(Icons.history_outlined),
        label: 'History',
      ),
      NavigationDestination(
        icon: Icon(Icons.auto_awesome_outlined),
        label: 'Insights',
      ),
      NavigationDestination(
        icon: Icon(Icons.settings_outlined),
        label: 'Settings',
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _tabs[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() => _selectedIndex = index);
        },
        destinations: _destinations,
        animationDuration: const Duration(milliseconds: 300),
        height: 64,
        elevation: 0,
        surfaceTintColor: Theme.of(context).colorScheme.surface,
        indicatorColor: Theme.of(context).colorScheme.primaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
    );
  }
}

// ============================================================================
// Home Tab
// ============================================================================

class _HomeTab extends StatefulWidget {
  const _HomeTab();

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab>
    with SingleTickerProviderStateMixin {
  bool _isConnecting = false;
  String? _errorMessage;

  // Animation for metric cards
  late final AnimationController _metricsController;
  late final Animation<double> _metricsFade;

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

    _checkPermissionsAndAutoConnect();
  }

  @override
  void dispose() {
    _metricsController.dispose();
    super.dispose();
  }

  Future<void> _checkPermissionsAndAutoConnect() async {
    final ble = context.read<BleProvider>();
    ble.requestPermissions();
    ble.startScan();
    final status = await _requestBluetoothPermissions();
    if (!status) {
      setState(
        () => _errorMessage =
            'Bluetooth permission denied. Cannot connect to watch.',
      );
      return;
    }

    if (ble.lastConnectedDeviceId != null &&
        ble.status != BleStatus.connected) {
      setState(() => _isConnecting = true);
      try {
        await ble.autoReconnect();
      } catch (e) {
        setState(() => _errorMessage = 'Auto-reconnect failed: $e');
      } finally {
        if (mounted) setState(() => _isConnecting = false);
      }
    }
    _metricsController.forward();
  }

  Future<bool> _requestBluetoothPermissions() async {
    if (await Permission.bluetooth.isDenied) {
      final status = await Permission.bluetooth.request();
      if (status.isDenied) return false;
    }
    if (await Permission.bluetoothScan.isDenied) {
      final status = await Permission.bluetoothScan.request();
      if (status.isDenied) return false;
    }
    if (await Permission.bluetoothConnect.isDenied) {
      final status = await Permission.bluetoothConnect.request();
      if (status.isDenied) return false;
    }
    if (await Permission.location.isDenied) {
      final status = await Permission.location.request();
      if (status.isDenied) return false;
    }
    return true;
  }

  void _showErrorSnackBar(String message) {
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

  Future<void> _startScan() async {
    setState(() => _isConnecting = true);
    try {
      final ble = context.read<BleProvider>();
      await ble.startScan();
      if (!mounted) return;
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => _ScanSheet(ble: ble),
      );
    } catch (e) {
      _showErrorSnackBar('Scan failed: $e');
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleProvider>();
    final auth = context.watch<AuthProvider>();
    final cs = Theme.of(context).colorScheme;
    final isConnected = context.select<BleProvider, bool>(
      (b) => b.status == BleStatus.connected,
    );
    final userName = context.select<AuthProvider, String?>(
      (a) => a.user?.displayName?.split(' ').first,
    );
    return RefreshIndicator(
      onRefresh: () async {
        if (!isConnected) {
          await _checkPermissionsAndAutoConnect();
        }
        _metricsController.forward(from: 0);
      },
      child: CustomScrollView(
        slivers: [
          // App Bar
          SliverAppBar(
            title: Text(
              'Hello, ${auth.user?.displayName?.split(' ').first ?? 'there'}',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            actions: [
              // Connection status indicator
              if (_isConnecting)
                const Padding(
                  padding: EdgeInsets.only(right: 16),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                )
              else if (isConnected)
                Container(
                  margin: const EdgeInsets.only(right: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.bluetooth_connected,
                        size: 16,
                        color: cs.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Connected',
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                )
              else if (ble.status == BleStatus.error)
                Container(
                  margin: const EdgeInsets.only(right: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: cs.errorContainer.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline, size: 16, color: cs.error),
                      const SizedBox(width: 4),
                      Text(
                        'Error',
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.error,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              // ECG button
              if (isConnected)
                IconButton(
                  icon: const Icon(Icons.show_chart),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const EcgDetailScreen()),
                  ),
                  tooltip: 'ECG Monitor',
                ),
            ],
            floating: true,
            elevation: 0,
            backgroundColor: cs.surface,
          ),

          // Content
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // Error banner
                if (_errorMessage != null) _buildErrorBanner(cs),

                // Connect banner
                if (!isConnected && _errorMessage == null)
                  _ConnectBanner(
                    ble: ble,
                    isConnecting: _isConnecting,
                    onScan: _startScan,
                  ),

                // Metrics
                FadeTransition(
                  opacity: _metricsFade,
                  child: _buildMetricsGrid(ble, cs),
                ),

                const SizedBox(height: 20),

                // ECG preview
                if (isConnected) _buildEcgPreview(ble, cs),

                const SizedBox(height: 32),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(ColorScheme cs) {
    return Card(
      color: cs.errorContainer.withOpacity(0.2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.error.withOpacity(0.3), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: cs.error, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _errorMessage!,
                style: TextStyle(color: cs.onSurface, fontSize: 14),
              ),
            ),
            TextButton(
              onPressed: () {
                setState(() => _errorMessage = null);
                _checkPermissionsAndAutoConnect();
              },
              style: TextButton.styleFrom(foregroundColor: cs.primary),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricsGrid(BleProvider ble, ColorScheme cs) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                icon: Icons.favorite_outline,
                label: 'Heart Rate',
                value: ble.heartRate != null ? '${ble.heartRate}' : '--',
                unit: 'bpm',
                color: const Color(0xFFE57373),
                onTap: () => _showMetricDetail(
                  'Heart Rate',
                  ble.heartRate?.toString() ?? '--',
                  'bpm',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MetricCard(
                icon: Icons.air_outlined,
                label: 'SpO₂',
                value: ble.spo2 != null ? '${ble.spo2}' : '--',
                unit: '%',
                color: const Color(0xFF64B5F6),
                onTap: () => _showMetricDetail(
                  'SpO₂',
                  ble.spo2?.toString() ?? '--',
                  '%',
                ),
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
                value: ble.temperature != null
                    ? ble.temperature!.toStringAsFixed(1)
                    : '--',
                unit: '°C',
                color: const Color(0xFFFFB74D),
                onTap: () => _showMetricDetail(
                  'Temperature',
                  ble.temperature?.toStringAsFixed(1) ?? '--',
                  '°C',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MetricCard(
                icon: Icons.battery_std_outlined,
                label: 'Battery',
                value: ble.battery != null ? '${ble.battery}' : '--',
                unit: '%',
                color: const Color(0xFF81C784),
                onTap: null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEcgPreview(BleProvider ble, ColorScheme cs) {
    final hasData = ble.ecgMv != null && ble.ecgMv!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Live ECG',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const EcgDetailScreen()),
              ),
              style: TextButton.styleFrom(foregroundColor: cs.primary),
              child: const Text('View Full'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: cs.outline.withOpacity(0.1)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: hasData
                ? SizedBox(height: 120, child: _EcgChart(samples: ble.ecgMv!))
                : SizedBox(
                    height: 120,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.show_chart,
                            size: 28,
                            color: cs.onSurface.withOpacity(0.3),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Waiting for ECG signal...',
                            style: TextStyle(
                              color: cs.onSurface.withOpacity(0.5),
                              fontSize: 14,
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

  void _showMetricDetail(String label, String value, String unit) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(label),
        content: Text(
          'Current value: $value $unit',
          style: const TextStyle(fontSize: 18),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Connect Banner
// ============================================================================

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
    final cs = Theme.of(context).colorScheme;
    final isError = ble.status == BleStatus.error;

    return Card(
      color: cs.primaryContainer.withOpacity(0.1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isError
              ? cs.error.withOpacity(0.3)
              : cs.primary.withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isError ? Icons.error_outline : Icons.bluetooth_disabled,
                  color: isError ? cs.error : cs.primary,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    isError ? 'Connection Error' : 'No Watch Connected',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: isError ? cs.error : cs.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              isError
                  ? 'Failed to connect. Please check Bluetooth and try again.'
                  : 'Scan to pair your GuardianWrist device.',
              style: TextStyle(
                color: cs.onSurface.withOpacity(0.7),
                fontSize: 14,
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
              label: Text(isConnecting ? 'Connecting...' : 'Scan for Device'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
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

// ============================================================================
// Scan Sheet
// ============================================================================

class _ScanSheet extends StatelessWidget {
  final BleProvider ble;
  const _ScanSheet({required this.ble});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: cs.outline.withOpacity(0.4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Nearby Devices',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Make sure your watch is in pairing mode',
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder(
              valueListenable: ble.scanResultsNotifier,
              builder: (context, results, _) {
                if (results.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Column(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text(
                            'No devices found.\nTap scan to search again.',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return Column(
                  children: results.map((r) {
                    return Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: cs.outline.withOpacity(0.1)),
                      ),
                      child: ListTile(
                        leading: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: cs.primaryContainer.withOpacity(0.3),
                          ),
                          child: Icon(Icons.watch_outlined, color: cs.primary),
                        ),
                        title: Text(
                          r.device.platformName.isEmpty
                              ? 'GuardianWrist'
                              : r.device.platformName,
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: cs.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          r.device.remoteId.str,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withOpacity(0.6),
                          ),
                        ),
                        trailing: OutlinedButton(
                          onPressed: () async {
                            Navigator.pop(context);
                            try {
                              await ble.connectTo(r.device);
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Connection failed: $e'),
                                    backgroundColor: cs.error,
                                  ),
                                );
                              }
                            }
                          },
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: const Text('Connect'),
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Metric Card
// ============================================================================

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
    final cs = Theme.of(context).colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outline.withOpacity(0.08)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
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
                      color: color.withOpacity(0.12),
                    ),
                    child: Icon(icon, color: color, size: 22),
                  ),
                  if (onTap != null)
                    Icon(
                      Icons.chevron_right,
                      color: cs.onSurface.withOpacity(0.3),
                      size: 18,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface.withOpacity(0.6),
                ),
              ),
              const SizedBox(height: 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      unit,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withOpacity(0.5),
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

// ============================================================================
// ECG Chart (Optimised)
// ============================================================================

class _EcgChart extends StatelessWidget {
  final List<double> samples;
  const _EcgChart({required this.samples});

  @override
  Widget build(BuildContext context) {
    final spots = List.generate(
      samples.length,
      (i) => FlSpot(i.toDouble(), samples[i]),
    );

    return RepaintBoundary(
      child: LineChart(
        LineChartData(
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: false,
              color: Colors.greenAccent.shade700,
              barWidth: 1.8,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: Colors.greenAccent.withOpacity(0.08),
              ),
            ),
          ],
          gridData: FlGridData(
            show: true,
            drawHorizontalLine: true,
            drawVerticalLine: false,
            horizontalInterval: 0.5,
            getDrawingHorizontalLine: (value) =>
                FlLine(color: Colors.grey.withOpacity(0.1), strokeWidth: 0.5),
          ),
          borderData: FlBorderData(show: false),
          titlesData: const FlTitlesData(show: false),
          minY: -1.5,
          maxY: 1.5,
        ),
        duration: Duration.zero,
      ),
    );
  }
}
