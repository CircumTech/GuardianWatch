// ════════════════════════════════════════════════════════════════════════════
// lib/features/history/screens/history_screen.dart
// ════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../../../providers/dashboard_provider.dart';
import '../../../models/health_record.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _dateFormat = DateFormat('MMM d');
  DateTimeRange _dateRange = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 7)),
    end: DateTime.now(),
  );
  bool _isLoadingMore = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _loadHistory() {
    context.read<DashboardProvider>().loadHistory(
          from: _dateRange.start,
          to: _dateRange.end,
        );
  }

  void _onScroll() {
    final dp = context.read<DashboardProvider>();
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !dp.isLoading &&
        !_isLoadingMore &&
        dp.hasMore) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    setState(() => _isLoadingMore = true);
    await context.read<DashboardProvider>().loadMoreHistory(
          from: _dateRange.start,
          to: _dateRange.end,
        );
    if (mounted) setState(() => _isLoadingMore = false);
  }

  Future<void> _refresh() async {
    await context.read<DashboardProvider>().refreshHistory(
          from: _dateRange.start,
          to: _dateRange.end,
        );
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: _dateRange,
    );
    if (picked != null && picked != _dateRange) {
      setState(() => _dateRange = picked);
      _loadHistory();
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dp = context.watch<DashboardProvider>();
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today),
            onPressed: _pickDateRange,
            tooltip: 'Select date range',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _buildBody(dp, cs),
      ),
    );
  }

  Widget _buildBody(DashboardProvider dp, ColorScheme cs) {
    if (dp.isLoading && dp.history.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (dp.error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: cs.error),
            const SizedBox(height: 16),
            Text('Failed to load history', style: TextStyle(color: cs.error)),
            const SizedBox(height: 8),
            Text(dp.error!, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loadHistory,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (dp.history.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            const Text('No health records found'),
            const SizedBox(height: 8),
            Text(
              'No data available for ${_dateFormat.format(_dateRange.start)} – ${_dateFormat.format(_dateRange.end)}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ],
        ),
      );
    }

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      children: [
        // Date range indicator
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${_dateFormat.format(_dateRange.start)} – ${_dateFormat.format(_dateRange.end)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            TextButton.icon(
              onPressed: _pickDateRange,
              icon: const Icon(Icons.edit_calendar, size: 18),
              label: const Text('Change'),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Heart rate trend chart
        _HrChart(records: dp.history),
        const SizedBox(height: 20),

        // Summary cards
        _SummaryRow(
          avgHr: dp.avgHr,
          avgSpo2: dp.avgSpo2,
        ),
        const SizedBox(height: 20),

        // Records list title
        Text(
          'Daily Records',
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),

        // List of records
        ...dp.history.map((r) => _RecordTile(record: r)),

        // Loading more indicator
        if (_isLoadingMore)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (!dp.hasMore && dp.history.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text(
                'No more records',
                style: TextStyle(color: Colors.grey.shade500),
              ),
            ),
          ),
      ],
    );
  }
}

// ============================================================================
// Heart Rate Chart with Date Labels
// ============================================================================

class _HrChart extends StatelessWidget {
  final List<HealthRecord> records;
  const _HrChart({required this.records});

  @override
  Widget build(BuildContext context) {
    final sorted = List<HealthRecord>.from(records)
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));

    if (sorted.isEmpty) {
      return const SizedBox(
        height: 160,
        child: Center(child: Text('No data for chart')),
      );
    }

    final spots = List.generate(
      sorted.length,
      (i) => FlSpot(i.toDouble(), sorted[i].heartRate.toDouble()),
    );

    final labelInterval = (sorted.length / 5).ceil().toDouble();

    return SizedBox(
      height: 200,
      child: LineChart(
        LineChartData(
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: Colors.redAccent,
              barWidth: 2,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: Colors.redAccent.withOpacity(0.15),
              ),
            ),
          ],
          gridData: FlGridData(
            show: true,
            horizontalInterval: 20,
            drawVerticalLine: false,
          ),
          borderData: FlBorderData(
            show: true,
            border: const Border(
              bottom: BorderSide(),
              left: BorderSide(),
            ),
          ),
          titlesData: FlTitlesData(
            show: true,
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 20,
                reservedSize: 40,
                getTitlesWidget: (value, _) => Text('${value.toInt()}',
                    style: const TextStyle(fontSize: 10)),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: labelInterval,
                getTitlesWidget: (value, _) {
                  final index = value.toInt();
                  if (index < 0 || index >= sorted.length)
                    return const Text('');
                  final date = sorted[index].recordedAt;
                  return Transform.rotate(
                    angle: -0.5,
                    child: Text(
                      DateFormat('MM/dd').format(date),
                      style: const TextStyle(fontSize: 10),
                    ),
                  );
                },
              ),
            ),
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          minY: 40,
          maxY: 160,
        ),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      ),
    );
  }
}

// ============================================================================
// Summary Row
// ============================================================================

class _SummaryRow extends StatelessWidget {
  final double? avgHr, avgSpo2;
  const _SummaryRow({this.avgHr, this.avgSpo2});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _SumCard(
            label: 'Avg HR',
            value: avgHr?.toStringAsFixed(0) ?? '--',
            unit: 'bpm',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _SumCard(
            label: 'Avg SpO₂',
            value: avgSpo2?.toStringAsFixed(1) ?? '--',
            unit: '%',
          ),
        ),
      ],
    );
  }
}

class _SumCard extends StatelessWidget {
  final String label, value, unit;
  const _SumCard(
      {required this.label, required this.value, required this.unit});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            Text(
              '$value $unit',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Record Tile
// ============================================================================

class _RecordTile extends StatelessWidget {
  final HealthRecord record;
  const _RecordTile({required this.record});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('MMM d, yyyy – h:mm a');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.favorite, color: Colors.redAccent),
        title: Text('${record.heartRate} bpm  •  ${record.spo2}% SpO₂'),
        subtitle: Text(fmt.format(record.recordedAt)),
        trailing: Text('${record.temperature.toStringAsFixed(1)}°C'),
        isThreeLine: false,
      ),
    );
  }
}
