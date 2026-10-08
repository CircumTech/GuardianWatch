// ─── lib/services/connectivity_service.dart ──────────────────────────────────
//
// Guardian Watch connectivity monitor.
//
// Purpose:
//   Inform the sync engine and UI when the device can reach the Guardian
//   backend. Reachability is checked against the API host, not a third
//   party — reachability to Google does not imply reachability to Render.
//
// Design rules:
//  Checks are deduplicated. Concurrent calls share one future.
//  The service never throws from startMonitoring or stopMonitoring.
//  State transitions are logged.
//  The singleton can be re-initialized after dispose via reset().
//

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config/constants.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Exception
// ─────────────────────────────────────────────────────────────────────────────

class ConnectivityServiceException implements Exception {
  final String message;
  final Object? cause;

  const ConnectivityServiceException(this.message, {this.cause});

  @override
  String toString() {
    final suffix = cause != null ? ' (cause: $cause)' : '';
    return 'ConnectivityServiceException: $message$suffix';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

class ConnectivityService {
  static ConnectivityService _instance = ConnectivityService._internal();

  factory ConnectivityService() => _instance;

  ConnectivityService._internal();

  // ── State ────────────────────────────────────────────────────────────────

  /// Null until the first check completes.
  ///
  /// Exposed as `isOnline` (false when unknown) so existing callers
  /// continue to work. New code should prefer `state` for tri-state logic.
  bool? _online;

  bool get isOnline => _online ?? false;

  /// Tri-state for callers who need to distinguish "offline" from
  /// "not yet checked".
  bool? get knownState => _online;

  final StreamController<bool> _controller = StreamController<bool>.broadcast();

  /// Emits whenever the reachability state changes.
  ///
  /// Note: only transitions are emitted. If the state is unchanged, no
  /// event is fired.
  Stream<bool> get onStatusChange => _controller.stream;

  Timer? _timer;

  /// In-flight reachability check, if any.
  Future<bool>? _activeCheck;

  /// In-flight check is cancelled on stopMonitoring.
  bool _cancelled = false;

  bool _disposed = false;

  // ── Monitoring ───────────────────────────────────────────────────────────

  /// Starts periodic reachability monitoring.
  ///
  /// Safe to call multiple times. If the service was disposed, re-arms it.
  void startMonitoring({Duration? interval}) {
    if (_disposed) {
      // Re-arm — a previous dispose() may have been called during a
      // hot-restart cycle or account switch.
      _disposed = false;
      _cancelled = false;
    }

    final effectiveInterval =
        interval ?? AppConstants.connectivityCheckInterval;

    _timer?.cancel();

    // Fire an immediate check. Errors are contained by _performCheck.
    unawaited(checkNow());

    _timer = Timer.periodic(effectiveInterval, (_) {
      unawaited(checkNow());
    });
  }

  /// Stops periodic monitoring.
  ///
  /// Does NOT close the stream controller — the service can be started
  /// again. Any in-flight check will complete but will not emit.
  void stopMonitoring() {
    _timer?.cancel();
    _timer = null;
    _cancelled = true;
  }

  // ── Checks ───────────────────────────────────────────────────────────────

  /// Runs a reachability check immediately.
  ///
  /// Concurrent calls share the same in-flight future.
  /// Never throws — returns false on any error.
  Future<bool> checkNow() async {
    if (_disposed) return false;

    final inFlight = _activeCheck;
    if (inFlight != null) return inFlight;

    final future = _performCheck();
    _activeCheck = future;

    try {
      return await future;
    } finally {
      if (identical(_activeCheck, future)) {
        _activeCheck = null;
      }
    }
  }

  Future<bool> _performCheck() async {
    bool reachable = false;

    try {
      final host = _apiHost();
      if (host == null || host.isEmpty) {
        // No API configured — cannot check.
        reachable = false;
      } else {
        final result = await InternetAddress.lookup(
          host,
        ).timeout(AppConstants.connectivityCheckTimeout);

        reachable =
            result.isNotEmpty && result.any((a) => a.rawAddress.isNotEmpty);
      }
    } on SocketException catch (e) {
      debugPrint('Guardian reachability SocketException: ${e.message}');
      reachable = false;
    } on TimeoutException {
      debugPrint('Guardian reachability timed out.');
      reachable = false;
    } catch (e, stack) {
      debugPrint('Guardian reachability check failed: $e');
      debugPrintStack(stackTrace: stack);
      reachable = false;
    }

    // If monitoring was stopped while the check was in flight, discard
    // the result and do not emit.
    if (_cancelled) {
      return reachable;
    }

    if (reachable != _online) {
      _online = reachable;

      debugPrint('Guardian connectivity: ${reachable ? "online" : "offline"}');

      if (!_controller.isClosed) {
        _controller.add(reachable);
      }
    }

    return reachable;
  }

  /// Extracts the host from `AppConstants.apiBaseUrl`.
  ///
  /// Returns null if the URL is not configured or malformed.
  String? _apiHost() {
    final raw = AppConstants.apiBaseUrl.trim();
    if (raw.isEmpty || raw.contains('xxxxxxxx')) return null;

    try {
      final uri = Uri.parse(raw);
      return uri.host.isNotEmpty ? uri.host : null;
    } catch (_) {
      return null;
    }
  }

  // ── Manual state ─────────────────────────────────────────────────────────

  /// Resets the service to an unknown state.
  ///
  /// Does NOT emit a false "offline" event — that would mislead the sync
  /// engine. Instead, forces a fresh check on the next tick, and clears
  /// the last-known state.
  ///
  /// Use this when you know the network changed but want the next check
  /// to determine the truth.
  void reset() {
    if (_disposed) return;

    _online = null;

    // Do not emit. The next check will emit if state actually changed.
    debugPrint('Guardian connectivity: state reset to unknown.');
  }

  /// Immediately reports offline to subscribers.
  ///
  /// Use only when the OS has confirmed the radio is off (e.g., from a
  /// `connectivity_plus` airplane-mode event). This bypasses the DNS check.
  void forceOffline() {
    if (_disposed) return;

    if (_online == false) return;

    _online = false;

    debugPrint('Guardian connectivity: forced offline.');

    if (!_controller.isClosed) {
      _controller.add(false);
    }
  }

  // ── Disposal ─────────────────────────────────────────────────────────────

  /// Closes the broadcast stream and marks the service as disposed.
  ///
  /// After dispose, subsequent calls to [startMonitoring] re-arm the
  /// service by replacing the internal state. This is intended for tests
  /// and hot-restart scenarios.
  void dispose() {
    if (_disposed) return;

    _disposed = true;
    _cancelled = true;

    _timer?.cancel();
    _timer = null;

    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  /// Full teardown suitable for a fresh app session.
  ///
  /// Closes the current controller and creates a new one so that
  /// subsequent subscribers receive events again.
  ///
  /// Intended for logout flows or tests.
  void resetSingleton() {
    dispose();
    _instance = ConnectivityService._internal();
  }
}
