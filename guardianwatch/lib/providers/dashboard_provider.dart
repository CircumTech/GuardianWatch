// ════════════════════════════════════════════════════════════════════════════
// lib/providers/dashboard_provider.dart
// ════════════════════════════════════════════════════════════════════════════
//
// DashboardProvider — history + derived stats.
//
// Responsibilities:
//   Load paginated health-record history from cloud or local cache
//   Cache cloud records locally for offline access
//   Compute average / min / max statistics from non-null values
//   React to connectivity changes so offline state stays fresh
//
// Design rules:
//   Local queries are always scoped to the current authenticated user.
//   Cloud-cached records are never re-enqueued for sync.
//   Stats ignore null values, never assume they exist.
//   All notifyListeners() paths are guarded by _disposed.
//

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/health_record.dart';
import '../services/api_service.dart';
import '../services/connectivity_service.dart';
import '../services/local_db_service.dart';

class DashboardProvider extends ChangeNotifier {
  DashboardProvider() {
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

  bool _loading = false;
  bool _offline = false;
  bool _hasMore = true;
  bool _disposed = false;

  String? _error;

  int _currentPage = 0;

  static const int _pageSize = 20;

  StreamSubscription<bool>? _connectivitySubscription;

  // ── Getters ───────────────────────────────────────────────────────────────

  List<HealthRecord> get history => List.unmodifiable(_history);
  bool get isLoading => _loading;
  bool get isOffline => _offline;
  bool get hasMore => _hasMore;
  String? get error => _error;
  int get currentPage => _currentPage;
  int get pageSize => _pageSize;

  /// Completes with the authenticated user's UID, or null if signed out.
  String? _currentUserId() => FirebaseAuth.instance.currentUser?.uid;

  // ── Derived statistics ────────────────────────────────────────────────────
  //
  // Every stat filters out null values before computing. If no record in the
  // current page contains a value for the metric, the getter returns null.

  double? get avgHr => _average(_history.map((r) => r.heartRate));

  double? get avgSpo2 => _average(_history.map((r) => r.spo2));

  double? get avgTemp => _average(_history.map((r) => r.temperature));

  int? get minHr {
    final values = _history.map((r) => r.heartRate).whereType<int>();
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a < b ? a : b);
  }

  int? get maxHr {
    final values = _history.map((r) => r.heartRate).whereType<int>();
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a > b ? a : b);
  }

  int? get latestHeartRate =>
      _history.isEmpty ? null : _history.first.heartRate;

  static double? _average(Iterable<num?> source) {
    final values = source.whereType<num>().toList(growable: false);
    if (values.isEmpty) return null;

    var sum = 0.0;
    for (final v in values) {
      sum += v.toDouble();
    }
    return sum / values.length;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // History loading
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> loadHistory({DateTime? from, DateTime? to, int page = 0}) async {
    if (_disposed || _loading) return;

    _loading = true;
    _error = null;

    if (page == 0) {
      _history.clear();
      _currentPage = 0;
    }

    _safeNotify();

    try {
      final online = await _connectivity.checkNow();
      if (_disposed) return;

      if (online) {
        try {
          await _loadFromCloud(from: from, to: to, page: page);
        } catch (e, stack) {
          debugPrint('Guardian dashboard cloud load failed: $e');
          debugPrintStack(stackTrace: stack);

          // Fall back to local for this page.
          await _loadFromLocal(from: from, to: to, page: page);
          _offline = true;
          _error = _friendlyError(e);
        }
      } else {
        await _loadFromLocal(from: from, to: to, page: page);
        _offline = true;
      }
    } catch (e, stack) {
      debugPrint('Guardian dashboard load failed: $e');
      debugPrintStack(stackTrace: stack);
      if (!_disposed) _error = _friendlyError(e);
    } finally {
      if (!_disposed) {
        _loading = false;
        _safeNotify();
      }
    }
  }

  Future<void> _loadFromCloud({
    DateTime? from,
    DateTime? to,
    required int page,
  }) async {
    final userId = _currentUserId();
    if (userId == null || userId.isEmpty) {
      throw StateError('No authenticated user for cloud load.');
    }

    final cloudData = await _api.fetchHistory(
      from: from,
      to: to,
      page: page,
      limit: _pageSize,
    );

    if (_disposed) return;

    // Cache records locally without re-enqueuing for sync, and mark them
    // as synced (they came from the server). Patch userId if the backend
    // omitted it.
    for (final record in cloudData) {
      final patched = record.userId.isEmpty || record.userId != userId
          ? record.copyWith(userId: userId, isSynced: true)
          : record.copyWith(isSynced: true);

      await _db.insertRecord(patched, enqueueForSync: false);
    }

    if (_disposed) return;

    _appendUniqueRecords(cloudData, replace: page == 0);
    _hasMore = cloudData.length == _pageSize;
    _currentPage = page;
    _offline = false;
  }

  Future<void> _loadFromLocal({
    DateTime? from,
    DateTime? to,
    required int page,
  }) async {
    final userId = _currentUserId();
    if (userId == null || userId.isEmpty) {
      // No user → nothing local to load.
      if (page == 0) _history.clear();
      _hasMore = false;
      return;
    }

    final localData = await _db.queryRecords(
      userId: userId,
      from: from,
      to: to,
      limit: _pageSize,
      offset: page * _pageSize,
    );

    if (_disposed) return;

    _appendUniqueRecords(localData, replace: page == 0);
    _hasMore = localData.length == _pageSize;
    _currentPage = page;
  }

  void _appendUniqueRecords(
    List<HealthRecord> records, {
    required bool replace,
  }) {
    if (replace) {
      _history
        ..clear()
        ..addAll(records);
    } else {
      final existingIds = _history.map((r) => r.id).toSet();
      for (final record in records) {
        if (existingIds.add(record.id)) {
          _history.add(record);
        }
      }
    }

    // Keep newest-first ordering stable even if the source was not sorted.
    _history.sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Pagination
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> loadMoreHistory({DateTime? from, DateTime? to}) async {
    if (_disposed || _loading || !_hasMore) return;
    await loadHistory(from: from, to: to, page: _currentPage + 1);
  }

  Future<void> refreshHistory({DateTime? from, DateTime? to}) async {
    _currentPage = 0;
    _hasMore = true;
    await loadHistory(from: from, to: to, page: 0);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Retention
  // ─────────────────────────────────────────────────────────────────────────

  /// Deletes local records older than [keep] for the current user.
  ///
  /// Returns the number of deleted rows. Returns 0 when no user is
  /// signed in.
  Future<int> pruneLocalCache({
    Duration keep = const Duration(days: 30),
  }) async {
    final userId = _currentUserId();
    if (userId == null || userId.isEmpty) return 0;
    return _db.deleteOlderThan(keep, userId: userId);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Connectivity
  // ─────────────────────────────────────────────────────────────────────────

  void _onConnectivityChange(bool online) {
    if (_disposed) return;
    if (_offline == !online) return;

    _offline = !online;
    _safeNotify();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Error handling
  // ─────────────────────────────────────────────────────────────────────────

  void clearError() {
    if (_error == null) return;
    _error = null;
    _safeNotify();
  }

  /// Maps errors to user-safe strings. Never leaks raw Dart exceptions.
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

  // ─────────────────────────────────────────────────────────────────────────
  // Reset
  // ─────────────────────────────────────────────────────────────────────────

  /// Clears all in-memory state. Call on sign-out.
  void clear() {
    if (_disposed) return;
    _history.clear();
    _currentPage = 0;
    _hasMore = true;
    _offline = false;
    _error = null;
    _safeNotify();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Notify guard
  // ─────────────────────────────────────────────────────────────────────────

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

    super.dispose();
  }
}
