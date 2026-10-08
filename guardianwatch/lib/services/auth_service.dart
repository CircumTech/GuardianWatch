// ─── lib/services/auth_service.dart ──────────────────────────────────────────

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../config/constants.dart';
import 'health_export_service.dart';
import 'api_service.dart';
import 'local_db_service.dart';

class AuthService {
  AuthService({
    FirebaseAuth? auth,
    GoogleSignIn? googleSignIn,
    ApiService? api,
    LocalDbService? localDb,
  }) : _auth = auth ?? FirebaseAuth.instance,
       _googleSI = googleSignIn ?? GoogleSignIn.instance,
       _api = api ?? ApiService.shared,
       _localDb = localDb ?? LocalDbService() {
    // Register the session-expired handler
    _api.onSessionExpired = _handleSessionExpired;
  }

  final FirebaseAuth _auth;
  final GoogleSignIn _googleSI;
  final ApiService _api;
  final LocalDbService _localDb;

  /// Tracks initialization of Google Sign-In without awaiting between the
  /// check and the flag write.
  Completer<void>? _googleSignInInit;

  /// Prevents concurrent Firebase to backend token exchanges and avoids
  /// caching failed futures across callers.
  Future<String?>? _tokenExchangeInProgress;

  // ─────────────────────────────────────────────────────────────────────────
  // Public state
  // ─────────────────────────────────────────────────────────────────────────

  User? get currentUser => _auth.currentUser;

  bool get isLoggedIn => currentUser != null;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Stream<User?> get idTokenChanges => _auth.idTokenChanges();

  Stream<User?> get userChanges => _auth.userChanges();

  // ─────────────────────────────────────────────────────────────────────────
  // Session-expired handler
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _handleSessionExpired() async {
    debugPrint('Guardian session expired — signing out.');
    try {
      await _auth.signOut();
    } catch (e) {
      debugPrint('Session-expired sign-out failed: $e');
    }
    try {
      await _api.clearSession();
    } catch (e) {
      debugPrint('Session-expired token clear failed: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Google Sign-In initialization
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> initGoogleSignIn({
    String? clientId,
    String? serverClientId,
  }) async {
    final existing = _googleSignInInit;
    if (existing != null) {
      return existing.future;
    }

    final completer = Completer<void>();
    _googleSignInInit = completer;

    try {
      final effectiveServerClientId =
          serverClientId ?? AppConstants.googleServerClientId;

      // Require a server client ID in production, otherwise the backend
      // will reject the Firebase ID token as coming from an untrusted
      // client.
      if (kReleaseMode && effectiveServerClientId.isEmpty) {
        throw const AuthServiceException(
          'GOOGLE_SERVER_CLIENT_ID is required for production builds.',
        );
      }

      await _googleSI.initialize(
        clientId: clientId ?? AppConstants.googleClientId,
        serverClientId: effectiveServerClientId.isEmpty
            ? null
            : effectiveServerClientId,
      );

      // Best-effort silent sign-in. Not fatal.
      try {
        await _googleSI.attemptLightweightAuthentication();
      } catch (e) {
        debugPrint('Google lightweight authentication failed: $e');
      }

      completer.complete();
    } catch (e, stack) {
      debugPrint('Google Sign-In initialization failed: $e');
      debugPrintStack(stackTrace: stack);

      // Allow a future call to retry.
      _googleSignInInit = null;

      if (!completer.isCompleted) {
        completer.completeError(e, stack);
      }
      rethrow;
    }
  }

  Future<void> _ensureGoogleInitialized({
    String? clientId,
    String? serverClientId,
  }) {
    return initGoogleSignIn(clientId: clientId, serverClientId: serverClientId);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Firebase to Guardian backend JWT
  // ─────────────────────────────────────────────────────────────────────────

  /// Exchanges the current Firebase ID token for a Guardian JWT.
  ///
  /// Returns null if there is no signed-in Firebase user.
  ///
  /// Throws [ApiException] if the backend exchange fails. Callers that
  /// need a non-fatal variant should use [tryExchangeCurrentFirebaseToken].
  Future<String?> exchangeCurrentFirebaseToken({
    bool forceRefresh = false,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      await _api.clearSession();
      return null;
    }

    final inFlight = _tokenExchangeInProgress;
    if (inFlight != null) return inFlight;

    final future = _performTokenExchange(user, forceRefresh: forceRefresh);
    _tokenExchangeInProgress = future;

    try {
      return await future;
    } finally {
      // Always clear — do not cache failed futures.
      if (identical(_tokenExchangeInProgress, future)) {
        _tokenExchangeInProgress = null;
      }
    }
  }

  /// Non-fatal variant. Returns null on backend failure without throwing.
  ///
  /// Use this during sign-in so a temporarily unavailable backend does not
  /// prevent the user from authenticating locally with Firebase.
  Future<String?> tryExchangeCurrentFirebaseToken({
    bool forceRefresh = false,
  }) async {
    try {
      return await exchangeCurrentFirebaseToken(forceRefresh: forceRefresh);
    } catch (e) {
      debugPrint('Guardian backend token exchange failed (non-fatal): $e');
      return null;
    }
  }

  Future<String?> _performTokenExchange(
    User user, {
    required bool forceRefresh,
  }) async {
    final firebaseIdToken = await user.getIdToken(forceRefresh);
    if (firebaseIdToken == null || firebaseIdToken.isEmpty) {
      throw const ApiException(
        message: 'Firebase did not return a valid ID token.',
        endpoint: '/auth/token',
      );
    }
    return _api.exchangeToken(firebaseIdToken);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Email/password registration
  // ─────────────────────────────────────────────────────────────────────────

  Future<User?> registerWithEmail(
    String email,
    String password,
    String displayName,
  ) async {
    final normalizedEmail = email.trim().toLowerCase();
    final normalizedName = displayName.trim();

    if (normalizedEmail.isEmpty) {
      throw FirebaseAuthException(
        code: 'invalid-email',
        message: 'Please enter your email address.',
      );
    }
    if (password.isEmpty) {
      throw FirebaseAuthException(
        code: 'invalid-password',
        message: 'Please enter a password.',
      );
    }
    if (normalizedName.isEmpty) {
      throw FirebaseAuthException(
        code: 'invalid-display-name',
        message: 'Please enter your name.',
      );
    }

    final credential = await _auth.createUserWithEmailAndPassword(
      email: normalizedEmail,
      password: password,
    );

    final user = credential.user;
    if (user == null) {
      throw const AuthServiceException(
        'Firebase did not return the newly created user.',
      );
    }

    await user.updateDisplayName(normalizedName);
    await user.reload();

    final refreshedUser = _auth.currentUser ?? user;

    // Non-fatal: sign-in succeeds even if the backend is unreachable.
    await tryExchangeCurrentFirebaseToken(forceRefresh: true);

    return refreshedUser;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Email/password sign-in
  // ─────────────────────────────────────────────────────────────────────────

  Future<User?> signInWithEmail(String email, String password) async {
    final normalizedEmail = email.trim().toLowerCase();

    final credential = await _auth.signInWithEmailAndPassword(
      email: normalizedEmail,
      password: password,
    );

    final user = credential.user;
    if (user == null) {
      throw const AuthServiceException(
        'Firebase did not return an authenticated user.',
      );
    }

    await tryExchangeCurrentFirebaseToken(forceRefresh: true);
    return user;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Google authentication
  // ─────────────────────────────────────────────────────────────────────────

  Future<User?> signInWithGoogle({
    String? clientId,
    String? serverClientId,
  }) async {
    await _ensureGoogleInitialized(
      clientId: clientId,
      serverClientId: serverClientId,
    );

    if (!_googleSI.supportsAuthenticate()) {
      throw const AuthServiceException(
        'Google Sign-In is not supported on this platform '
        'through the authenticate() flow.',
      );
    }

    try {
      final GoogleSignInAccount googleUser = await _googleSI.authenticate();
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      final idToken = googleAuth.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw const AuthServiceException(
          'Google Sign-In did not return an ID token.',
        );
      }

      final credential = GoogleAuthProvider.credential(idToken: idToken);
      final userCredential = await _auth.signInWithCredential(credential);
      final user = userCredential.user;

      if (user == null) {
        throw const AuthServiceException(
          'Firebase did not return a Google-authenticated user.',
        );
      }

      await tryExchangeCurrentFirebaseToken(forceRefresh: true);
      return user;
    } on GoogleSignInException catch (e) {
      debugPrint('Google Sign-In failed: ${e.code}: ${e.description}');
      rethrow;
    } catch (e) {
      debugPrint('Google authentication failed: $e');
      rethrow;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Password reset
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> sendPasswordResetEmail(String email) async {
    final normalizedEmail = email.trim().toLowerCase();

    if (normalizedEmail.isEmpty) {
      throw FirebaseAuthException(
        code: 'invalid-email',
        message: 'Please enter your email address.',
      );
    }

    await _auth.sendPasswordResetEmail(email: normalizedEmail);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Profile
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> updateUserProfile({
    String? displayName,
    String? photoURL,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthServiceException('No authenticated user.');
    }

    final normalizedName = displayName?.trim();

    if (normalizedName != null && normalizedName.isNotEmpty) {
      await user.updateDisplayName(normalizedName);
    }

    if (photoURL != null) {
      await user.updatePhotoURL(
        photoURL.trim().isEmpty ? null : photoURL.trim(),
      );
    }

    await user.reload();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Email verification & account management
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> sendEmailVerification() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthServiceException('No authenticated user.');
    }
    if (user.emailVerified) return;
    await user.sendEmailVerification();
  }

  Future<bool> isEmailVerified() async {
    final user = _auth.currentUser;
    if (user == null) return false;

    try {
      await user.reload();
    } catch (e) {
      debugPrint('Email verification reload failed: $e');
    }

    // Re-read from the authenticated instance in case reload replaced it.
    return _auth.currentUser?.emailVerified ?? false;
  }

  Future<void> reauthenticateWithPassword({
    required String email,
    required String password,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthServiceException('No authenticated user.');
    }

    final credential = EmailAuthProvider.credential(
      email: email.trim().toLowerCase(),
      password: password,
    );

    await user.reauthenticateWithCredential(credential);
  }

  /// Deletes the current user's account and clears local data.
  ///
  /// Throws [FirebaseAuthException] with code `requires-recent-login` if
  /// Firebase requires re-authentication. Callers should catch that code
  /// and prompt the user for their password via
  /// [reauthenticateWithPassword], then retry.
  Future<void> deleteAccount() async {
    final user = _auth.currentUser;
    if (user == null) return;

    final uid = user.uid;

    // Delete from Firebase first
    await user.delete();

    // Now clean up local data. Best-effort: failures here are logged but
    // do not propagate, because the Firebase account is already gone.
    try {
      await _localDb.clearUserData(uid);
    } catch (e) {
      debugPrint('Local data clear after delete failed: $e');
    }

    await _api.clearSession();
  }

  Future<void> signOut() async {
    final uid = _auth.currentUser?.uid;

    try {
      await _googleSI.signOut();
    } catch (e) {
      debugPrint('Google Sign-Out warning: $e');
    }

    try {
      await _auth.signOut();
    } catch (e) {
      debugPrint('Firebase sign-out warning: $e');
    }

    if (uid != null) {
      try {
        await _localDb.clearUserData(uid);
        await HealthExportService.shared().clearOptIn();
      } catch (e) {
        debugPrint('Local data clear on sign-out failed: $e');
      }
    }

    await _api.clearSession();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exception
// ─────────────────────────────────────────────────────────────────────────────

class AuthServiceException implements Exception {
  final String message;
  final Object? cause;

  const AuthServiceException(this.message, {this.cause});

  @override
  String toString() {
    final suffix = cause != null ? ' (cause: $cause)' : '';
    return 'AuthServiceException: $message$suffix';
  }
}
