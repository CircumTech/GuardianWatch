// ════════════════════════════════════════════════════════════════════════════
// lib/features/ecg/screens/ecg_detail_screen.dart
// ════════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../../providers/ble_provider.dart';

class EcgDetailScreen extends StatefulWidget {
  const EcgDetailScreen({super.key});

  @override
  State<EcgDetailScreen> createState() => _EcgDetailScreenState();
}

class _EcgDetailScreenState extends State<EcgDetailScreen> {
  // Rolling buffer – last 500 samples
  static const int _maxSamples = 500;
  final List<double> _buffer = [];

  // Stream subscription for ECG data
  StreamSubscription<List<double>>? _ecgSubscription;

  // UI state
  bool _isPaused = false;
  double _currentSampleRate = 0;
  final Stopwatch _sampleStopwatch = Stopwatch();
  int _samplesReceived = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subscribeToEcgStream();
  }

  void _subscribeToEcgStream() {
    final ble = context.read<BleProvider>();
    _ecgSubscription = ble.ecgStream.listen((samples) {
      if (_isPaused) return;

      // Update sample rate stats
      _samplesReceived += samples.length;
      if (!_sampleStopwatch.isRunning) {
        _sampleStopwatch.start();
      } else if (_sampleStopwatch.elapsedMilliseconds >= 1000) {
        setState(() {
          _currentSampleRate =
              _samplesReceived / (_sampleStopwatch.elapsedMilliseconds / 1000);
        });
        _samplesReceived = 0;
        _sampleStopwatch.reset();
        _sampleStopwatch.start();
      }

      // Add samples to buffer
      setState(() {
        _buffer.addAll(samples);
        if (_buffer.length > _maxSamples) {
          _buffer.removeRange(0, _buffer.length - _maxSamples);
        }
      });
    }, onError: (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    });
  }

  @override
  void dispose() {
    _ecgSubscription?.cancel();
    _sampleStopwatch.stop();
    super.dispose();
  }

  void _clearBuffer() {
    setState(() {
      _buffer.clear();
      _samplesReceived = 0;
      _sampleStopwatch.reset();
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hr = context.select<BleProvider, int?>((b) => b.heartRate);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ECG Monitor'),
        actions: [
          IconButton(
            icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
            onPressed: () => setState(() => _isPaused = !_isPaused),
            tooltip: _isPaused ? 'Resume' : 'Pause',
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: _clearBuffer,
            tooltip: 'Clear chart',
          ),
          const SizedBox(width: 4),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Chip(
              avatar:
                  const Icon(Icons.favorite, size: 14, color: Colors.redAccent),
              label: Text(hr != null ? '$hr bpm' : '-- bpm'),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status row
            Row(
              children: [
                _StatusBadge(hr: hr),
                const Spacer(),
                if (_currentSampleRate > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: cs.primaryContainer,
                    ),
                    child: Text(
                      '${_currentSampleRate.toStringAsFixed(0)} sps',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),

            // ECG chart panel
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 20, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Live ECG strip',
                              style: Theme.of(context).textTheme.labelMedium),
                          if (_isPaused)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: Colors.orange,
                              ),
                              child: const Text('PAUSED',
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: _buildChart(cs),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'mV (millivolts)  •  ${_buffer.length} / $_maxSamples samples',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Info cards
            Row(
              children: [
                Expanded(
                    child: _InfoCard(
                  label: 'Buffer',
                  value: '${_buffer.length}',
                  sub: '/ $_maxSamples max',
                )),
                const SizedBox(width: 12),
                Expanded(
                    child: _InfoCard(
                  label: 'Peak (mV)',
                  value: _buffer.isEmpty
                      ? '--'
                      : _buffer
                          .reduce((a, b) => a > b ? a : b)
                          .toStringAsFixed(3),
                  sub: 'max voltage',
                )),
                const SizedBox(width: 12),
                Expanded(
                    child: _InfoCard(
                  label: 'Trough (mV)',
                  value: _buffer.isEmpty
                      ? '--'
                      : _buffer
                          .reduce((a, b) => a < b ? a : b)
                          .toStringAsFixed(3),
                  sub: 'min voltage',
                )),
              ],
            ),
            const SizedBox(height: 16),

            // Error message
            if (_error != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: cs.errorContainer,
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: cs.error),
                    const SizedBox(width: 8),
                    Expanded(
                        child:
                            Text(_error!, style: TextStyle(color: cs.error))),
                    TextButton(
                      onPressed: () {
                        setState(() => _error = null);
                        _subscribeToEcgStream();
                      },
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),

            // Medical disclaimer
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: cs.errorContainer.withValues(alpha: 0.4),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: cs.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This ECG is for informational purposes only and is not a '
                      'medical-grade reading. Consult a physician for clinical diagnosis.',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: cs.error),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChart(ColorScheme cs) {
    if (_buffer.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Waiting for ECG data…',
              style: TextStyle(color: Colors.grey.shade500),
            ),
            const SizedBox(height: 8),
            Text(
              'Make sure your GuardianWrist is connected.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
            ),
          ],
        ),
      );
    }

    final spots = List.generate(
      _buffer.length,
      (i) => FlSpot(i.toDouble(), _buffer[i]),
    );

    return RepaintBoundary(
      child: LineChart(
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
          minY: -1.5,
          maxY: 1.5,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: true,
            horizontalInterval: 0.5,
            verticalInterval: 50,
            getDrawingHorizontalLine: (_) => FlLine(
                color: Colors.grey.withValues(alpha: 0.15), strokeWidth: 0.8),
            getDrawingVerticalLine: (_) => FlLine(
                color: Colors.grey.withValues(alpha: 0.1), strokeWidth: 0.8),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 0.5,
                reservedSize: 36,
                getTitlesWidget: (value, _) => Text(
                  value.toStringAsFixed(1),
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 100,
                getTitlesWidget: (value, _) => Text(
                  '${value.toInt()}',
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            ),
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
        ),
        duration: Duration.zero,
      ),
    );
  }
}

// ============================================================================
// Status Badge
// ============================================================================

class _StatusBadge extends StatelessWidget {
  final int? hr;
  const _StatusBadge({this.hr});

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = hr == null
        ? ('Waiting for data', Colors.grey, Icons.hourglass_empty)
        : hr! > 100
            ? ('Elevated heart rate', Colors.orange, Icons.warning_amber)
            : hr! < 50
                ? ('Low heart rate', Colors.blue, Icons.arrow_downward)
                : ('Normal rhythm', Colors.green, Icons.check_circle_outline);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: color.withValues(alpha: 0.15),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ============================================================================
// Info Card
// ============================================================================

class _InfoCard extends StatelessWidget {
  final String label, value, sub;
  const _InfoCard(
      {required this.label, required this.value, required this.sub});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            Text(
              value,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              sub,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }
}
