// ════════════════════════════════════════════════════════════════════════════
// lib/providers/history_provider.dart
// ════════════════════════════════════════════════════════════════════════════
//
// HistoryProvider — paginated history browser with date/metric filters.
//
// Responsibilities:
//   Load paginated health-record history (cloud-first, local fallback)
//   Support filtering by date range and metric type
//   Cache cloud records locally for offline access
//   Compute summary statistics for the loaded range
//   Delete individual records locally and enqueue deletion for sync
//   React to connectivity changes
//
// Design rules:
//   Uses ApiService.shared.
//   Local queries are always scoped to the current authenticated user.
//   Cloud-fetched records are cached WITHOUT re-enqueueing for sync.
//   In-flight loads are cancellable when the filter changes.
//   All notifyListeners() paths are guarded by _disposed.
//

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/health_record.dart';
import '../services/api_service.dart';
import '../services/connectivity_service.dart';
import '../services/local_db_service.dart';

// ════════════════════════════════════════════════════════════════════════════
// Filter
// ════════════════════════════════════════════════════════════════════════════

/// Metric selector for history filtering.
enum HistoryMetric { all, heartRate, spo2, temperature }

/// Immutable filter description.
///
/// Equality is by value so the provider can detect a "same filter" call and
/// skip a redundant reload.
@immutable
class HistoryFilter {
  final DateTime? from;
  final DateTime? to;
  final HistoryMetric metric;
  final bool onlyUnsynced;

  const HistoryFilter({
    this.from,
    this.to,
    this.metric = HistoryMetric.all,
    this.onlyUnsynced = false,
  });

  HistoryFilter copyWith({
    DateTime? from,
    DateTime? to,
    HistoryMetric? metric,
    bool? onlyUnsynced,
    bool clearFrom = false,
    bool clearTo = false,
  }) {
    return HistoryFilter(
      from: clearFrom ? null : from ?? this.from,
      to: clearTo ? null : to ?? this.to,
      metric: metric ?? this.metric,
      onlyUnsynced: onlyUnsynced ?? this.onlyUnsynced,
    );
  }

  bool get isEmpty =>
      from == null &&
      to == null &&
      metric == HistoryMetric.all &&
      !onlyUnsynced;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HistoryFilter &&
          other.from == from &&
          other.to == to &&
          other.metric == metric &&
          other.onlyUnsynced == onlyUnsynced;

  @override
  int get hashCode => Object.hash(from, to, metric, onlyUnsynced);

  @override
  String toString() =>
      'HistoryFilter(from: $from, to: $to, metric: ${metric.name}, '
      'onlyUnsynced: $onlyUnsynced)';
}

// ════════════════════════════════════════════════════════════════════════════
// Statistics snapshot
// ════════════════════════════════════════════════════════════════════════════

/// Aggregated statistics over the currently loaded records.
///
/// All nullable fields are null when no record in the loaded range carried
/// that metric. Statistics are computed from currently-loaded records only —
/// not from the full server dataset.
class HistoryStats {
  final int recordCount;
  final int unsyncedCount;

  final double? avgHr;
  final int? minHr;
  final int? maxHr;

  final double? avgSpo2;
  final int? minSpo2;
  final int? maxSpo2;

  final double? avgTemp;
  final double? minTemp;
  final double? maxTemp;

  final DateTime? firstRecordAt;
  final DateTime? lastRecordAt;

  const HistoryStats({
    required this.recordCount,
    required this.unsyncedCount,
    this.avgHr,
    this.minHr,
    this.maxHr,
    this.avgSpo2,
    this.minSpo2,
    this.maxSpo2,
    this.avgTemp,
    this.minTemp,
    this.maxTemp,
    this.firstRecordAt,
    this.lastRecordAt,
  });

  static const HistoryStats empty = HistoryStats(
    recordCount: 0,
    unsyncedCount: 0,
  );

  bool get isEmpty => recordCount == 0;
}

// ════════════════════════════════════════════════════════════════════════════
// History provider
// ════════════════════════════════════════════════════════════════════════════

class HistoryProvider extends ChangeNotifier {
  HistoryProvider() {
    _connectivitySubscription = _connectivity.onStatusChange.listen(
      _onConnectivityChange,
    );
  }

  // ── Services ──────────────────────────────────────────────────────────────

  final ApiService _api = ApiService.shared;
  final LocalDbService _db = LocalDbService();
  final ConnectivityService _connectivity = ConnectivityService();

  // ── State ─────────────────────────────────────────────────────────────────

  final List<HealthRecord> _history = <HealthRecord>[];

  HistoryFilter _filter = const HistoryFilter();

  bool _loading = false;
  bool _loadingMore = false;
  bool _offline = false;
  bool _hasMore = true;
  bool _disposed = false;

  String? _error;

  int _currentPage = 0;

  static const int _pageSize = 30;

  /// Bumped on every reload/filter change so stale in-flight loads can
  /// discard their results.
  int _loadGeneration = 0;

  StreamSubscription<bool>? _connectivitySubscription;

  // ── Getters ───────────────────────────────────────────────────────────────

  List<HealthRecord> get history => List.unmodifiable(_history);

  HistoryFilter get filter => _filter;

  bool get isLoading => _loading;
  bool get isLoadingMore => _loadingMore;
  bool get isOffline => _offline;
  bool get hasMore => _hasMore;
  bool get isEmpty => _history.isEmpty && !_loading;
  String? get error => _error;

  int get currentPage => _currentPage;
  int get pageSize => _pageSize;
  int get loadedCount => _history.length;

  /// Aggregate statistics over the currently loaded records.
  HistoryStats get stats => _computeStats(_history);

  /// Best-effort summary of pending uploads in the loaded window.
  int get unsyncedCount => _history.where((r) => !r.isSynced).length;

  // ── Public API — loading ──────────────────────────────────────────────────

  /// Loads the first page for the current filter.
  ///
  /// Safe to call multiple times. Any previous in-flight load is discarded.
  Future<void> load() async {
    if (_disposed) return;
    await _load(reset: true);
  }

  /// Loads the next page.
  Future<void> loadMore() async {
    if (_disposed || _loading || _loadingMore || !_hasMore) return;
    await _load(reset: false);
  }

  /// Refreshes from page 0, keeping the current filter.
  Future<void> refresh() async {
    if (_disposed) return;
    await _load(reset: true);
  }

  /// Applies a new filter and reloads from page 0.
  ///
  /// No-op if the filter is unchanged.
  Future<void> setFilter(HistoryFilter filter) async {
    if (_disposed) return;
    if (_filter == filter) return;

    _filter = filter;
    _safeNotify();

    await _load(reset: true);
  }

  /// Clears the filter and reloads.
  Future<void> clearFilter() async {
    if (_disposed) return;
    if (_filter.isEmpty) return;
    await setFilter(const HistoryFilter());
  }

  // ── Public API — single record ────────────────────────────────────────────

  /// Returns a record from the loaded window, or fetches it from the
  /// local database if not present.
  Future<HealthRecord?> getById(String id) async {
    if (_disposed) return null;

    for (final record in _history) {
      if (record.id == id) return record;
    }

    final userId = _currentUserId();
    if (userId == null) return null;

    try {
      return await _db.getRecordById(id, userId: userId);
    } catch (e, stack) {
      debugPrint('Guardian history getById failed: $e');
      debugPrintStack(stackTrace: stack);
      return null;
    }
  }

  // ── Public API — deletion ─────────────────────────────────────────────────

  /// Deletes a single record locally.
  ///
  /// The cloud copy is left intact for the next sync cycle to reconcile.
  /// Removes the record from the in-memory list.
  Future<bool> deleteRecord(String id) async {
    if (_disposed) return false;

    final userId = _currentUserId();
    if (userId == null) return false;

    try {
      final affected = await _db.deleteRecord(id, userId: userId);
      if (affected > 0) {
        _history.removeWhere((r) => r.id == id);
        _safeNotify();
      }
      return affected > 0;
    } catch (e, stack) {
      debugPrint('Guardian history record delete failed: $e');
      debugPrintStack(stackTrace: stack);
      return false;
    }
  }

  /// Deletes all local records older than [keep] for the current user.
  ///
  /// Returns the number of deleted records.
  Future<int> pruneLocalCache({
    Duration keep = const Duration(days: 90),
  }) async {
    if (_disposed) return 0;

    final userId = _currentUserId();
    if (userId == null) return 0;

    try {
      final removed = await _db.deleteOlderThan(keep, userId: userId);
      if (removed > 0) {
        // Drop them from the in-memory list too.
        final cutoff = DateTime.now().subtract(keep);
        _history.removeWhere((r) => r.recordedAt.isBefore(cutoff));
        _safeNotify();
      }
      return removed;
    } catch (e, stack) {
      debugPrint('Guardian history prune failed: $e');
      debugPrintStack(stackTrace: stack);
      return 0;
    }
  }

  // ── Public API — export ───────────────────────────────────────────────────

  /// Returns a copy of the currently loaded records for export.
  ///
  /// The caller is responsible for serializing and sharing.
  List<HealthRecord> snapshotForExport() =>
      List<HealthRecord>.unmodifiable(_history);

  /// Returns the currently loaded records filtered by the current
  /// [HistoryFilter.metric].
  List<HealthRecord> snapshotForMetric(HistoryMetric metric) {
    if (metric == HistoryMetric.all) return snapshotForExport();

    return _history
        .where((r) {
          switch (metric) {
            case HistoryMetric.all:
              return true;
            case HistoryMetric.heartRate:
              return r.heartRate != null;
            case HistoryMetric.spo2:
              return r.spo2 != null;
            case HistoryMetric.temperature:
              return r.temperature != null;
          }
        })
        .toList(growable: false);
  }

  // ── Public API — reset ────────────────────────────────────────────────────

  /// Clears in-memory state. Call on sign-out.
  void clear() {
    if (_disposed) return;

    _history.clear();
    _filter = const HistoryFilter();
    _currentPage = 0;
    _hasMore = true;
    _offline = false;
    _error = null;
    _loadGeneration++;

    _safeNotify();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    _safeNotify();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Internal — loading
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _load({required bool reset}) async {
    if (_disposed) return;

    if (reset) {
      if (_loading) {
        // Start a new generation to invalidate any in-flight load.
        _loadGeneration++;
      }
      _loading = true;
      _currentPage = 0;
      _hasMore = true;
    } else {
      _loadingMore = true;
    }

    _error = null;
    _safeNotify();

    final generation = ++_loadGeneration;

    try {
      final online = await _connectivity.checkNow();
      if (_disposed || generation != _loadGeneration) return;

      final page = reset ? 0 : _currentPage + 1;

      if (online) {
        try {
          await _loadFromCloud(
            page: page,
            reset: reset,
            generation: generation,
          );
        } on ApiException catch (e) {
          debugPrint('Guardian history cloud load failed: $e');

          // Fall back to local for this page.
          await _loadFromLocal(
            page: page,
            reset: reset,
            generation: generation,
          );
          if (_disposed || generation != _loadGeneration) return;

          _offline = true;
          _error = _friendlyError(e);
        }
      } else {
        await _loadFromLocal(page: page, reset: reset, generation: generation);
        if (_disposed || generation != _loadGeneration) return;
        _offline = true;
      }
    } catch (e, stack) {
      debugPrint('Guardian history load failed: $e');
      debugPrintStack(stackTrace: stack);

      if (!_disposed && generation == _loadGeneration) {
        _error = _friendlyError(e);
      }
    } finally {
      if (!_disposed && generation == _loadGeneration) {
        _loading = false;
        _loadingMore = false;
        _safeNotify();
      }
    }
  }

  Future<void> _loadFromCloud({
    required int page,
    required bool reset,
    required int generation,
  }) async {
    final userId = _currentUserId();
    if (userId == null || userId.isEmpty) {
      throw StateError('No authenticated user for cloud load.');
    }

    final cloudData = await _api.fetchHistory(
      from: _filter.from,
      to: _filter.to,
      page: page,
      limit: _pageSize,
    );

    if (_disposed || generation != _loadGeneration) return;

    // Cache cloud records WITHOUT re-enqueueing for sync. Mark them as
    // synced and patch userId if the backend omitted it.
    for (final record in cloudData) {
      final patched = record.copyWith(
        userId: record.userId.isEmpty ? userId : record.userId,
        isSynced: true,
      );

      try {
        await _db.insertRecord(patched, enqueueForSync: false);
      } catch (e) {
        debugPrint('Guardian history cache insert failed: $e');
      }
    }

    if (_disposed || generation != _loadGeneration) return;

    _applyFilterAndAppend(_filterLocally(cloudData), reset: reset);

    _hasMore = cloudData.length == _pageSize;
    _currentPage = page;
    _offline = false;
  }

  Future<void> _loadFromLocal({
    required int page,
    required bool reset,
    required int generation,
  }) async {
    final userId = _currentUserId();
    if (userId == null || userId.isEmpty) {
      if (reset) _history.clear();
      _hasMore = false;
      return;
    }

    final localData = await _db.queryRecords(
      userId: userId,
      from: _filter.from,
      to: _filter.to,
      limit: _pageSize,
      offset: page * _pageSize,
    );

    if (_disposed || generation != _loadGeneration) return;

    _applyFilterAndAppend(_filterLocally(localData), reset: reset);

    _hasMore = localData.length == _pageSize;
    _currentPage = page;
  }

  /// Applies the metric and unsynced filter to a record list.
  ///
  /// Date filtering happens at the DB/API layer, so it is not repeated here.
  List<HealthRecord> _filterLocally(List<HealthRecord> records) {
    Iterable<HealthRecord> filtered = records;

    if (_filter.onlyUnsynced) {
      filtered = filtered.where((r) => !r.isSynced);
    }

    switch (_filter.metric) {
      case HistoryMetric.all:
        break;
      case HistoryMetric.heartRate:
        filtered = filtered.where((r) => r.heartRate != null);
        break;
      case HistoryMetric.spo2:
        filtered = filtered.where((r) => r.spo2 != null);
        break;
      case HistoryMetric.temperature:
        filtered = filtered.where((r) => r.temperature != null);
        break;
    }

    return filtered.toList(growable: false);
  }

  void _applyFilterAndAppend(
    List<HealthRecord> records, {
    required bool reset,
  }) {
    if (reset) {
      _history
        ..clear()
        ..addAll(records);
    } else {
      final existing = _history.map((r) => r.id).toSet();
      for (final record in records) {
        if (existing.add(record.id)) {
          _history.add(record);
        }
      }
    }

    // Newest first.
    _history.sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Internal — stats
  // ─────────────────────────────────────────────────────────────────────────

  HistoryStats _computeStats(List<HealthRecord> records) {
    if (records.isEmpty) return HistoryStats.empty;

    final hrValues = <int>[];
    final spo2Values = <int>[];
    final tempValues = <double>[];
    var unsynced = 0;

    DateTime? earliest;
    DateTime? latest;

    for (final r in records) {
      if (!r.isSynced) unsynced++;

      if (r.heartRate != null) hrValues.add(r.heartRate!);
      if (r.spo2 != null) spo2Values.add(r.spo2!);
      if (r.temperature != null) tempValues.add(r.temperature!);

      if (earliest == null || r.recordedAt.isBefore(earliest)) {
        earliest = r.recordedAt;
      }
      if (latest == null || r.recordedAt.isAfter(latest)) {
        latest = r.recordedAt;
      }
    }

    return HistoryStats(
      recordCount: records.length,
      unsyncedCount: unsynced,
      avgHr: _averageInt(hrValues),
      minHr: hrValues.isEmpty ? null : hrValues.reduce((a, b) => a < b ? a : b),
      maxHr: hrValues.isEmpty ? null : hrValues.reduce((a, b) => a > b ? a : b),
      avgSpo2: _averageInt(spo2Values),
      minSpo2: spo2Values.isEmpty
          ? null
          : spo2Values.reduce((a, b) => a < b ? a : b),
      maxSpo2: spo2Values.isEmpty
          ? null
          : spo2Values.reduce((a, b) => a > b ? a : b),
      avgTemp: _averageDouble(tempValues),
      minTemp: tempValues.isEmpty
          ? null
          : tempValues.reduce((a, b) => a < b ? a : b),
      maxTemp: tempValues.isEmpty
          ? null
          : tempValues.reduce((a, b) => a > b ? a : b),
      firstRecordAt: earliest,
      lastRecordAt: latest,
    );
  }

  static double? _averageInt(List<int> values) {
    if (values.isEmpty) return null;
    var sum = 0;
    for (final v in values) {
      sum += v;
    }
    return sum / values.length;
  }

  static double? _averageDouble(List<double> values) {
    if (values.isEmpty) return null;
    var sum = 0.0;
    for (final v in values) {
      sum += v;
    }
    return sum / values.length;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Internal — connectivity
  // ─────────────────────────────────────────────────────────────────────────

  void _onConnectivityChange(bool online) {
    if (_disposed) return;
    if (_offline == !online) return;

    _offline = !online;
    _safeNotify();

    // On reconnect, refresh the current page from the server.
    if (online) {
      unawaited(_load(reset: true));
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Internal — helpers
  // ─────────────────────────────────────────────────────────────────────────

  String? _currentUserId() => FirebaseAuth.instance.currentUser?.uid;

  String _friendlyError(Object error) {
    if (error is ApiException) {
      if (error.isUnauthorized) {
        return 'Your session has expired. Please sign in again.';
      }
      if (error.isServerError) {
        return 'Cloud service is temporarily unavailable.';
      }
      if (error.statusCode == null) {
        return 'Network error. Showing locally stored data.';
      }
      return error.message;
    }

    return 'Unable to load history. Showing locally stored data.';
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Dispose
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;

    _history.clear();

    super.dispose();
  }
}
