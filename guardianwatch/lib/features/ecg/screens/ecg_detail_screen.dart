// ════════════════════════════════════════════════════════════════════════════
// lib/features/ecg/screens/ecg_detail_screen.dart
// ════════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../../providers/ble_provider.dart';

// ============================================================================
// ECG Detail Screen
// ============================================================================

class EcgDetailScreen extends StatefulWidget {
  const EcgDetailScreen({super.key});

  @override
  State<EcgDetailScreen> createState() => _EcgDetailScreenState();
}

class _EcgDetailScreenState extends State<EcgDetailScreen>
    with TickerProviderStateMixin {
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
  Timer? _uiUpdateTimer;

  // Animation for chart updates
  late final AnimationController _chartController;
  late final Animation<double> _chartFade;

  @override
  void initState() {
    super.initState();
    _chartController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _chartFade = CurvedAnimation(
      parent: _chartController,
      curve: Curves.easeOut,
    );
    _chartController.forward();
    _subscribeToEcgStream();
  }

  void _subscribeToEcgStream() {
    final ble = context.read<BleProvider>();
    _ecgSubscription = ble.ecgStream.listen(
      (samples) {
        if (_isPaused) return;

        // Update sample rate stats
        _samplesReceived += samples.length;
        if (!_sampleStopwatch.isRunning) {
          _sampleStopwatch.start();
        } else if (_sampleStopwatch.elapsedMilliseconds >= 1000) {
          setState(() {
            _currentSampleRate =
                _samplesReceived /
                (_sampleStopwatch.elapsedMilliseconds / 1000);
          });
          _samplesReceived = 0;
          _sampleStopwatch.reset();
          _sampleStopwatch.start();
        }

        // Add samples to buffer
        _buffer.addAll(samples);
        if (_buffer.length > _maxSamples) {
          _buffer.removeRange(0, _buffer.length - _maxSamples);
        }
      },
      onError: (error) {
        if (mounted) {
          setState(() => _error = error.toString());
        }
      },
    );
    _uiUpdateTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (mounted && !_isPaused && _buffer.isNotEmpty) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ecgSubscription?.cancel();
    _sampleStopwatch.stop();
    _uiUpdateTimer?.cancel();
    _chartController.dispose();
    super.dispose();
  }

  void _clearBuffer() {
    setState(() {
      _buffer.clear();
      _samplesReceived = 0;
      _sampleStopwatch.reset();
      _error = null;
      _chartController.reset();
      _chartController.forward();
    });
  }

  void _togglePause() {
    setState(() => _isPaused = !_isPaused);
    if (!_isPaused) {
      _chartController.reset();
      _chartController.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hr = context.select<BleProvider, int?>((b) => b.heartRate);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ECG Monitor'),
        elevation: 0,
        backgroundColor: cs.surface,
        actions: [
          IconButton(
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Icon(
                _isPaused ? Icons.play_arrow : Icons.pause,
                key: ValueKey(_isPaused),
              ),
            ),
            onPressed: _togglePause,
            tooltip: _isPaused ? 'Resume' : 'Pause',
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: _clearBuffer,
            tooltip: 'Clear chart',
          ),
          const SizedBox(width: 4),
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withOpacity(0.3),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.favorite,
                  size: 16,
                  color: hr != null
                      ? Colors.redAccent
                      : cs.onSurface.withOpacity(0.4),
                ),
                const SizedBox(width: 6),
                Text(
                  hr != null ? '$hr bpm' : '-- bpm',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: hr != null
                        ? cs.onSurface
                        : cs.onSurface.withOpacity(0.4),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status Row
            _buildStatusRow(hr, cs),

            const SizedBox(height: 16),

            // ECG Chart Panel
            Expanded(flex: 2, child: _buildChartPanel(cs)),

            const SizedBox(height: 16),

            // Info Cards
            _buildInfoCards(cs),

            const SizedBox(height: 16),

            // Error Display
            if (_error != null) _buildErrorDisplay(cs),

            // Medical Disclaimer
            _buildDisclaimer(cs),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRow(int? hr, ColorScheme cs) {
    final (label, color, icon) = _getStatusData(hr);

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: color.withOpacity(0.12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        if (_currentSampleRate > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: cs.primaryContainer.withOpacity(0.3),
            ),
            child: Text(
              '${_currentSampleRate.toStringAsFixed(0)} samples/s',
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withOpacity(0.7),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
      ],
    );
  }

  (String, Color, IconData) _getStatusData(int? hr) {
    if (hr == null) {
      return ('Waiting for data', Colors.grey, Icons.hourglass_empty);
    }
    if (hr > 100) {
      return (
        'Elevated heart rate',
        Colors.orange,
        Icons.warning_amber_rounded,
      );
    }
    if (hr < 50) {
      return ('Low heart rate', Colors.blue, Icons.arrow_downward_rounded);
    }
    return ('Normal rhythm', Colors.green, Icons.check_circle_outline_rounded);
  }

  Widget _buildChartPanel(ColorScheme cs) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outline.withOpacity(0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Live ECG',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                if (_isPaused)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: Colors.orange.withOpacity(0.15),
                    ),
                    child: Text(
                      'PAUSED',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.orange.shade700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FadeTransition(
                opacity: _chartFade,
                child: _buildChart(cs),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'millivolts (mV)  •  ${_buffer.length} / $_maxSamples samples',
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurface.withOpacity(0.4),
                fontWeight: FontWeight.w400,
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
            Container(
              width: 32,
              height: 32,
              padding: const EdgeInsets.all(4),
              child: const CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(height: 12),
            Text(
              'Waiting for ECG signal...',
              style: TextStyle(
                color: cs.onSurface.withOpacity(0.5),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Ensure your GuardianWrist is connected',
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withOpacity(0.3),
              ),
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
              color: const Color(0xFF4CAF50),
              barWidth: 1.8,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: const Color(0xFF4CAF50).withOpacity(0.06),
              ),
            ),
          ],
          minY: -1.5,
          maxY: 1.5,
          gridData: FlGridData(
            show: true,
            drawHorizontalLine: true,
            drawVerticalLine: true,
            horizontalInterval: 0.5,
            verticalInterval: 50,
            getDrawingHorizontalLine: (value) =>
                FlLine(color: Colors.grey.withOpacity(0.08), strokeWidth: 0.5),
            getDrawingVerticalLine: (value) =>
                FlLine(color: Colors.grey.withOpacity(0.05), strokeWidth: 0.5),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 0.5,
                reservedSize: 36,
                getTitlesWidget: (value, _) => Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    value.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: 9,
                      color: cs.onSurface.withOpacity(0.4),
                    ),
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 100,
                getTitlesWidget: (value, _) => Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    value.toInt().toString(),
                    style: TextStyle(
                      fontSize: 9,
                      color: cs.onSurface.withOpacity(0.3),
                    ),
                  ),
                ),
              ),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
          ),
        ),
        duration: Duration.zero,
      ),
    );
  }

  Widget _buildInfoCards(ColorScheme cs) {
    final peak = _buffer.isEmpty
        ? '--'
        : _buffer.reduce((a, b) => a > b ? a : b).toStringAsFixed(3);
    final trough = _buffer.isEmpty
        ? '--'
        : _buffer.reduce((a, b) => a < b ? a : b).toStringAsFixed(3);

    return Row(
      children: [
        Expanded(
          child: _InfoCard(
            label: 'Buffer',
            value: '${_buffer.length}',
            sub: 'of $_maxSamples',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _InfoCard(label: 'Peak', value: peak, sub: 'mV'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _InfoCard(label: 'Trough', value: trough, sub: 'mV'),
        ),
      ],
    );
  }

  Widget _buildErrorDisplay(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: cs.errorContainer.withOpacity(0.15),
        border: Border.all(color: cs.error.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: cs.error, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _error!,
              style: TextStyle(color: cs.error, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: () {
              setState(() => _error = null);
              _subscribeToEcgStream();
            },
            style: TextButton.styleFrom(foregroundColor: cs.primary),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildDisclaimer(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: cs.errorContainer.withOpacity(0.08),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline,
            size: 16,
            color: cs.onSurface.withOpacity(0.5),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'This ECG is for informational purposes only and is not a '
              'medical-grade reading. Consult a physician for clinical diagnosis.',
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurface.withOpacity(0.5),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Info Card
// ============================================================================

class _InfoCard extends StatelessWidget {
  final String label;
  final String value;
  final String sub;

  const _InfoCard({
    required this.label,
    required this.value,
    required this.sub,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outline.withOpacity(0.06)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: cs.onSurface.withOpacity(0.5),
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              value,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            Text(
              sub,
              style: TextStyle(
                fontSize: 10,
                color: cs.onSurface.withOpacity(0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
