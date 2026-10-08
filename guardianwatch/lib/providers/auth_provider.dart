// ─── lib/providers/auth_provider.dart ────────────────────────────────────────
//
// AuthProvider — ChangeNotifier wrapper around AuthService.
//
// Responsibilities:
//   Expose the current Firebase user to the widget tree
//   Provide a stable loading/error state during auth operations
//   Preserve FirebaseAuthException codes so the UI can branch
//   Guard against notify-after-dispose
//
// Design rules:
//   AuthService is injected (testable). Default: a single shared instance.
//   All async methods guard against a disposed notifier.
//   Raw error strings are never surfaced to the UI. Errors are typed.
//

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../services/auth_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Typed error exposed to the UI
// ─────────────────────────────────────────────────────────────────────────────

class AuthError {
  /// Firebase error code when available (e.g. 'wrong-password').
  final String? code;

  /// Human-readable, user-safe message.
  final String message;

  /// The original error, for logging only.
  final Object? cause;

  const AuthError({required this.message, this.code, this.cause});

  @override
  String toString() => 'AuthError(${code ?? '-'}): $message';
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────────

class AuthProvider extends ChangeNotifier {
  AuthProvider({AuthService? service}) : _svc = service ?? _defaultService;

  /// Shared AuthService so the onSessionExpired handler is registered
  /// exactly once for the app.
  static final AuthService _defaultService = AuthService();

  final AuthService _svc;

  User? _user;
  bool _initialized = false;
  bool _isAuthenticating = false;
  AuthError? _error;

  StreamSubscription<User?>? _authSubscription;
  bool _disposed = false;

  /// Completes once the first auth state event has been observed.
  final Completer<void> _authReadyCompleter = Completer<void>();

  // ── Public state ─────────────────────────────────────────────────────────

  User? get user => _user;
  bool get isAuthenticated => _user != null;

  /// True until the first auth state event arrives. Use this during app
  /// bootstrap to decide between splash and login.
  bool get isInitializing => !_initialized;

  /// True while a sign-in / register / delete is in flight. Use this to
  /// disable buttons — not to gate the whole app.
  bool get isAuthenticating => _isAuthenticating;

  /// Combined loading state for callers that only want "is the user
  /// expected to wait right now".
  bool get isLoading => isInitializing || _isAuthenticating;

  AuthError? get error => _error;

  /// True once the first auth state event has been observed.
  bool get isReady => _initialized;

  /// Convenience for the UI. Reflects the last known emailVerified state.
  bool get emailVerified => _user?.emailVerified ?? false;

  /// The Firebase UID, or null if not signed in.
  String? get uid => _user?.uid;

  /// The Firebase email, or null if not signed in.
  String? get email => _user?.email;

  // ── Lifecycle ────────────────────────────────────────────────────────────

  /// Awaits the first auth state event.
  ///
  /// Useful in main() / splash screen:
  ///
  ///   final auth = AuthProvider();
  ///   await auth.waitUntilReady();
  Future<void> waitUntilReady() => _authReadyCompleter.future;

  // ── Init ─────────────────────────────────────────────────────────────────

  // NOTE: The subscription is set up in the constructor body below.
  //       Keeping it out of the field initializer avoids a race with
  //       `super()` if the stream ever emits synchronously.

  void _listenToAuthChanges() {
    _authSubscription = _svc.authStateChanges.listen(
      _handleAuthState,
      onError: _handleAuthError,
    );
  }

  void _handleAuthState(User? user) {
    if (_disposed) return;

    _user = user;
    _initialized = true;

    if (!_authReadyCompleter.isCompleted) {
      _authReadyCompleter.complete();
    }

    _safeNotify();
  }

  void _handleAuthError(Object error, StackTrace stack) {
    if (_disposed) return;

    debugPrint('Guardian auth state error: $error');
    debugPrintStack(stackTrace: stack);

    _error = _formatError(error);
    _initialized = true;

    if (!_authReadyCompleter.isCompleted) {
      _authReadyCompleter.complete();
    }

    _safeNotify();
  }

  // ── Error handling ───────────────────────────────────────────────────────

  void clearError() {
    if (_error == null) return;
    _error = null;
    _safeNotify();
  }

  void _setError(Object error) {
    _error = _formatError(error);
  }

  /// Maps any error into a user-safe [AuthError].
  ///
  /// Raw `toString()` values are never shown. Unknown errors surface as a
  /// generic message; the real cause is attached for logging.
  AuthError _formatError(Object error) {
    if (error is FirebaseAuthException) {
      return AuthError(
        code: error.code,
        message: _firebaseMessage(error),
        cause: error,
      );
    }

    if (error is AuthServiceException) {
      return AuthError(message: error.message, cause: error);
    }

    if (error is StateError) {
      return AuthError(message: error.message, cause: error);
    }

    return AuthError(
      message: 'Something went wrong. Please try again.',
      cause: error,
    );
  }

  String _firebaseMessage(FirebaseAuthException e) {
    // Prefer the OS-agnostic code over the raw message.
    switch (e.code) {
      case 'invalid-email':
        return 'That email address is not valid.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'user-not-found':
        return 'No account found with that email.';
      case 'wrong-password':
        return 'Incorrect password. Please try again.';
      case 'invalid-credential':
        return 'Incorrect email or password.';
      case 'email-already-in-use':
        return 'An account already exists with that email.';
      case 'weak-password':
        return 'Please choose a stronger password.';
      case 'operation-not-allowed':
        return 'This sign-in method is not enabled.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait and try again.';
      case 'requires-recent-login':
        return 'Please sign in again to complete this action.';
      case 'network-request-failed':
        return 'Network error. Check your connection and try again.';
      default:
        return e.message ?? 'Authentication failed. Please try again.';
    }
  }

  // ── Register ─────────────────────────────────────────────────────────────

  Future<User?> register(
    String email,
    String password,
    String displayName,
  ) async {
    return _runAuthOperation(() async {
      return await _svc.registerWithEmail(
        email.trim(),
        password,
        displayName.trim(),
      );
    });
  }

  // ── Email sign-in ────────────────────────────────────────────────────────

  Future<User?> signInWithEmail(String email, String password) async {
    return _runAuthOperation(() async {
      return await _svc.signInWithEmail(email.trim(), password);
    });
  }

  // ── Google sign-in ───────────────────────────────────────────────────────

  Future<User?> signInWithGoogle() async {
    return _runAuthOperation(() async {
      return await _svc.signInWithGoogle();
    });
  }

  // ── Password reset ───────────────────────────────────────────────────────

  Future<void> sendPasswordResetEmail(String email) async {
    if (_disposed) return;

    clearError();
    _isAuthenticating = true;
    _safeNotify();

    try {
      await _svc.sendPasswordResetEmail(email.trim());
    } catch (e, stack) {
      debugPrint('Guardian password reset failed: $e');
      debugPrintStack(stackTrace: stack);
      _setError(e);
      rethrow;
    } finally {
      _isAuthenticating = false;
      _safeNotify();
    }
  }

  // ── Profile ──────────────────────────────────────────────────────────────

  Future<void> updateUserProfile({
    String? displayName,
    String? photoURL,
  }) async {
    if (_disposed) return;

    clearError();

    try {
      await _svc.updateUserProfile(
        displayName: displayName?.trim(),
        photoURL: photoURL,
      );

      // Service already reloads the Firebase user. Refresh local state.
      _user = _svc.currentUser;
      _safeNotify();
    } catch (e, stack) {
      debugPrint('Guardian profile update failed: $e');
      debugPrintStack(stackTrace: stack);
      _setError(e);
      _safeNotify();
      rethrow;
    }
  }

  // ── Email verification ───────────────────────────────────────────────────

  Future<void> sendEmailVerification() async {
    if (_disposed) return;

    clearError();

    try {
      await _svc.sendEmailVerification();
      _user = _svc.currentUser;
      _safeNotify();
    } catch (e, stack) {
      debugPrint('Guardian email verification failed: $e');
      debugPrintStack(stackTrace: stack);
      _setError(e);
      _safeNotify();
      rethrow;
    }
  }

  Future<bool> refreshEmailVerified() async {
    if (_disposed) return false;

    try {
      final verified = await _svc.isEmailVerified();
      _user = _svc.currentUser;
      _safeNotify();
      return verified;
    } catch (e) {
      debugPrint('Guardian email verification refresh failed: $e');
      _setError(e);
      _safeNotify();
      return false;
    }
  }

  // ── Reload ───────────────────────────────────────────────────────────────

  Future<void> reloadUser() async {
    if (_disposed) return;

    try {
      await _svc.currentUser?.reload();
      _user = _svc.currentUser;
      _safeNotify();
    } catch (e, stack) {
      debugPrint('Guardian user reload failed: $e');
      debugPrintStack(stackTrace: stack);
      _setError(e);
      _safeNotify();
    }
  }

  // ── Delete account ───────────────────────────────────────────────────────

  /// Deletes the account.
  ///
  /// May throw `FirebaseAuthException` with code `requires-recent-login`.
  /// The UI should catch that code, prompt for password, call
  /// [reauthenticate], then retry.
  Future<void> deleteAccount() async {
    await _runAuthOperation(() async {
      // Backend data deletion FIRST. Once Firebase deletes the account,
      // the JWT is invalid and this endpoint becomes unreachable.
      //await _api.deleteAccount();
      // Then Firebase + local cleanup.
      await _svc.deleteAccount();
      _user = null;
      return null;
    });
  }

  /// Re-authenticates the current user with email + password.
  ///
  /// Use before [deleteAccount] if Firebase returns
  /// `requires-recent-login`.
  Future<void> reauthenticate({
    required String email,
    required String password,
  }) async {
    if (_disposed) return;

    clearError();

    try {
      await _svc.reauthenticateWithPassword(email: email, password: password);
      _user = _svc.currentUser;
      _safeNotify();
    } catch (e, stack) {
      debugPrint('Guardian reauthentication failed: $e');
      debugPrintStack(stackTrace: stack);
      _setError(e);
      _safeNotify();
      rethrow;
    }
  }

  // ── Sign out ─────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    if (_disposed) return;

    clearError();

    try {
      await _svc.signOut();
      _user = null;
      _safeNotify();
    } catch (e, stack) {
      debugPrint('Guardian sign-out failed: $e');
      debugPrintStack(stackTrace: stack);
      _setError(e);
      _safeNotify();
      rethrow;
    }
  }

  // ── Shared operation wrapper ─────────────────────────────────────────────

  /// Runs an auth operation with consistent error handling, loading state,
  /// and dispose guarding.
  Future<User?> _runAuthOperation(Future<User?> Function() operation) async {
    if (_disposed) return null;

    clearError();
    _isAuthenticating = true;
    _safeNotify();

    try {
      final result = await operation();
      if (!_disposed) {
        _user = result ?? _svc.currentUser;
      }
      return result;
    } catch (e, stack) {
      debugPrint('Guardian auth operation failed: $e');
      debugPrintStack(stackTrace: stack);
      _setError(e);
      rethrow;
    } finally {
      if (!_disposed) {
        _isAuthenticating = false;
        _safeNotify();
      }
    }
  }

  // ── Notify guard ─────────────────────────────────────────────────────────

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  // ── Dispose ──────────────────────────────────────────────────────────────

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    _authSubscription?.cancel();
    _authSubscription = null;

    // Complete the readiness future so any awaiting callers unblock.
    if (!_authReadyCompleter.isCompleted) {
      _authReadyCompleter.complete();
    }

    super.dispose();
  }
}
