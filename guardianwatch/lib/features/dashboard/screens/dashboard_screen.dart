// ════════════════════════════════════════════════════════════════════════════
// lib/features/dashboard/screens/dashboard_screen.dart
// ════════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../providers/ble_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../history/screens/history_screen.dart';
import '../../insights/screens/insights_screen.dart';
import '../../settings/screens/settings_screen.dart';
import '../../ecg/screens/ecg_detail_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _tab = 0;

  static const _tabs = <Widget>[
    _HomeTab(),
    HistoryScreen(),
    InsightsScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _tabs[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.dashboard_outlined), label: 'Dashboard'),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
          NavigationDestination(
              icon: Icon(Icons.auto_awesome_outlined), label: 'Insights'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined), label: 'Settings'),
        ],
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

class _HomeTabState extends State<_HomeTab> {
  bool _isConnecting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _checkPermissionsAndAutoConnect();
  }

  Future<void> _checkPermissionsAndAutoConnect() async {
    final ble = context.read<BleProvider>();
    final status = await _requestBluetoothPermissions();
    if (!status) {
      setState(() => _errorMessage =
          'Bluetooth permission denied. Cannot connect to watch.');
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
      SnackBar(content: Text(message), backgroundColor: Colors.red),
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

    return RefreshIndicator(
      onRefresh: () async {
        if (ble.status != BleStatus.connected) {
          await _checkPermissionsAndAutoConnect();
        }
      },
      child: CustomScrollView(
        slivers: [
          SliverAppBar(
            title: Text(
                'Hi, ${auth.user?.displayName?.split(' ').first ?? 'there'} 👋'),
            actions: [
              if (_isConnecting)
                const Padding(
                  padding: EdgeInsets.only(right: 16),
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else if (ble.status == BleStatus.connected)
                const Padding(
                  padding: EdgeInsets.only(right: 16),
                  child: Icon(Icons.bluetooth_connected, color: Colors.green),
                )
              else if (ble.status == BleStatus.error)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Icon(Icons.bluetooth_disabled, color: cs.error),
                ),
              if (ble.status == BleStatus.connected)
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
          ),
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                if (_errorMessage != null)
                  Card(
                    color: cs.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline, color: cs.error),
                          const SizedBox(width: 12),
                          Expanded(child: Text(_errorMessage!)),
                          TextButton(
                            onPressed: () {
                              setState(() => _errorMessage = null);
                              _checkPermissionsAndAutoConnect();
                            },
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_errorMessage != null) const SizedBox(height: 12),
                if (ble.status != BleStatus.connected &&
                    _errorMessage == null) ...[
                  _ConnectBanner(
                    ble: ble,
                    isConnecting: _isConnecting,
                    onScan: _startScan,
                  ),
                  const SizedBox(height: 20),
                ],
                Row(children: [
                  Expanded(
                      child: _MetricCard(
                    icon: Icons.favorite,
                    label: 'Heart Rate',
                    value: ble.heartRate != null ? '${ble.heartRate}' : '--',
                    unit: 'bpm',
                    color: Colors.redAccent,
                    onTap: () => _showDetail(
                        'Heart Rate', ble.heartRate?.toString() ?? '--', 'bpm'),
                  )),
                  const SizedBox(width: 12),
                  Expanded(
                      child: _MetricCard(
                    icon: Icons.air,
                    label: 'SpO₂',
                    value: ble.spo2 != null ? '${ble.spo2}' : '--',
                    unit: '%',
                    color: Colors.blueAccent,
                    onTap: () =>
                        _showDetail('SpO₂', ble.spo2?.toString() ?? '--', '%'),
                  )),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                      child: _MetricCard(
                    icon: Icons.thermostat,
                    label: 'Temperature',
                    value: ble.temperature != null
                        ? ble.temperature!.toStringAsFixed(1)
                        : '--',
                    unit: '°C',
                    color: Colors.orangeAccent,
                    onTap: () => _showDetail('Temperature',
                        ble.temperature?.toStringAsFixed(1) ?? '--', '°C'),
                  )),
                  const SizedBox(width: 12),
                  Expanded(
                      child: _MetricCard(
                    icon: Icons.battery_full,
                    label: 'Battery',
                    value: ble.battery != null ? '${ble.battery}' : '--',
                    unit: '%',
                    color: Colors.greenAccent,
                  )),
                ]),
                const SizedBox(height: 20),
                if (ble.ecgMv != null && ble.ecgMv!.isNotEmpty) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Live ECG',
                          style: Theme.of(context).textTheme.titleMedium),
                      TextButton(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const EcgDetailScreen()),
                        ),
                        child: const Text('Details'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(height: 120, child: _EcgChart(samples: ble.ecgMv!)),
                  const SizedBox(height: 20),
                ] else if (ble.status == BleStatus.connected) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: cs.surfaceContainerHighest.withOpacity(0.5),
                    ),
                    child: const Center(child: Text('Waiting for ECG data...')),
                  ),
                  const SizedBox(height: 20),
                ],
              ]),
            ),
          ),
        ],
      ),
    );
  }

  void _showDetail(String label, String value, String unit) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(label),
        content: Text('Current value: $value $unit'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(_), child: const Text('Close')),
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
    return Card(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              ble.status == BleStatus.error
                  ? 'Connection Error'
                  : 'No watch connected',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              ble.status == BleStatus.error
                  ? 'Failed to connect. Please check Bluetooth and try again.'
                  : 'Scan to pair your GuardianWrist.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: isConnecting ? null : onScan,
              icon: isConnecting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.bluetooth_searching),
              label: Text(isConnecting ? 'Connecting...' : 'Scan for watch'),
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
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Nearby devices',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            ValueListenableBuilder(
              valueListenable: ble.scanResultsNotifier,
              builder: (context, results, _) {
                if (results.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                          'No GuardianWrist devices found.\nMake sure your watch is in pairing mode.'),
                    ),
                  );
                }
                return Column(
                  children: results.map((r) {
                    return ListTile(
                      leading: const Icon(Icons.watch),
                      title: Text(r.device.platformName.isEmpty
                          ? 'GuardianWrist'
                          : r.device.platformName),
                      subtitle: Text(r.device.remoteId.str),
                      onTap: () async {
                        Navigator.pop(context);
                        try {
                          await ble.connectTo(r.device);
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Connection failed: $e')),
                            );
                          }
                        }
                      },
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
  final String label, value, unit;
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
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(icon, color: color, size: 24),
                  if (onTap != null)
                    Icon(Icons.chevron_right,
                        color: Colors.grey.shade400, size: 18),
                ],
              ),
              const SizedBox(height: 10),
              Text(label, style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    value,
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(unit,
                        style: Theme.of(context).textTheme.bodySmall),
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
// ECG Chart (optimised)
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

    return LineChart(
      LineChartData(
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: false,
            color: Colors.greenAccent,
            barWidth: 1.5,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: false),
          ),
        ],
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: const FlTitlesData(show: false),
        minY: -1.5,
        maxY: 1.5,
      ),
      duration: Duration.zero,
    );
  }
}
