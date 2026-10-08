// ════════════════════════════════════════════════════════════════════════════
// lib/features/history/screens/history_screen.dart
// ════════════════════════════════════════════════════════════════════════════
//
// History browser.
//
// Backed by DashboardProvider, which handles cloud-first loading with a
// local fallback. This screen owns:
//   The date-range filter UI
//   Pagination trigger (scroll listener)
//   Per-record null-safe rendering
//
// All record fields are nullable. A record may carry only heart rate, only
// SpO₂, only temperature, or any combination. This screen must render
// gracefully for every combination.
//

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../models/health_record.dart';
import '../../../providers/dashboard_provider.dart';

// ════════════════════════════════════════════════════════════════════════════
// History screen
// ════════════════════════════════════════════════════════════════════════════

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
  final DateFormat _shortDateFormat = DateFormat('MMM d');
  final DateFormat _fullDateFormat = DateFormat('MMM d, yyyy');

  late DateTimeRange _dateRange;

  late final ScrollController _scrollController;
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  bool _isLoadingMore = false;

  /// Timestamp of the last pagination trigger.
  ///
  /// Used to throttle the scroll listener so it does not fire once per
  /// frame while the user is at the bottom of the list.
  DateTime? _lastLoadMoreAt;

  static const Duration _loadMoreThrottle = Duration(milliseconds: 600);

  @override
  void initState() {
    super.initState();

    final now = DateTime.now();
    _dateRange = DateTimeRange(
      start: DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(const Duration(days: 6)),
      end: DateTime(now.year, now.month, now.day),
    );

    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadHistory(animate: true);
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Date range helpers
  // ─────────────────────────────────────────────────────────────────────────

  DateTime _startOfDay(DateTime date) {
    final local = date.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  DateTime _endOfDay(DateTime date) {
    final start = _startOfDay(date);
    return start.add(const Duration(days: 1, microseconds: -1));
  }

  String _formatRange() {
    final start = _startOfDay(_dateRange.start);
    final end = _startOfDay(_dateRange.end);

    final sameDay =
        start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;

    if (sameDay) {
      return _fullDateFormat.format(start);
    }

    return '${_shortDateFormat.format(start)} - '
        '${_shortDateFormat.format(end)}';
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Loading
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _loadHistory({bool animate = false}) async {
    if (!mounted) return;

    if (animate) {
      _fadeController
        ..reset()
        ..forward();
    }

    final provider = context.read<DashboardProvider>();

    await provider.refreshHistory(
      from: _startOfDay(_dateRange.start),
      to: _endOfDay(_dateRange.end),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Pagination
  // ─────────────────────────────────────────────────────────────────────────

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    final triggerPosition = position.maxScrollExtent - 300;

    if (position.pixels < triggerPosition) return;

    // Throttle — do not fire more than once per _loadMoreThrottle window.
    final now = DateTime.now();
    if (_lastLoadMoreAt != null &&
        now.difference(_lastLoadMoreAt!) < _loadMoreThrottle) {
      return;
    }
    _lastLoadMoreAt = now;

    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !mounted) return;

    final provider = context.read<DashboardProvider>();

    // Provider already guards against concurrent loads and end-of-list.
    if (!provider.hasMore || provider.isLoading) return;

    setState(() => _isLoadingMore = true);

    try {
      await provider.loadMoreHistory(
        from: _startOfDay(_dateRange.start),
        to: _endOfDay(_dateRange.end),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
    }
  }

  Future<void> _refresh() async {
    await _loadHistory(animate: true);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Date picker
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final firstDate = DateTime(2020);

    final picked = await showDateRangePicker(
      context: context,
      firstDate: firstDate,
      lastDate: _startOfDay(now),
      initialDateRange: DateTimeRange(
        start: _startOfDay(_dateRange.start),
        end: _startOfDay(_dateRange.end),
      ),
      saveText: 'Apply',
      builder: (context, child) {
        final theme = Theme.of(context);
        return Theme(
          data: theme.copyWith(
            datePickerTheme: DatePickerThemeData(
              rangeSelectionBackgroundColor: theme.colorScheme.primary
                  .withValues(alpha: 0.15),
              rangeSelectionOverlayColor: WidgetStatePropertyAll(
                theme.colorScheme.primary.withValues(alpha: 0.08),
              ),
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked == null || !mounted) return;

    final newStart = _startOfDay(picked.start);
    final newEnd = _startOfDay(picked.end);

    final changed =
        newStart != _startOfDay(_dateRange.start) ||
        newEnd != _startOfDay(_dateRange.end);

    if (!changed) return;

    setState(() {
      _dateRange = DateTimeRange(start: newStart, end: newEnd);
      _isLoadingMore = false;
      _lastLoadMoreAt = null;
    });

    await _loadHistory(animate: true);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DashboardProvider>();
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        elevation: 0,
        backgroundColor: colorScheme.surface,
        surfaceTintColor: colorScheme.surface,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              onPressed: provider.isLoading ? null : _pickDateRange,
              icon: const Icon(Icons.calendar_today_outlined, size: 18),
              label: Text(
                _formatRange(),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.onSurface,
                ),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        color: colorScheme.primary,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: _buildBody(provider, colorScheme),
        ),
      ),
    );
  }

  Widget _buildBody(DashboardProvider provider, ColorScheme colorScheme) {
    // ── Initial loading ────────────────────────────────────────────────────
    if (provider.isLoading && provider.history.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(
            height: 260,
            child: Center(child: CircularProgressIndicator()),
          ),
        ],
      );
    }

    // ── Error with no fallback data ────────────────────────────────────────
    if (provider.history.isEmpty && provider.error != null) {
      return _ErrorState(message: provider.error!, onRetry: _loadHistory);
    }

    // ── Empty ──────────────────────────────────────────────────────────────
    if (provider.history.isEmpty) {
      return _EmptyHistoryState(
        dateRange: _dateRange,
        onChangeRange: _pickDateRange,
      );
    }

    // ── Content ────────────────────────────────────────────────────────────
    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        if (provider.isOffline)
          const _OfflineBanner(
            message:
                'Showing locally cached data. Cloud synchronization '
                'may be unavailable.',
          ),

        if (provider.isOffline) const SizedBox(height: 12),

        _SummarySection(provider: provider),

        const SizedBox(height: 20),

        _HrChart(records: provider.history),

        const SizedBox(height: 20),

        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              'Health Records',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            Text(
              '${provider.history.length} entries',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurface.withValues(alpha: 0.50),
              ),
            ),
          ],
        ),

        const SizedBox(height: 10),

        ...provider.history.map((record) => _RecordTile(record: record)),

        if (_isLoadingMore)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: CircularProgressIndicator()),
          ),

        if (!provider.hasMore && !_isLoadingMore)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Center(
              child: Text(
                'You have reached the end of this period.',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurface.withValues(alpha: 0.40),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Summary section
// ════════════════════════════════════════════════════════════════════════════

class _SummarySection extends StatelessWidget {
  final DashboardProvider provider;

  const _SummarySection({required this.provider});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.55,
      children: [
        _SummaryCard(
          label: 'Average HR',
          value: provider.avgHr?.toStringAsFixed(0) ?? '--',
          unit: 'bpm',
          icon: Icons.favorite_outline,
          iconColor: const Color(0xFFE57373),
        ),
        _SummaryCard(
          label: 'Average SpO₂',
          value: provider.avgSpo2?.toStringAsFixed(1) ?? '--',
          unit: '%',
          icon: Icons.air_outlined,
          iconColor: const Color(0xFF64B5F6),
        ),
        _SummaryCard(
          label: 'Average Temp.',
          value: provider.avgTemp?.toStringAsFixed(1) ?? '--',
          unit: '°C',
          icon: Icons.thermostat_outlined,
          iconColor: const Color(0xFFFFB74D),
        ),
        _SummaryCard(
          label: 'Records',
          value: provider.history.length.toString(),
          unit: 'entries',
          icon: Icons.assessment_outlined,
          iconColor: colorScheme.primary,
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Summary card
// ════════════════════════════════════════════════════════════════════════════

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final IconData icon;
  final Color iconColor;

  const _SummaryCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: iconColor.withValues(alpha: 0.12),
              ),
              child: Icon(icon, color: iconColor, size: 21),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: colorScheme.onSurface.withValues(alpha: 0.58),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Flexible(
                        child: Text(
                          value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          unit,
                          style: TextStyle(
                            fontSize: 10,
                            color: colorScheme.onSurface.withValues(
                              alpha: 0.45,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Heart-rate chart
// ════════════════════════════════════════════════════════════════════════════

class _HrChart extends StatelessWidget {
  final List<HealthRecord> records;

  const _HrChart({required this.records});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Only records with a non-null HR participate in the chart.
    // Records with a null HR are legitimately possible — a SpO₂-only
    // reading, a temperature-only reading, or a partially synced record.
    final withHr = records.where((r) => r.heartRate != null).toList()
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));

    // Fewer than 2 points cannot form a trend line.
    if (withHr.length < 2) {
      return _ChartPlaceholder(
        icon: Icons.show_chart,
        title: 'Heart Rate Trend',
        message: withHr.isEmpty
            ? 'No heart-rate readings in this period.'
            : 'Not enough heart-rate readings to plot a trend.',
        colorScheme: colorScheme,
      );
    }

    // Bound chart cost with a downsample.
    final chartRecords = _downsampleRecords(withHr, 250);
    if (chartRecords.isEmpty) {
      return const SizedBox.shrink();
    }

    final spots = <FlSpot>[];
    final hrValues = <double>[];
    for (var i = 0; i < chartRecords.length; i++) {
      final hr = chartRecords[i].heartRate;
      if (hr == null) continue;
      final value = hr.toDouble();
      spots.add(FlSpot(i.toDouble(), value));
      hrValues.add(value);
    }

    if (spots.length < 2 || hrValues.isEmpty) {
      return _ChartPlaceholder(
        icon: Icons.show_chart,
        title: 'Heart Rate Trend',
        message: 'Not enough heart-rate readings to plot a trend.',
        colorScheme: colorScheme,
      );
    }

    var minY = hrValues.reduce(math.min);
    var maxY = hrValues.reduce(math.max);

    if (minY == maxY) {
      minY -= 10;
      maxY += 10;
    }

    final range = maxY - minY;
    final verticalPadding = math.max(range * 0.15, 5);
    minY -= verticalPadding;
    maxY += verticalPadding;

    final interval = _calculateYInterval(minY, maxY);
    final labelInterval = math
        .max((chartRecords.length / 5).ceil(), 1)
        .toDouble();

    final dateFormat = DateFormat.Md(); // locale-aware month/day

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Heart Rate Trend',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                Text(
                  '${chartRecords.length} plotted',
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurface.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 210,
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: math.max(0, spots.length - 1).toDouble(),
                  minY: minY,
                  maxY: maxY,
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      curveSmoothness: 0.15,
                      color: const Color(0xFFE57373),
                      barWidth: 2.2,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: const Color(0xFFE57373).withValues(alpha: 0.08),
                      ),
                    ),
                  ],
                  gridData: FlGridData(
                    show: true,
                    drawHorizontalLine: true,
                    drawVerticalLine: false,
                    horizontalInterval: interval,
                    getDrawingHorizontalLine: (value) => FlLine(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.25),
                      strokeWidth: 0.6,
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: interval,
                        reservedSize: 38,
                        getTitlesWidget: (value, meta) => Text(
                          value.toStringAsFixed(0),
                          style: TextStyle(
                            fontSize: 10,
                            color: colorScheme.onSurface.withValues(
                              alpha: 0.45,
                            ),
                          ),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: labelInterval,
                        reservedSize: 28,
                        getTitlesWidget: (value, meta) {
                          final index = value.round();
                          if (index < 0 || index >= chartRecords.length) {
                            return const SizedBox.shrink();
                          }
                          final date = chartRecords[index].recordedAt.toLocal();
                          return Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: Text(
                              dateFormat.format(date),
                              style: TextStyle(
                                fontSize: 9,
                                color: colorScheme.onSurface.withValues(
                                  alpha: 0.40,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
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
                duration: const Duration(milliseconds: 250),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static List<HealthRecord> _downsampleRecords(
    List<HealthRecord> input,
    int maxPoints,
  ) {
    if (input.length <= maxPoints) return input;

    final result = <HealthRecord>[];
    final step = input.length / maxPoints;

    for (var i = 0; i < maxPoints; i++) {
      final index = (i * step).floor();
      result.add(input[index.clamp(0, input.length - 1)]);
    }

    return result;
  }

  static double _calculateYInterval(double minY, double maxY) {
    final range = maxY - minY;
    if (range <= 40) return 10;
    if (range <= 80) return 20;
    return 25;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Chart placeholder
// ════════════════════════════════════════════════════════════════════════════

class _ChartPlaceholder extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final ColorScheme colorScheme;

  const _ChartPlaceholder({
    required this.icon,
    required this.title,
    required this.message,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 40),
            Center(
              child: Column(
                children: [
                  Icon(
                    icon,
                    size: 34,
                    color: colorScheme.onSurface.withValues(alpha: 0.30),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Record tile
//
// Every metric on a HealthRecord is nullable. This tile renders whatever
// is present and omits what is not — no null-assertion, no literal "null".
// ════════════════════════════════════════════════════════════════════════════

class _RecordTile extends StatelessWidget {
  final HealthRecord record;

  const _RecordTile({required this.record});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final recordedLocal = record.recordedAt.toLocal();
    final day = DateFormat('EEE, MMM d').format(recordedLocal);
    final time = DateFormat('h:mm a').format(recordedLocal);

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header row: icon + date/time + battery ─────────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFE57373).withValues(alpha: 0.10),
                  ),
                  child: const Icon(
                    Icons.monitor_heart_outlined,
                    color: Color(0xFFE57373),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$day • $time',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurface.withValues(alpha: 0.52),
                        ),
                      ),
                    ],
                  ),
                ),
                if (record.battery != null) ...[
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _batteryIcon(record.battery!),
                        size: 14,
                        color: colorScheme.onSurface.withValues(alpha: 0.45),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '${record.battery}%',
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),

            // ── Metric chips row ───────────────────────────────────────
            if (record.heartRate != null ||
                record.spo2 != null ||
                record.temperature != null) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(left: 44),
                child: Wrap(
                  spacing: 14,
                  runSpacing: 8,
                  children: [
                    if (record.heartRate != null)
                      _MetricPill(
                        icon: Icons.favorite_outline,
                        color: const Color(0xFFE57373),
                        text: '${record.heartRate} bpm',
                        emphasize: true,
                      ),
                    if (record.spo2 != null)
                      _MetricPill(
                        icon: Icons.air_outlined,
                        color: const Color(0xFF64B5F6),
                        text: '${record.spo2}% SpO₂',
                        emphasize: false,
                      ),
                    if (record.temperature != null)
                      _MetricPill(
                        icon: Icons.thermostat_outlined,
                        color: const Color(0xFFFFB74D),
                        text: '${record.temperature!.toStringAsFixed(1)} °C',
                        emphasize: false,
                      ),
                  ],
                ),
              ),
            ] else ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 44),
                child: Text(
                  'No metrics recorded in this entry.',
                  style: TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: colorScheme.onSurface.withValues(alpha: 0.40),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _batteryIcon(int battery) {
    if (battery <= 10) return Icons.battery_alert_outlined;
    if (battery <= 30) return Icons.battery_2_bar_outlined;
    if (battery <= 60) return Icons.battery_4_bar_outlined;
    return Icons.battery_full_outlined;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Metric pill
// ════════════════════════════════════════════════════════════════════════════

class _MetricPill extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  final bool emphasize;

  const _MetricPill({
    required this.icon,
    required this.color,
    required this.text,
    required this.emphasize,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            fontSize: emphasize ? 14 : 13,
            fontWeight: emphasize ? FontWeight.w600 : FontWeight.w500,
            color: colorScheme.onSurface.withValues(
              alpha: emphasize ? 1.0 : 0.75,
            ),
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Offline banner
// ════════════════════════════════════════════════════════════════════════════

class _OfflineBanner extends StatelessWidget {
  final String message;

  const _OfflineBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: colorScheme.secondaryContainer.withValues(alpha: 0.45),
      ),
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 18,
            color: colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Error state
// ════════════════════════════════════════════════════════════════════════════

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.45,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.cloud_off_outlined,
                    size: 56,
                    color: colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Unable to load history',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurface.withValues(alpha: 0.60),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: onRetry, child: const Text('Retry')),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Empty state
// ════════════════════════════════════════════════════════════════════════════

class _EmptyHistoryState extends StatelessWidget {
  final DateTimeRange dateRange;
  final VoidCallback onChangeRange;

  const _EmptyHistoryState({
    required this.dateRange,
    required this.onChangeRange,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.50,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colorScheme.primaryContainer.withValues(
                        alpha: 0.45,
                      ),
                    ),
                    child: Icon(
                      Icons.history_outlined,
                      size: 40,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'No health records found',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'There is no Guardian Watch data for the selected period.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: colorScheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                  const SizedBox(height: 20),
                  OutlinedButton.icon(
                    onPressed: onChangeRange,
                    icon: const Icon(Icons.calendar_month_outlined),
                    label: const Text('Change Date Range'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
