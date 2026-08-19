import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'api_service.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSI = GoogleSignIn.instance;
  final ApiService _api = ApiService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  bool _isGoogleSignInInitialized = false;

  User? get currentUser => _auth.currentUser;
  bool get isLoggedIn => currentUser != null;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // ───────────────────────────────────────────────────────────────────────────
  // Initialize Google Sign-In 7.2.0 (Call during app startup or before auth)
  // ───────────────────────────────────────────────────────────────────────────
  Future<void> initGoogleSignIn({
    String? clientId,
    String? serverClientId,
  }) async {
    if (_isGoogleSignInInitialized) return;

    await _googleSI.initialize(
      clientId: clientId,
      serverClientId: serverClientId,
    );

    // Attempt background session restoration
    await _googleSI.attemptLightweightAuthentication();
    _isGoogleSignInInitialized = true;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Create user in Auth + Firestore
  // ───────────────────────────────────────────────────────────────────────────
  Future<User?> registerWithEmail(
    String email,
    String password,
    String displayName,
  ) async {
    final UserCredential uc = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    final User? user = uc.user;
    if (user != null) {
      await user.updateDisplayName(displayName);
      await user.reload();
      await _firestore.collection('users').doc(user.uid).set({
        'uid': user.uid,
        'email': email,
        'displayName': displayName,
        'photoURL': null,
        'createdAt': FieldValue.serverTimestamp(),
        'lastLoginAt': FieldValue.serverTimestamp(),
        'premium': false,
        'settings': {},
      });
      final idToken = await user.getIdToken();
      if (idToken != null) await _api.exchangeToken(idToken);
    }
    return user;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Sign in with email/password + update lastLoginAt in Firestore
  // ───────────────────────────────────────────────────────────────────────────
  Future<User?> signInWithEmail(String email, String password) async {
    final UserCredential uc = await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    final User? user = uc.user;
    if (user != null) {
      await _firestore.collection('users').doc(user.uid).update({
        'lastLoginAt': FieldValue.serverTimestamp(),
      });
      final idToken = await user.getIdToken();
      if (idToken != null) await _api.exchangeToken(idToken);
    }
    return user;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Google Sign‑In + Firestore upsert (Updated for google_sign_in 7.2.0)
  // ───────────────────────────────────────────────────────────────────────────
  Future<User?> signInWithGoogle({
    String? clientId,
    String? serverClientId,
  }) async {
    try {
      // 1. Ensure initialization has occurred
      if (!_isGoogleSignInInitialized) {
        await initGoogleSignIn(
          clientId: clientId,
          serverClientId: serverClientId,
        );
      }

      // 2. Verify platform supports explicit authentication step
      if (!_googleSI.supportsAuthenticate()) {
        throw Exception('Platform does not support direct authenticate()');
      }

      // 3. Trigger interactive sign-in flow
      final GoogleSignInAccount? googleUser = await _googleSI.authenticate();
      if (googleUser == null) return null;

      // 4. Retrieve ID token from authentication payload
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      final OAuthCredential credential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );

      // 5. Authenticate with Firebase
      final UserCredential uc = await _auth.signInWithCredential(credential);
      final User? user = uc.user;

      if (user != null) {
        final userRef = _firestore.collection('users').doc(user.uid);
        final doc = await userRef.get();

        if (!doc.exists) {
          await userRef.set({
            'uid': user.uid,
            'email': user.email,
            'displayName': user.displayName ?? '',
            'photoURL': user.photoURL,
            'createdAt': FieldValue.serverTimestamp(),
            'lastLoginAt': FieldValue.serverTimestamp(),
            'premium': false,
            'settings': {},
          });
        } else {
          await userRef.update({'lastLoginAt': FieldValue.serverTimestamp()});
        }

        final idToken = await user.getIdToken();
        if (idToken != null) await _api.exchangeToken(idToken);
      }
      return user;
    } catch (e) {
      return null;
    }
  }

  Future<void> sendPasswordResetEmail(String email) async {
    await _auth.sendPasswordResetEmail(email: email);
  }

  Future<void> updateUserProfile({
    String? displayName,
    String? photoURL,
  }) async {
    final User? user = _auth.currentUser;
    if (user == null) return;
    if (displayName != null) await user.updateDisplayName(displayName);
    if (photoURL != null) await user.updatePhotoURL(photoURL);
    await user.reload();

    final Map<String, dynamic> updates = {};
    if (displayName != null) updates['displayName'] = displayName;
    if (photoURL != null) updates['photoURL'] = photoURL;
    if (updates.isNotEmpty) {
      await _firestore.collection('users').doc(user.uid).update(updates);
    }
  }

  Future<void> deleteAccount() async {
    final User? user = _auth.currentUser;
    if (user == null) return;
    await _firestore.collection('users').doc(user.uid).delete();
    await user.delete();
  }

  Future<void> signOut() async {
    await _googleSI.disconnect();
    await _auth.signOut();
    await _api.clearSession();
  }
}
