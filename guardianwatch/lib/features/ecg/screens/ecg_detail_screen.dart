// ════════════════════════════════════════════════════════════════════════════
// lib/features/ecg/screens/ecg_detail_screen.dart
// ════════════════════════════════════════════════════════════════════════════
//
// Live ECG monitor.
//
// SESSION LIFECYCLE
// -----------------
// Tapping "Record" tells BleProvider to start a monitoring session. The
// session ID it generates is attached to every HealthRecord written while
// the session is active. Tapping "Stop" ends it.
//
// The buffer shown here is a display buffer only. Persisting the raw ECG
// waveform to disk is out of scope for this screen and will be handled by
// the ECG storage layer.
//
// RHYTHM ANALYSIS
// ---------------
// When the buffer holds enough samples, the user can request a rhythm
// irregularity screening. This calls InsightProvider.analyzeEcgRhythm(),
// which invokes the validated TFLite model when available and otherwise
// falls back to the RR-irregularity heuristic.
//

import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/ble_provider.dart';
import '../../../providers/insight_provider.dart';

// ════════════════════════════════════════════════════════════════════════════
// ECG Detail Screen
// ════════════════════════════════════════════════════════════════════════════

class EcgDetailScreen extends StatefulWidget {
  const EcgDetailScreen({super.key});

  @override
  State<EcgDetailScreen> createState() => _EcgDetailScreenState();
}

class _EcgDetailScreenState extends State<EcgDetailScreen>
    with TickerProviderStateMixin {
  /// Display buffer size — 6 seconds at 250 Hz.
  ///
  /// Not the permanent ECG recording store.
  static const int _maxDisplaySamples = 1500;

  /// Minimum samples required before rhythm analysis is offered.
  /// 4 seconds at 250 Hz — matches the insight service's minimum.
  static const int _minSamplesForAnalysis = 1000;

  final List<double> _buffer = [];

  StreamSubscription<List<double>>? _ecgSubscription;

  Timer? _uiUpdateTimer;

  late final AnimationController _chartController;
  late final Animation<double> _chartFade;

  bool _isPaused = false;
  bool _isSubscribed = false;
  bool _isAnalyzing = false;
  bool _isRecordingSession = false;

  String? _error;

  int _samplesReceivedSinceRateUpdate = 0;

  DateTime? _rateWindowStart;
  double _observedSampleRate = 0;
  DateTime? _lastPacketTime;
  DateTime? _lastUiUpdate;

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

    // Defer until after the first frame so context is fully wired.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _subscribeToEcgStream();
    });
  }

  // ─────────────────────────────────────────────────────────────
  // ECG stream
  // ─────────────────────────────────────────────────────────────

  Future<void> _subscribeToEcgStream() async {
    // Capture the provider BEFORE any await, so a disposed widget
    // during the cancel() call cannot lead to a context.read after
    // disposal.
    if (!mounted) return;
    final ble = context.read<BleProvider>();

    await _ecgSubscription?.cancel();
    _ecgSubscription = null;

    if (!mounted) return;

    _rateWindowStart = DateTime.now();
    _samplesReceivedSinceRateUpdate = 0;
    _lastPacketTime = null;

    final subscription = ble.ecgStream.listen(
      _handleEcgPacket,
      onError: (Object error, StackTrace stack) {
        debugPrint('Guardian ECG stream error: $error');
        debugPrintStack(stackTrace: stack);

        if (!mounted) return;

        setState(() {
          _error = _humanizeEcgError(error);
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _isSubscribed = false;
        });
      },
      cancelOnError: false,
    );

    _ecgSubscription = subscription;

    // Only flag subscribed once the listener is attached.
    if (!mounted) {
      await subscription.cancel();
      return;
    }

    setState(() {
      _isSubscribed = true;
      _error = null;
    });
  }

  void _handleEcgPacket(List<double> samples) {
    if (!_isSubscribed || samples.isEmpty) return;

    // Keep receiving while paused; pause only freezes the display buffer.
    if (!_isPaused) {
      _buffer.addAll(samples);

      if (_buffer.length > _maxDisplaySamples) {
        final removeCount = _buffer.length - _maxDisplaySamples;
        _buffer.removeRange(0, removeCount);
      }
    }

    _updateObservedSampleRate(samples.length);

    _lastPacketTime = DateTime.now();

    if (_isPaused) return;

    // Cap chart rebuilds at ~30 fps.
    final now = DateTime.now();
    if (_lastUiUpdate != null &&
        now.difference(_lastUiUpdate!) < const Duration(milliseconds: 33)) {
      return;
    }
    _lastUiUpdate = now;

    if (!mounted) return;
    setState(() {});
  }

  void _updateObservedSampleRate(int sampleCount) {
    final now = DateTime.now();
    _rateWindowStart ??= now;
    _samplesReceivedSinceRateUpdate += sampleCount;

    final elapsed = now.difference(_rateWindowStart!);
    if (elapsed.inMilliseconds < 1000) return;

    final seconds = elapsed.inMilliseconds / 1000.0;
    _observedSampleRate = _samplesReceivedSinceRateUpdate / seconds;
    _samplesReceivedSinceRateUpdate = 0;
    _rateWindowStart = now;
  }

  String _humanizeEcgError(Object error) {
    final text = error.toString();

    if (text.contains('Bluetooth') ||
        text.contains('bluetooth') ||
        text.contains('BLE')) {
      return 'The Bluetooth ECG stream encountered a problem.';
    }

    if (text.contains('SocketException') ||
        text.contains('Failed host lookup')) {
      return 'Network error while processing the ECG stream.';
    }

    // Never leak raw Dart error strings to the UI.
    return 'The ECG stream encountered an unexpected error.';
  }

  // ─────────────────────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────────────────────

  @override
  void dispose() {
    // If a recording session is still active when the screen closes,
    // end it so the session has a closed ended_at timestamp.
    if (_isRecordingSession) {
      // Fire and forget — the provider handles its own state.
      unawaited(_stopRecording(silent: true));
    }

    _ecgSubscription?.cancel();
    _uiUpdateTimer?.cancel();
    _chartController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────
  // Recording lifecycle
  // ─────────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    if (_isRecordingSession) return;

    final ble = context.read<BleProvider>();

    if (!ble.isConnected) {
      _showSnack('Connect to your Guardian Watch first.');
      return;
    }

    try {
      await ble.startMonitoringSession();
      if (!mounted) return;

      setState(() {
        _isRecordingSession = ble.currentSessionId != null;
      });
    } catch (e, stack) {
      debugPrint('Guardian ECG session start failed: $e');
      debugPrintStack(stackTrace: stack);
      if (!mounted) return;
      _showSnack('Unable to start the ECG session.');
    }
  }

  Future<void> _stopRecording({bool silent = false}) async {
    if (!_isRecordingSession && !silent) return;

    final ble = context.read<BleProvider>();

    try {
      ble.endMonitoringSession();
    } catch (e, stack) {
      debugPrint('Guardian ECG session end failed: $e');
      debugPrintStack(stackTrace: stack);
    }

    if (!mounted) return;

    if (!silent) {
      setState(() {
        _isRecordingSession = false;
      });
      _showSnack('ECG session ended.');
    } else {
      _isRecordingSession = false;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Rhythm analysis
  // ─────────────────────────────────────────────────────────────

  Future<void> _analyzeRhythm() async {
    if (_isAnalyzing) return;

    if (_buffer.length < _minSamplesForAnalysis) {
      _showSnack(
        'Collect at least 4 seconds of clean ECG before running '
        'rhythm screening.',
      );
      return;
    }

    setState(() => _isAnalyzing = true);

    try {
      final insight = context.read<InsightProvider>();

      // Snapshot the buffer so the analysis runs on a stable input.
      final segment = List<double>.from(_buffer);

      await insight.analyzeEcgRhythm(segment);

      if (!mounted) return;

      final rhythm = insight.currentRhythmIrregularity;

      if (rhythm == null) {
        _showSnack('Rhythm screening did not produce a result.');
      } else if (rhythm.isSuspected) {
        _showSnack(
          'Irregular pattern flagged in this ECG segment. '
          'See Insights for details.',
        );
      } else {
        _showSnack('No irregular pattern was flagged in this segment.');
      }
    } catch (e, stack) {
      debugPrint('Guardian rhythm screening failed: $e');
      debugPrintStack(stackTrace: stack);
      if (mounted) _showSnack('Rhythm screening could not be completed.');
    } finally {
      if (mounted) {
        setState(() => _isAnalyzing = false);
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Controls
  // ─────────────────────────────────────────────────────────────

  void _clearBuffer() {
    setState(() {
      _buffer.clear();
      _samplesReceivedSinceRateUpdate = 0;
      _rateWindowStart = DateTime.now();
      _observedSampleRate = 0;
      _lastPacketTime = null;
      _lastUiUpdate = null;
      _error = null;
    });

    _chartController
      ..reset()
      ..forward();
  }

  void _togglePause() {
    setState(() => _isPaused = !_isPaused);

    if (!_isPaused) {
      _chartController
        ..reset()
        ..forward();
    }
  }

  Future<void> _retryStream() async {
    setState(() => _error = null);

    try {
      await _subscribeToEcgStream();
    } catch (e, stack) {
      debugPrint('Guardian ECG stream retry failed: $e');
      debugPrintStack(stackTrace: stack);
      if (!mounted) return;
      setState(() {
        _error = _humanizeEcgError(e);
      });
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
  }

  // ─────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hr = context.select<BleProvider, int?>(
      (provider) => provider.heartRate,
    );
    final connected = context.select<BleProvider, bool>(
      (provider) => provider.isConnected,
    );
    final colorScheme = Theme.of(context).colorScheme;

    final canAnalyze =
        _buffer.length >= _minSamplesForAnalysis && !_isAnalyzing;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ECG Monitor'),
        elevation: 0,
        backgroundColor: colorScheme.surface,
        surfaceTintColor: colorScheme.surface,
        actions: [
          IconButton(
            tooltip: _isPaused ? 'Resume display' : 'Pause display',
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Icon(
                _isPaused ? Icons.play_arrow : Icons.pause,
                key: ValueKey(_isPaused),
              ),
            ),
            onPressed: _togglePause,
          ),
          IconButton(
            tooltip: 'Clear display',
            icon: const Icon(Icons.clear_all),
            onPressed: _clearBuffer,
          ),
          const SizedBox(width: 4),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.30),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.favorite,
                    size: 16,
                    // Red only when a live HR is present. Otherwise muted.
                    color: (connected && hr != null)
                        ? colorScheme.error
                        : colorScheme.onSurface.withValues(alpha: 0.40),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    (connected && hr != null) ? '$hr bpm' : '-- bpm',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: (connected && hr != null)
                          ? colorScheme.onSurface
                          : colorScheme.onSurface.withValues(alpha: 0.40),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildConnectionBanner(connected, colorScheme),

            const SizedBox(height: 12),

            _buildStatusRow(hr, connected, colorScheme),

            const SizedBox(height: 16),

            Expanded(flex: 2, child: _buildChartPanel(colorScheme)),

            const SizedBox(height: 16),

            _buildActionRow(connected, canAnalyze, colorScheme),

            const SizedBox(height: 16),

            _buildInfoCards(colorScheme),

            const SizedBox(height: 16),

            if (_error != null) ...[
              _buildErrorDisplay(colorScheme),
              const SizedBox(height: 12),
            ],

            _buildDisclaimer(colorScheme),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Connection banner
  // ─────────────────────────────────────────────────────────────

  Widget _buildConnectionBanner(bool connected, ColorScheme cs) {
    final color = connected ? cs.primary : cs.error;
    final icon = connected
        ? Icons.bluetooth_connected
        : Icons.bluetooth_disabled;

    final title = connected
        ? 'Guardian Watch connected'
        : 'Guardian Watch disconnected';

    final subtitle = connected
        ? (_isRecordingSession
              ? 'Recording ECG session.'
              : 'Receiving ECG telemetry.')
        : 'Reconnect the watch to receive live ECG data.';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
          if (_isRecordingSession)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: cs.errorContainer.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: cs.error,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    'REC',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: cs.error,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            )
          else if (connected && _isSubscribed)
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: cs.primary,
              ),
            ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Status
  // ─────────────────────────────────────────────────────────────

  Widget _buildStatusRow(int? hr, bool connected, ColorScheme cs) {
    final status = _getStatusData(hr, connected);

    final label = status.$1;
    final color = status.$2;
    final icon = status.$3;

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: color.withValues(alpha: 0.12),
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
        if (_observedSampleRate > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: cs.primaryContainer.withValues(alpha: 0.30),
            ),
            child: Text(
              '${_observedSampleRate.toStringAsFixed(0)} samples/s',
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.70),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
      ],
    );
  }

  (String, Color, IconData) _getStatusData(int? hr, bool connected) {
    if (!connected) {
      return ('Watch disconnected', Colors.grey, Icons.bluetooth_disabled);
    }

    if (!_isSubscribed) {
      return (
        'ECG stream unavailable',
        Colors.orange,
        Icons.warning_amber_rounded,
      );
    }

    if (hr == null) {
      return ('Monitoring', Colors.blueGrey, Icons.monitor_heart_outlined);
    }

    return ('Monitoring', Colors.green, Icons.monitor_heart_outlined);
  }

  // ─────────────────────────────────────────────────────────────
  // Chart panel
  // ─────────────────────────────────────────────────────────────

  Widget _buildChartPanel(ColorScheme cs) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.55)),
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
                      color: Colors.orange.withValues(alpha: 0.15),
                    ),
                    child: Text(
                      'DISPLAY PAUSED',
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
              'Signal amplitude  •  ${_buffer.length} display samples',
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurface.withValues(alpha: 0.40),
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Chart
  // ─────────────────────────────────────────────────────────────

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
                color: cs.onSurface.withValues(alpha: 0.5),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Ensure your Guardian Watch is connected and the ECG '
              'electrodes have skin contact.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.35),
              ),
            ),
          ],
        ),
      );
    }

    const targetPoints = 600;
    final display = _downsample(_buffer, targetPoints);
    if (display.isEmpty) return const SizedBox.shrink();

    final spots = List<FlSpot>.generate(
      display.length,
      (index) => FlSpot(index.toDouble(), display[index]),
    );

    var minY = display.reduce(math.min);
    var maxY = display.reduce(math.max);

    if (!minY.isFinite || !maxY.isFinite) {
      return Center(
        child: Text('Invalid ECG signal', style: TextStyle(color: cs.error)),
      );
    }

    if (minY == maxY) {
      minY -= 1;
      maxY += 1;
    }

    final range = maxY - minY;

    // Dynamic vertical scaling for prototype/future firmware ranges.
    // This does not claim a clinically calibrated ECG axis.
    final padding = math.max(range * 0.12, 0.001);
    final axisMin = minY - padding;
    final axisMax = maxY + padding;
    final horizontalInterval = math.max(range / 4, 0.000001);

    return RepaintBoundary(
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: math.max(0, spots.length - 1).toDouble(),
          minY: axisMin,
          maxY: axisMax,
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: false,
              color: cs.primary,
              barWidth: 1.6,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: cs.primary.withValues(alpha: 0.04),
              ),
            ),
          ],
          gridData: FlGridData(
            show: true,
            drawHorizontalLine: true,
            drawVerticalLine: true,
            horizontalInterval: horizontalInterval,
            verticalInterval: math.max(spots.length / 6, 1),
            getDrawingHorizontalLine: (value) => FlLine(
              color: cs.outlineVariant.withValues(alpha: 0.30),
              strokeWidth: 0.6,
            ),
            getDrawingVerticalLine: (value) => FlLine(
              color: cs.outlineVariant.withValues(alpha: 0.20),
              strokeWidth: 0.5,
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: horizontalInterval,
                reservedSize: 40,
                getTitlesWidget: (value, meta) => Text(
                  _formatAxisValue(value),
                  style: TextStyle(
                    fontSize: 9,
                    color: cs.onSurface.withValues(alpha: 0.40),
                  ),
                ),
              ),
            ),
            bottomTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
          ),
          clipData: const FlClipData.all(),
        ),
        duration: Duration.zero,
      ),
    );
  }

  String _formatAxisValue(double value) {
    if (value.abs() >= 100) return value.toStringAsFixed(0);
    if (value.abs() >= 10) return value.toStringAsFixed(1);
    return value.toStringAsFixed(2);
  }

  // ─────────────────────────────────────────────────────────────
  // Downsampling
  // ─────────────────────────────────────────────────────────────

  static List<double> _downsample(List<double> input, int target) {
    if (input.isEmpty) return const [];
    if (input.length <= target) return List<double>.from(input);

    // Simple decimation for the live display. Original high-resolution
    // samples are not stored by this screen.
    final result = <double>[];
    final step = input.length / target;

    for (var i = 0; i < target; i++) {
      final index = (i * step).floor();
      result.add(input[index.clamp(0, input.length - 1)]);
    }

    return result;
  }

  // ─────────────────────────────────────────────────────────────
  // Action row (record + analyze)
  // ─────────────────────────────────────────────────────────────

  Widget _buildActionRow(bool connected, bool canAnalyze, ColorScheme cs) {
    return Row(
      children: [
        Expanded(
          child: _isRecordingSession
              ? OutlinedButton.icon(
                  onPressed: () => _stopRecording(),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Stop Recording'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: cs.error,
                    side: BorderSide(color: cs.error),
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                )
              : FilledButton.icon(
                  onPressed: connected ? _startRecording : null,
                  icon: const Icon(Icons.fiber_manual_record),
                  label: const Text('Record Session'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: canAnalyze ? _analyzeRhythm : null,
            icon: _isAnalyzing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome_outlined),
            label: Text(_isAnalyzing ? 'Analyzing...' : 'Screen Rhythm'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Info cards
  // ─────────────────────────────────────────────────────────────

  Widget _buildInfoCards(ColorScheme cs) {
    final peak = _buffer.isEmpty
        ? '--'
        : _formatCompact(_buffer.reduce(math.max));
    final trough = _buffer.isEmpty
        ? '--'
        : _formatCompact(_buffer.reduce(math.min));

    return Row(
      children: [
        Expanded(
          child: _InfoCard(
            label: 'Buffer',
            value: '${_buffer.length}',
            sub: 'display samples',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _InfoCard(label: 'Peak', value: peak, sub: 'signal units'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _InfoCard(label: 'Trough', value: trough, sub: 'signal units'),
        ),
      ],
    );
  }

  /// Compact number formatting for the info cards.
  ///
  /// Keeps the value short so long decimals do not overflow small cards.
  static String _formatCompact(double value) {
    if (!value.isFinite) return '--';
    final abs = value.abs();
    if (abs >= 100) return value.toStringAsFixed(0);
    if (abs >= 10) return value.toStringAsFixed(1);
    if (abs >= 1) return value.toStringAsFixed(2);
    return value.toStringAsFixed(3);
  }

  // ─────────────────────────────────────────────────────────────
  // Error
  // ─────────────────────────────────────────────────────────────

  Widget _buildErrorDisplay(ColorScheme cs) {
    final message = _error;
    if (message == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: cs.errorContainer.withValues(alpha: 0.20),
        border: Border.all(color: cs.error.withValues(alpha: 0.20)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: cs.error, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: cs.error, fontSize: 13, height: 1.35),
            ),
          ),
          TextButton(
            onPressed: _retryStream,
            style: TextButton.styleFrom(foregroundColor: cs.primary),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Disclaimer
  // ─────────────────────────────────────────────────────────────

  Widget _buildDisclaimer(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 16,
            color: cs.onSurface.withValues(alpha: 0.50),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'ECG shown here is for monitoring and informational use. '
              'It is not a diagnosis and does not replace clinical ECG '
              'testing.',
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurface.withValues(alpha: 0.50),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Info Card
// ════════════════════════════════════════════════════════════════════════════

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
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.45)),
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
                color: cs.onSurface.withValues(alpha: 0.50),
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                color: cs.onSurface.withValues(alpha: 0.40),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
