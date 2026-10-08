// ════════════════════════════════════════════════════════════════════════════
// lib/services/iap_service.dart
// ════════════════════════════════════════════════════════════════════════════
//
// Guardian Watch In-App Purchase / Premium Entitlement Service.
//
// Responsibilities:
//   Initialize App Store / Google Play billing
//   Load cached entitlement for fast startup
//   Query Guardian premium products
//   Start monthly / annual subscriptions
//   Listen to asynchronous purchase updates
//   Verify transactions with Guardian backend
//   Maintain premium entitlement state
//   Restore previous purchases
//   Refresh entitlement on app resume
//   Open native subscription-management pages
//
// IMPORTANT:
// The local premium cache is NOT the authoritative source of entitlement.
// The backend (/subscription/verify and /subscription/status) determines
// whether Guardian Premium is active, including expiration, refund, and
// renewal state.
//
// Supported products:
//   guardianwrist_premium_monthly
//   guardianwrist_premium_annual
// ════════════════════════════════════════════════════════════════════════════

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/constants.dart';
import 'api_service.dart';

// ════════════════════════════════════════════════════════════════════════════
// Premium status
// ════════════════════════════════════════════════════════════════════════════

enum PremiumStatus {
  unknown,
  inactive,
  pending,
  active,
  gracePeriod,
  expired,
  error,
}

// ════════════════════════════════════════════════════════════════════════════
// Premium entitlement
// ════════════════════════════════════════════════════════════════════════════

class PremiumEntitlement {
  final PremiumStatus status;
  final String? productId;
  final String? platform;
  final DateTime? expiresAt;

  /// When the entitlement was last confirmed against the backend.
  final DateTime? lastVerifiedAt;

  /// Human-readable explanation. Never platform-specific raw errors.
  final String? message;

  const PremiumEntitlement({
    required this.status,
    this.productId,
    this.platform,
    this.expiresAt,
    this.lastVerifiedAt,
    this.message,
  });

  bool get isActive =>
      status == PremiumStatus.active || status == PremiumStatus.gracePeriod;
  bool get isPending => status == PremiumStatus.pending;
  bool get isExpired => status == PremiumStatus.expired;

  PremiumEntitlement copyWith({
    PremiumStatus? status,
    String? productId,
    String? platform,
    DateTime? expiresAt,
    DateTime? lastVerifiedAt,
    String? message,
    bool clearExpiry = false,
    bool clearProductId = false,
  }) {
    return PremiumEntitlement(
      status: status ?? this.status,
      productId: clearProductId ? null : productId ?? this.productId,
      platform: platform ?? this.platform,
      expiresAt: clearExpiry ? null : expiresAt ?? this.expiresAt,
      lastVerifiedAt: lastVerifiedAt ?? this.lastVerifiedAt,
      message: message ?? this.message,
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// IAP exception
// ════════════════════════════════════════════════════════════════════════════

class IAPException implements Exception {
  final String message;
  final Object? cause;

  const IAPException(this.message, {this.cause});

  @override
  String toString() => 'IAPException: $message';
}

// ════════════════════════════════════════════════════════════════════════════
// IAP Service
// ════════════════════════════════════════════════════════════════════════════

class IAPService {
  IAPService({InAppPurchase? iap, ApiService? api})
    : _iap = iap ?? InAppPurchase.instance,
      _api = api ?? ApiService.shared;

  final InAppPurchase _iap;
  final ApiService _api;

  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;

  final StreamController<bool> _premiumController =
      StreamController<bool>.broadcast();
  final StreamController<PremiumEntitlement> _entitlementController =
      StreamController<PremiumEntitlement>.broadcast();

  bool _initializing = false;
  bool _initialized = false;
  bool _storeAvailable = false;
  bool _disposed = false;

  PremiumEntitlement _entitlement = const PremiumEntitlement(
    status: PremiumStatus.unknown,
  );

  // Cache keys — these map 1:1 to AppConstants and no longer collide with
  // device-verification keys.
  static const String _cachedPremiumKey = AppConstants.keyPremiumActive;
  static const String _cachedProductKey = AppConstants.keyPremiumProduct;
  static const String _cachedExpiryKey = AppConstants.keyPremiumExpiry;
  static const String _cachedVerifiedKey = AppConstants.keyPremiumVerified;

  // ══════════════════════════════════════════════════════════════════════════
  // Public state
  // ══════════════════════════════════════════════════════════════════════════

  bool get isPremium => _entitlement.isActive;
  bool get isStoreAvailable => _storeAvailable;
  bool get isInitialized => _initialized;
  PremiumStatus get status => _entitlement.status;
  PremiumEntitlement get entitlement => _entitlement;

  Stream<bool> get premiumStream => _premiumController.stream;
  Stream<PremiumEntitlement> get entitlementStream =>
      _entitlementController.stream;

  // ══════════════════════════════════════════════════════════════════════════
  // Product IDs
  // ══════════════════════════════════════════════════════════════════════════

  Set<String> get productIds => <String>{
    AppConstants.premiumMonthlyId,
    AppConstants.premiumAnnualId,
  };

  bool isPremiumProduct(String productId) => productIds.contains(productId);

  // ══════════════════════════════════════════════════════════════════════════
  // Initialize
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> init() async {
    if (_initialized || _disposed) return;
    if (_initializing) {
      while (_initializing && !_disposed) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return;
    }

    _initializing = true;

    try {
      await _loadCachedEntitlement();

      _storeAvailable = await _iap.isAvailable();

      if (!_storeAvailable) {
        debugPrint('Guardian IAP store is unavailable.');

        if (!_entitlement.isActive) {
          _setEntitlement(
            const PremiumEntitlement(
              status: PremiumStatus.inactive,
              message: 'Store billing is currently unavailable.',
            ),
          );
        }

        return;
      }

      // Attach purchase stream BEFORE restorePurchases so no events are lost.
      await _purchaseSubscription?.cancel();
      _purchaseSubscription = _iap.purchaseStream.listen(
        _onPurchaseUpdate,
        onError: (Object error, StackTrace stack) {
          debugPrint('Guardian purchase stream error: $error');
          debugPrintStack(stackTrace: stack);
          _setEntitlement(
            PremiumEntitlement(
              status: PremiumStatus.error,
              platform: _platformName(),
              message:
                  'Premium purchase processing encountered an error. '
                  'Please try again later.',
            ),
          );
        },
      );

      _initialized = true;

      // Ask the store to replay any unfinished transactions.
      // This does not surface a user prompt; it re-delivers incomplete
      // transactions from the current account.
      try {
        await _iap.restorePurchases();
      } catch (e, stack) {
        debugPrint('Guardian purchase restoration failed: $e');
        debugPrintStack(stackTrace: stack);
      }

      // Refresh entitlement against the backend on every cold start.
      unawaited(refreshEntitlement());
    } catch (e, stack) {
      debugPrint('Guardian IAP initialization failed: $e');
      debugPrintStack(stackTrace: stack);

      _setEntitlement(
        PremiumEntitlement(
          status: PremiumStatus.error,
          platform: _platformName(),
          message: 'Premium billing could not be initialized.',
        ),
      );
    } finally {
      _initializing = false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Refresh entitlement from backend
  //
  // Call this on app resume (and any time the user returns to the premium
  // screen). It re-checks the authoritative backend state so expirations,
  // renewals, refunds, and family-sharing revocations are detected even if
  // no purchase event was delivered to the device.
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> refreshEntitlement() async {
    if (_disposed) return;

    try {
      final status = await _api.fetchSubscriptionStatus();

      if (!status.valid && !status.active) {
        _setEntitlement(
          PremiumEntitlement(
            status:
                status.expiresAt != null &&
                    status.expiresAt!.isBefore(DateTime.now())
                ? PremiumStatus.expired
                : PremiumStatus.inactive,
            productId: status.productId ?? _entitlement.productId,
            platform: status.platform ?? _platformName(),
            expiresAt: status.expiresAt,
            lastVerifiedAt: DateTime.now(),
            message: status.message ?? 'Guardian Premium is not active.',
          ),
        );
        return;
      }

      // Backend says the entitlement is active. Distinguish grace period
      // when the backend explicitly signals it via message text is not
      // ideal — prefer a dedicated field on the response. Until then,
      // status.active == true is authoritative.
      _setEntitlement(
        PremiumEntitlement(
          status: PremiumStatus.active,
          productId: status.productId ?? _entitlement.productId,
          platform: status.platform ?? _platformName(),
          expiresAt: status.expiresAt,
          lastVerifiedAt: DateTime.now(),
          message: 'Guardian Premium is active.',
        ),
      );
    } catch (e) {
      debugPrint('Guardian entitlement refresh failed: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Load cached entitlement
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _loadCachedEntitlement() async {
    final prefs = await SharedPreferences.getInstance();

    final cachedPremium = prefs.getBool(_cachedPremiumKey) ?? false;
    final cachedProduct = prefs.getString(_cachedProductKey);
    final cachedExpiryString = prefs.getString(_cachedExpiryKey);
    final cachedVerifiedString = prefs.getString(_cachedVerifiedKey);

    final cachedExpiry = cachedExpiryString != null
        ? DateTime.tryParse(cachedExpiryString)
        : null;
    final cachedVerifiedAt = cachedVerifiedString != null
        ? DateTime.tryParse(cachedVerifiedString)
        : null;

    if (cachedPremium && cachedExpiry != null) {
      if (cachedExpiry.isAfter(DateTime.now())) {
        _setEntitlement(
          PremiumEntitlement(
            status: PremiumStatus.active,
            productId: cachedProduct,
            platform: _platformName(),
            expiresAt: cachedExpiry,
            lastVerifiedAt: cachedVerifiedAt,
            message: 'Using cached premium status while verifying entitlement.',
          ),
        );
      } else {
        // Cached subscription has expired. Mark it as such and keep the
        // expiry so renewal detection still works.
        _setEntitlement(
          PremiumEntitlement(
            status: PremiumStatus.expired,
            productId: cachedProduct,
            platform: _platformName(),
            expiresAt: cachedExpiry,
            lastVerifiedAt: cachedVerifiedAt,
            message: 'Guardian Premium has expired.',
          ),
        );
      }
      return;
    }

    if (cachedPremium && cachedExpiry == null) {
      // Legacy cached value without expiry — require verification.
      _setEntitlement(
        const PremiumEntitlement(
          status: PremiumStatus.unknown,
          message: 'Premium status requires verification.',
        ),
      );
      return;
    }

    _setEntitlement(const PremiumEntitlement(status: PremiumStatus.inactive));
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Fetch products
  // ══════════════════════════════════════════════════════════════════════════

  Future<List<ProductDetails>> fetchProducts() async {
    if (_disposed) {
      throw const IAPException(
        'The billing service has already been disposed.',
      );
    }

    if (!_initialized) await init();
    if (!_storeAvailable) _storeAvailable = await _iap.isAvailable();

    if (!_storeAvailable) {
      throw const IAPException(
        'The App Store / Google Play billing service is unavailable.',
      );
    }

    final response = await _iap.queryProductDetails(productIds);

    if (response.error != null) {
      throw IAPException(
        'Unable to load Guardian Premium products: '
        '${response.error!.message}',
      );
    }

    if (response.productDetails.isEmpty) {
      final missing = response.notFoundIDs.join(', ');
      throw IAPException(
        missing.isEmpty
            ? 'No Guardian Premium products are currently available.'
            : 'Guardian Premium products not found: $missing',
      );
    }

    return response.productDetails;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Get one product
  // ══════════════════════════════════════════════════════════════════════════

  Future<ProductDetails> getProduct(String productId) async {
    if (!isPremiumProduct(productId)) {
      throw IAPException('Unknown Guardian Premium product: $productId');
    }

    final products = await fetchProducts();
    for (final product in products) {
      if (product.id == productId) return product;
    }

    throw IAPException(
      'Premium product $productId is not available in the current store.',
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Purchase
  // ══════════════════════════════════════════════════════════════════════════

  Future<bool> purchase(ProductDetails product) async {
    if (_disposed) {
      throw const IAPException(
        'The billing service has already been disposed.',
      );
    }

    if (!isPremiumProduct(product.id)) {
      throw IAPException('Unknown Guardian Premium product: ${product.id}');
    }

    if (!_initialized) await init();

    if (!_storeAvailable) {
      throw const IAPException('In-app purchases are currently unavailable.');
    }

    if (_entitlement.isPending) {
      throw const IAPException(
        'A premium purchase is already being processed.',
      );
    }

    _setEntitlement(
      PremiumEntitlement(
        status: PremiumStatus.pending,
        productId: product.id,
        platform: _platformName(),
        message: 'Waiting for the store to process your purchase.',
      ),
    );

    final purchaseParam = PurchaseParam(productDetails: product);

    try {
      final started = await _iap.buyNonConsumable(purchaseParam: purchaseParam);

      if (!started) {
        if (!isPremium) {
          _setEntitlement(
            PremiumEntitlement(
              status: PremiumStatus.inactive,
              productId: product.id,
              platform: _platformName(),
              message: 'The purchase flow could not be started.',
            ),
          );
        }
        return false;
      }

      return true;
    } catch (e, stack) {
      debugPrint('Guardian purchase initiation failed: $e');
      debugPrintStack(stackTrace: stack);

      if (!isPremium) {
        _setEntitlement(
          PremiumEntitlement(
            status: PremiumStatus.error,
            productId: product.id,
            platform: _platformName(),
            message: 'The premium purchase could not be started.',
          ),
        );
      }
      throw IAPException('Unable to start the premium purchase.', cause: e);
    }
  }

  Future<bool> subscribe(ProductDetails product) => purchase(product);

  // ══════════════════════════════════════════════════════════════════════════
  // Restore purchases
  // ══════════════════════════════════════════════════════════════════════════

  /// Restores any purchases the user previously made.
  ///
  Future<bool> restorePurchases({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (_disposed) {
      throw const IAPException(
        'The billing service has already been disposed.',
      );
    }

    if (!_initialized) await init();

    if (!_storeAvailable) {
      throw const IAPException(
        'The App Store / Google Play billing service is unavailable.',
      );
    }

    final completer = Completer<bool>();

    // Watch the entitlement stream for the first active result, then resolve.
    late StreamSubscription<PremiumEntitlement> sub;
    sub = entitlementStream.listen((entitlement) {
      if (entitlement.isActive && !completer.isCompleted) {
        completer.complete(true);
      }
    });

    try {
      await _iap.restorePurchases();

      // Give the stream a moment to deliver restored transactions.
      final result = await completer.future.timeout(
        timeout,
        onTimeout: () => _entitlement.isActive,
      );

      // Backend may have fresher info even if the store was silent.
      await refreshEntitlement();

      return result || _entitlement.isActive;
    } catch (e, stack) {
      debugPrint('Guardian restore failed: $e');
      debugPrintStack(stackTrace: stack);
      throw IAPException('Unable to restore purchases.', cause: e);
    } finally {
      await sub.cancel();
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Purchase stream
  // ══════════════════════════════════════════════════════════════════════════

  final Set<String> _recentlyProcessed = <String>{};

  Future<void> _onPurchaseUpdate(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      // Deduplicate by (productID + purchaseID).
      final key = '${purchase.productID}::${purchase.purchaseID ?? ''}';
      if (_recentlyProcessed.contains(key)) {
        // Still complete so the store doesn't refund on Android.
        if (purchase.pendingCompletePurchase) {
          await _completePurchaseSafely(purchase);
        }
        continue;
      }
      _recentlyProcessed.add(key);
      if (_recentlyProcessed.length > 100) {
        _recentlyProcessed.remove(_recentlyProcessed.first);
      }

      try {
        await _processPurchase(purchase);
      } catch (e, stack) {
        debugPrint('Guardian purchase processing failed: $e');
        debugPrintStack(stackTrace: stack);

        if (!isPremium) {
          _setEntitlement(
            PremiumEntitlement(
              status: PremiumStatus.error,
              productId: purchase.productID,
              platform: _platformName(),
              message:
                  'The Guardian purchase could not be verified. '
                  'If you were charged, please contact support.',
            ),
          );
        }
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Process a single purchase
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _processPurchase(PurchaseDetails purchase) async {
    // Always complete unknown products to avoid unfinished transactions.
    if (!isPremiumProduct(purchase.productID)) {
      if (purchase.pendingCompletePurchase) {
        await _completePurchaseSafely(purchase);
      }
      return;
    }

    switch (purchase.status) {
      case PurchaseStatus.pending:
        _setEntitlement(
          PremiumEntitlement(
            status: PremiumStatus.pending,
            productId: purchase.productID,
            platform: _platformName(),
            message: 'Your Guardian Premium purchase is being processed.',
          ),
        );
        break;

      case PurchaseStatus.purchased:
        await _verifyAndActivate(purchase);
        break;

      case PurchaseStatus.restored:
        // Restored transactions should be verified against the backend.
        // The receipt on a restored purchase is valid; we still verify.
        await _verifyAndActivate(purchase);
        break;

      case PurchaseStatus.canceled:
        if (!isPremium) {
          _setEntitlement(
            PremiumEntitlement(
              status: PremiumStatus.inactive,
              productId: purchase.productID,
              platform: _platformName(),
              message: 'Premium purchase cancelled.',
            ),
          );
        }
        break;

      case PurchaseStatus.error:
        if (!isPremium) {
          _setEntitlement(
            PremiumEntitlement(
              status: PremiumStatus.error,
              productId: purchase.productID,
              platform: _platformName(),
              message: _purchaseErrorMessage(purchase),
            ),
          );
        }
        break;
    }

    if (purchase.pendingCompletePurchase) {
      await _completePurchaseSafely(purchase);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Verify purchase with backend
  //
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _verifyAndActivate(PurchaseDetails purchase) async {
    final verificationData = purchase.verificationData.serverVerificationData;

    if (verificationData.isEmpty) {
      throw const IAPException(
        'The store did not provide purchase verification data.',
      );
    }

    final verification = await _api.verifySubscription(
      receipt: verificationData,
      productId: purchase.productID,
      platform: _platformName(),
    );

    if (!verification.valid || !verification.active) {
      _setEntitlement(
        PremiumEntitlement(
          status:
              verification.expiresAt != null &&
                  verification.expiresAt!.isBefore(DateTime.now())
              ? PremiumStatus.expired
              : PremiumStatus.inactive,
          productId: verification.productId ?? purchase.productID,
          platform: verification.platform ?? _platformName(),
          expiresAt: verification.expiresAt,
          lastVerifiedAt: DateTime.now(),
          message:
              verification.message ??
              'Guardian could not verify the subscription.',
        ),
      );
      return;
    }

    final now = DateTime.now();

    _setEntitlement(
      PremiumEntitlement(
        status: PremiumStatus.active,
        productId: verification.productId ?? purchase.productID,
        platform: verification.platform ?? _platformName(),
        expiresAt: verification.expiresAt,
        lastVerifiedAt: now,
        message: 'Guardian Premium is active.',
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Complete purchase
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _completePurchaseSafely(PurchaseDetails purchase) async {
    try {
      await _iap.completePurchase(purchase);
    } catch (e, stack) {
      debugPrint('Guardian purchase completion failed: $e');
      debugPrintStack(stackTrace: stack);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Subscription management
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> openManageSubscriptions() async {
    Uri? uri;

    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        // itms-apps scheme reliably opens Settings → Subscriptions.
        uri = Uri.parse('itms-apps://apps.apple.com/account/subscriptions');
        break;

      case TargetPlatform.android:
        uri = Uri.parse('https://play.google.com/store/account/subscriptions');
        break;

      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        throw const IAPException(
          'Subscription management is only available on mobile.',
        );
    }

    if (!await canLaunchUrl(uri)) {
      throw const IAPException('Unable to open subscription management.');
    }

    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Entitlement cache
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _cachePremium(
    bool value, {
    String? productId,
    DateTime? expiresAt,
    DateTime? verifiedAt,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.setBool(_cachedPremiumKey, value);

      if (productId != null) {
        await prefs.setString(_cachedProductKey, productId);
      }

      // IMPORTANT:
      // Always persist a known expiry, even when the subscription has
      // expired. Deleting the expiry prevents renewal detection.
      if (expiresAt != null) {
        await prefs.setString(
          _cachedExpiryKey,
          expiresAt.toUtc().toIso8601String(),
        );
      } else if (!value) {
        await prefs.remove(_cachedExpiryKey);
      }

      if (verifiedAt != null) {
        await prefs.setString(
          _cachedVerifiedKey,
          verifiedAt.toUtc().toIso8601String(),
        );
      } else if (!value) {
        await prefs.remove(_cachedVerifiedKey);
      }
    } catch (e, stack) {
      debugPrint('Guardian premium cache write failed: $e');
      debugPrintStack(stackTrace: stack);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Set entitlement
  // ══════════════════════════════════════════════════════════════════════════

  void _setEntitlement(PremiumEntitlement value) {
    if (_disposed) return;

    _entitlement = value;

    if (!_premiumController.isClosed) {
      _premiumController.add(value.isActive);
    }
    if (!_entitlementController.isClosed) {
      _entitlementController.add(value);
    }

    if (value.isActive ||
        value.status == PremiumStatus.inactive ||
        value.status == PremiumStatus.expired) {
      unawaited(
        _cachePremium(
          value.isActive,
          productId: value.productId,
          expiresAt: value.expiresAt,
          verifiedAt: value.lastVerifiedAt,
        ),
      );
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Utility
  // ══════════════════════════════════════════════════════════════════════════

  String _platformName() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  String _purchaseErrorMessage(PurchaseDetails purchase) {
    final message = purchase.error?.message;
    if (message == null || message.trim().isEmpty) {
      return 'The premium purchase could not be completed.';
    }

    // Do not leak raw platform error codes to the user.
    final normalized = message.trim().toLowerCase();
    if (normalized.contains('already owned') ||
        normalized.contains('item_already_owned')) {
      return 'You already own this subscription. Try Restore Purchases.';
    }
    if (normalized.contains('billing unavailable') ||
        normalized.contains('service_unavailable')) {
      return 'Billing is temporarily unavailable. Please try again.';
    }

    return 'The premium purchase could not be completed.';
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Dispose
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    await _purchaseSubscription?.cancel();
    _purchaseSubscription = null;

    if (!_premiumController.isClosed) await _premiumController.close();
    if (!_entitlementController.isClosed) await _entitlementController.close();

    _entitlement = const PremiumEntitlement(status: PremiumStatus.unknown);
  }
}
