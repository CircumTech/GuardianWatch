import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../services/auth_service.dart';

class AuthProvider extends ChangeNotifier {
  final AuthService _svc = AuthService();
  User? _user;
  bool _loading = true;
  String? _error;
  bool _isAuthenticating = false;

  User? get user => _user;
  bool get isAuthenticated => _user != null;
  bool get isLoading => _loading || _isAuthenticating;
  String? get error => _error;

  AuthProvider() {
    _svc.authStateChanges.listen((u) {
      _user = u;
      _loading = false;
      notifyListeners();
    });
  }

  void _clearError() => _error = null;

  Future<void> register(
      String email, String password, String displayName) async {
    _clearError();
    _isAuthenticating = true;
    notifyListeners();
    try {
      _user = await _svc.registerWithEmail(email, password, displayName);
    } on FirebaseAuthException catch (e) {
      _error = e.message;
    } finally {
      _isAuthenticating = false;
      notifyListeners();
    }
  }

  Future<void> signInWithEmail(String email, String password) async {
    _clearError();
    _isAuthenticating = true;
    notifyListeners();
    try {
      _user = await _svc.signInWithEmail(email, password);
    } on FirebaseAuthException catch (e) {
      _error = e.message;
    } finally {
      _isAuthenticating = false;
      notifyListeners();
    }
  }

  Future<void> signInWithGoogle() async {
    _clearError();
    _isAuthenticating = true;
    notifyListeners();
    try {
      _user = await _svc.signInWithGoogle();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isAuthenticating = false;
      notifyListeners();
    }
  }

  Future<void> sendPasswordResetEmail(String email) async {
    _clearError();
    try {
      await _svc.sendPasswordResetEmail(email);
    } catch (e) {
      _error = e.toString();
      rethrow;
    }
  }

  Future<void> updateUserProfile(
      {String? displayName, String? photoURL}) async {
    _clearError();
    try {
      await _svc.updateUserProfile(
          displayName: displayName, photoURL: photoURL);
      _user = FirebaseAuth.instance.currentUser;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      rethrow;
    }
  }

  // ✅ This is the missing method
  Future<void> sendEmailVerification() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && !user.emailVerified) {
      await user.sendEmailVerification();
      await user.reload();
      _user = FirebaseAuth.instance.currentUser;
      notifyListeners();
    }
  }

  Future<void> deleteAccount() async {
    _clearError();
    _isAuthenticating = true;
    notifyListeners();
    try {
      await _svc.deleteAccount();
      _user = null;
    } catch (e) {
      _error = e.toString();
      rethrow;
    } finally {
      _isAuthenticating = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    await _svc.signOut();
    _user = null;
    notifyListeners();
  }
}
