import 'package:flutter/foundation.dart';
import '../models/health_record.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import '../services/connectivity_service.dart';

class DashboardProvider extends ChangeNotifier {
  final ApiService _api = ApiService();
  final LocalDbService _db = LocalDbService();
  final ConnectivityService _connectivity = ConnectivityService();

  List<HealthRecord> _history = [];
  bool _loading = false;
  bool _offline = false;
  String? _error;
  bool _hasMore = true;
  int _currentPage = 0;
  static const int _pageSize = 20;

  List<HealthRecord> get history => _history;
  bool get isLoading => _loading;
  bool get isOffline => _offline;
  String? get error => _error;
  bool get hasMore => _hasMore;

  // Derived stats
  double? get avgHr {
    if (_history.isEmpty) return null;
    return _history.map((r) => r.heartRate).reduce((a, b) => a + b) /
        _history.length;
  }

  double? get avgSpo2 {
    if (_history.isEmpty) return null;
    return _history.map((r) => r.spo2).reduce((a, b) => a + b) /
        _history.length;
  }

  double? get avgTemp {
    if (_history.isEmpty) return null;
    return _history.map((r) => r.temperature).reduce((a, b) => a + b) /
        _history.length;
  }

  int? get minHr {
    if (_history.isEmpty) return null;
    return _history.map((r) => r.heartRate).reduce((a, b) => a < b ? a : b);
  }

  int? get maxHr {
    if (_history.isEmpty) return null;
    return _history.map((r) => r.heartRate).reduce((a, b) => a > b ? a : b);
  }

  // ── Load history (cloud first, SQLite fallback) with pagination ────────────
  Future<void> loadHistory({
    DateTime? from,
    DateTime? to,
    int page = 0,
  }) async {
    _loading = true;
    _error = null;
    if (page == 0) _history.clear();
    notifyListeners();

    final online = await _connectivity.checkNow();

    if (online) {
      try {
        final cloudData = await _api.fetchHistory(
          from: from,
          to: to,
          page: page,
          limit: _pageSize,
        );
        if (page == 0) {
          _history = cloudData;
        } else {
          _history.addAll(cloudData);
        }
        _hasMore = cloudData.length == _pageSize;
        _offline = false;
        // Backfill local DB with cloud data for offline access
        for (final r in cloudData) {
          await _db.insertRecord(r);
        }
      } catch (e) {
        // Cloud failed even though online — fallback to local DB
        final localData = await _db.queryRecords(
          from: from,
          to: to,
          limit: _pageSize,
          offset: page * _pageSize,
        );
        if (page == 0) {
          _history = localData;
        } else {
          _history.addAll(localData);
        }
        _hasMore = localData.length == _pageSize;
        _error = 'Cloud unavailable, showing cached data.';
        _offline = true;
      }
    } else {
      // Fully offline — use local SQLite
      final localData = await _db.queryRecords(
        from: from,
        to: to,
        limit: _pageSize,
        offset: page * _pageSize,
      );
      if (page == 0) {
        _history = localData;
      } else {
        _history.addAll(localData);
      }
      _hasMore = localData.length == _pageSize;
      _offline = true;
    }

    _loading = false;
    notifyListeners();
  }

  // ── Load more records (pagination) ─────────────────────────────────────────
  Future<void> loadMoreHistory({DateTime? from, DateTime? to}) async {
    if (!_hasMore || _loading) return;
    _currentPage++;
    await loadHistory(from: from, to: to, page: _currentPage);
  }

  // ── Refresh (reset pagination) ─────────────────────────────────────────────
  Future<void> refreshHistory({DateTime? from, DateTime? to}) async {
    _currentPage = 0;
    await loadHistory(from: from, to: to);
  }

  // ── Prune old local records ────────────────────────────────────────────────
  Future<void> pruneLocalCache({Duration keep = const Duration(days: 30)}) =>
      _db.deleteOlderThan(keep);
}
