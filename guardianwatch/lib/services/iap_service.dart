// ─── lib/services/iap_service.dart ───────────────────────────────────────────

import 'dart:async';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';  // add this
import '../config/constants.dart';
import 'api_service.dart';

class IAPService {
  final _iap = InAppPurchase.instance;
  final _api = ApiService();
  StreamSubscription<List<PurchaseDetails>>? _sub;
  bool _premium = false;
  bool get isPremium => _premium;

  final _premiumController = StreamController<bool>.broadcast();
  Stream<bool> get premiumStream => _premiumController.stream;

  // SharedPreferences key
  static const String _cachedPremiumKey = 'gw_premium_active';

  Future<void> init() async {
    if (!await _iap.isAvailable()) return;

    // Load cached premium status immediately (synchronous from SharedPreferences)
    final prefs = await SharedPreferences.getInstance();
    _premium = prefs.getBool(_cachedPremiumKey) ?? false;
    _premiumController.add(_premium);

    // Start listening to purchase updates
    _sub = _iap.purchaseStream.listen(_onPurchaseUpdate);

    // Restore purchases (this will update _premium if any active subscription is found)
    await _iap.restorePurchases();
  }

  Future<List<ProductDetails>> fetchProducts() async {
    final ids = {AppConstants.premiumMonthlyId, AppConstants.premiumAnnualId};
    final res = await _iap.queryProductDetails(ids);
    return res.productDetails;
  }

  Future<bool> purchase(ProductDetails product) async {
    final param = PurchaseParam(productDetails: product);
    final result = await _iap.buyNonConsumable(purchaseParam: param);
    return result;
  }

  Future<bool> restorePurchases() async {
    await _iap.restorePurchases();
    // Wait a moment for the purchase stream to process
    await Future.delayed(const Duration(seconds: 1));
    return _premium;
  }

  Future<void> openManageSubscriptions() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      const url = 'itms-apps://apps.apple.com/account/subscriptions';
      if (await canLaunchUrl(Uri.parse(url))) {
        await launchUrl(Uri.parse(url));
      }
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      const url = 'https://play.google.com/store/account/subscriptions';
      if (await canLaunchUrl(Uri.parse(url))) {
        await launchUrl(Uri.parse(url));
      }
    }
  }

  Future<bool> subscribe(ProductDetails product) async => purchase(product);

  void _onPurchaseUpdate(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      if (p.status == PurchaseStatus.purchased ||
          p.status == PurchaseStatus.restored) {
        if (p.productID == AppConstants.premiumMonthlyId ||
            p.productID == AppConstants.premiumAnnualId) {
          _setPremium(true);
          // Verify receipt with backend (optional, but keep as is)
          await _api.verifyReceipt(
              p.verificationData.serverVerificationData, p.productID);
        }
      }
      if (p.status == PurchaseStatus.error) {
        _setPremium(false);
      }
      if (p.pendingCompletePurchase) {
        _iap.completePurchase(p);
      }
    }
  }

  void _setPremium(bool val) async {
    if (_premium == val) return;
    _premium = val;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_cachedPremiumKey, val);
    _premiumController.add(val);
  }

  void dispose() {
    _sub?.cancel();
    _premiumController.close();
  }
}