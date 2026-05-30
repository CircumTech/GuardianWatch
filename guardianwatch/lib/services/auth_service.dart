import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'api_service.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSI = GoogleSignIn();
  final ApiService _api = ApiService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  User? get currentUser => _auth.currentUser;
  bool get isLoggedIn => currentUser != null;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // ───────────────────────────────────────────────────────────────────────────
  // Create user in Auth + Firestore
  // ───────────────────────────────────────────────────────────────────────────
  Future<User?> registerWithEmail(
      String email, String password, String displayName) async {
    final UserCredential uc = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    final User? user = uc.user;
    if (user != null) {
      // Update display name in Auth
      await user.updateDisplayName(displayName);
      await user.reload();
      // Create Firestore user document
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
      // Exchange Firebase token for backend JWT
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
      // Update last login timestamp
      await _firestore.collection('users').doc(user.uid).update({
        'lastLoginAt': FieldValue.serverTimestamp(),
      });
      // Exchange token for backend JWT
      final idToken = await user.getIdToken();
      if (idToken != null) await _api.exchangeToken(idToken);
    }
    return user;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Google Sign‑In + Firestore upsert
  // ───────────────────────────────────────────────────────────────────────────
  Future<User?> signInWithGoogle() async {
    final GoogleSignInAccount? googleUser = await _googleSI.signIn();
    if (googleUser == null) return null;
    final GoogleSignInAuthentication googleAuth =
        await googleUser.authentication;
    final AuthCredential credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    final UserCredential uc = await _auth.signInWithCredential(credential);
    final User? user = uc.user;
    if (user != null) {
      // Upsert Firestore document
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
        await userRef.update({
          'lastLoginAt': FieldValue.serverTimestamp(),
        });
      }
      // Exchange token
      final idToken = await user.getIdToken();
      if (idToken != null) await _api.exchangeToken(idToken);
    }
    return user;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Password reset – handled entirely by Firebase Auth
  // ───────────────────────────────────────────────────────────────────────────
  Future<void> sendPasswordResetEmail(String email) async {
    await _auth.sendPasswordResetEmail(email: email);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Update user profile (display name, photo) – updates both Auth and Firestore
  // ───────────────────────────────────────────────────────────────────────────
  Future<void> updateUserProfile(
      {String? displayName, String? photoURL}) async {
    final User? user = _auth.currentUser;
    if (user == null) return;
    if (displayName != null) await user.updateDisplayName(displayName);
    if (photoURL != null) await user.updatePhotoURL(photoURL);
    await user.reload();
    // Sync to Firestore
    final Map<String, dynamic> updates = {};
    if (displayName != null) updates['displayName'] = displayName;
    if (photoURL != null) updates['photoURL'] = photoURL;
    if (updates.isNotEmpty) {
      await _firestore.collection('users').doc(user.uid).update(updates);
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Delete account – remove from Auth + Firestore
  // ───────────────────────────────────────────────────────────────────────────
  Future<void> deleteAccount() async {
    final User? user = _auth.currentUser;
    if (user == null) return;
    // Delete Firestore document (and optionally its subcollections)
    await _firestore.collection('users').doc(user.uid).delete();
    // Delete the Auth user
    await user.delete();
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Sign out
  // ───────────────────────────────────────────────────────────────────────────
  Future<void> signOut() async {
    await _googleSI.signOut();
    await _auth.signOut();
    await _api.clearSession();
  }
}
