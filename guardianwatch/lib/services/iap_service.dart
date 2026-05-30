// ─── lib/services/iap_service.dart ───────────────────────────────────────────

import 'dart:async';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
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

  Future<void> init() async {
    if (!await _iap.isAvailable()) return;
    _sub = _iap.purchaseStream.listen(_onPurchaseUpdate);
    await _iap.restorePurchases();
  }

  Future<List<ProductDetails>> fetchProducts() async {
    final ids = {AppConstants.premiumMonthlyId, AppConstants.premiumAnnualId};
    final res = await _iap.queryProductDetails(ids);
    return res.productDetails;
  }

  /// Purchase a product (returns bool success)
  Future<bool> purchase(ProductDetails product) async {
    final param = PurchaseParam(productDetails: product);
    final result = await _iap.buyNonConsumable(purchaseParam: param);
    // Result is handled in stream; return true as optimistic feedback
    return result;
  }

  /// Restore previous purchases
  Future<bool> restorePurchases() async {
    await _iap.restorePurchases();
    await Future.delayed(const Duration(seconds: 1));
    return _premium;
  }

  Future<void> openManageSubscriptions() async {
    // For iOS: App Store subscription settings
    // For Android: Google Play subscriptions
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

  // Legacy subscribe method
  Future<bool> subscribe(ProductDetails product) async => purchase(product);

  void _onPurchaseUpdate(List<PurchaseDetails> purchases) {
    for (final p in purchases) {
      if (p.status == PurchaseStatus.purchased ||
          p.status == PurchaseStatus.restored) {
        if (p.productID == AppConstants.premiumMonthlyId ||
            p.productID == AppConstants.premiumAnnualId) {
          _setPremium(true);
          _api.verifyReceipt(
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

  void _setPremium(bool val) {
    _premium = val;
    _premiumController.add(val);
  }

  void dispose() {
    _sub?.cancel();
    _premiumController.close();
  }
}
