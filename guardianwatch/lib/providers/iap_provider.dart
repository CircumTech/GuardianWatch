// ════════════════════════════════════════════════════════════════════════════
// lib/providers/iap_provider.dart
// ════════════════════════════════════════════════════════════════════════════
//
// IAPProvider — paywall and premium entitlement state.
//
// Responsibilities:
//   Load and cache the store's available products
//   Initiate monthly / annual subscription purchases
//   Restore previous purchases
//   Open the platform subscription management page
//   Refresh entitlement from the backend on app resume
//   Expose premium state to the widget tree
//
// Design rules:
//   Uses a single IAPService shared with InsightProvider. Pass the
//    same instance at the app root.
//   All purchases go through IAPService. The service is the source of
//     truth for entitlement state.
//   Widgets listen to this provider for isPremium / entitlement.
//   Loading and error state is per-operation.
//   Refresh entitlement from the backend on AppLifecycleState.resumed
//     so expirations and renewals surface without a manual refresh.
//   All notifyListeners() paths are guarded by _disposed.
//

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../config/constants.dart';
import '../services/iap_service.dart';

// ════════════════════════════════════════════════════════════════════════════
// Plan helper
// ════════════════════════════════════════════════════════════════════════════

enum PremiumPlan { monthly, annual, unknown }

PremiumPlan planForProduct(String? productId) {
  if (productId == AppConstants.premiumMonthlyId) return PremiumPlan.monthly;
  if (productId == AppConstants.premiumAnnualId) return PremiumPlan.annual;
  return PremiumPlan.unknown;
}

// ════════════════════════════════════════════════════════════════════════════
// Error wrapper
// ════════════════════════════════════════════════════════════════════════════

/// User-facing error surfaced by the provider.
///
/// Only ever contains safe, displayable text. The underlying cause is
/// retained for logging.
class IAPProviderError {
  final String message;
  final Object? cause;

  const IAPProviderError(this.message, {this.cause});

  @override
  String toString() => 'IAPProviderError: $message';
}

// ════════════════════════════════════════════════════════════════════════════
// Provider
// ════════════════════════════════════════════════════════════════════════════

class IAPProvider extends ChangeNotifier with WidgetsBindingObserver {
  IAPProvider({required IAPService service, bool observeLifecycle = true})
    : _iap = service,
      _observeLifecycle = observeLifecycle {
    if (_observeLifecycle) {
      WidgetsBinding.instance.addObserver(this);
    }
    _initialize();
  }

  final IAPService _iap;
  final bool _observeLifecycle;

  // ── State ─────────────────────────────────────────────────────────────────

  List<ProductDetails> _products = <ProductDetails>[];
  String? _selectedProductId;

  bool _loadingProducts = false;
  bool _purchasing = false;
  bool _restoring = false;

  IAPProviderError? _error;

  bool _initialized = false;
  bool _disposed = false;

  final Completer<void> _readyCompleter = Completer<void>();

  // ── Subscriptions ─────────────────────────────────────────────────────────

  StreamSubscription<PremiumEntitlement>? _entitlementSubscription;

  // ══════════════════════════════════════════════════════════════════════════
  // Public state
  // ══════════════════════════════════════════════════════════════════════════

  bool get isPremium => _iap.isPremium;
  PremiumStatus get status => _iap.status;
  PremiumEntitlement get entitlement => _iap.entitlement;
  bool get isStoreAvailable => _iap.isStoreAvailable;

  List<ProductDetails> get products => List.unmodifiable(_products);
  bool get hasProducts => _products.isNotEmpty;

  String? get selectedProductId => _selectedProductId;

  ProductDetails? get selectedProduct {
    final id = _selectedProductId;
    if (id == null) return null;
    for (final product in _products) {
      if (product.id == id) return product;
    }
    return null;
  }

  PremiumPlan get selectedPlan => planForProduct(_selectedProductId);

  bool get isLoadingProducts => _loadingProducts;
  bool get isPurchasing => _purchasing;
  bool get isRestoring => _restoring;
  bool get isBusy => _loadingProducts || _purchasing || _restoring;

  IAPProviderError? get error => _error;
  bool get hasError => _error != null;

  bool get isInitialized => _initialized;
  bool get isReady => _initialized;

  /// Awaits the first product fetch attempt.
  Future<void> waitUntilReady() => _readyCompleter.future;

  // ══════════════════════════════════════════════════════════════════════════
  // Initialization
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _initialize() async {
    if (_initialized) return;

    try {
      // Ensure the underlying service is initialized. Safe to call
      // multiple times.
      await _iap.init();
    } catch (e, stack) {
      debugPrint('Guardian IAP service init failed: $e');
      debugPrintStack(stackTrace: stack);
    }

    // Listen to entitlement changes so the widget tree rebuilds.
    _entitlementSubscription = _iap.entitlementStream.listen(
      (_) {
        _safeNotify();
      },
      onError: (Object error, StackTrace stack) {
        debugPrint('Guardian IAP entitlement stream error: $error');
        debugPrintStack(stackTrace: stack);
      },
    );

    // Kick off the first product load in the background.
    unawaited(refreshProducts());

    _initialized = true;
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
    _safeNotify();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Product loading
  // ══════════════════════════════════════════════════════════════════════════

  /// Fetches products from the store.
  ///
  /// Safe to call repeatedly. Concurrent calls are deduplicated by the
  /// loading flag.
  Future<void> refreshProducts() async {
    if (_disposed || _loadingProducts) return;

    if (!_iap.isStoreAvailable) {
      _error = const IAPProviderError(
        'Billing is not available on this device.',
      );
      _safeNotify();
      return;
    }

    _loadingProducts = true;
    _error = null;
    _safeNotify();

    try {
      final fetched = await _iap.fetchProducts();
      if (_disposed) return;

      // Sort: annual first, then monthly. Unknown products at the end.
      _products = List<ProductDetails>.from(fetched)
        ..sort((a, b) {
          final aRank = _rankProduct(a.id);
          final bRank = _rankProduct(b.id);
          return aRank.compareTo(bRank);
        });

      // Auto-select the annual plan if the user hasn't picked one yet.
      if (_selectedProductId == null && _products.isNotEmpty) {
        _selectedProductId = _products.first.id;
      } else if (_selectedProductId != null &&
          !_products.any((p) => p.id == _selectedProductId)) {
        // The previously selected product is no longer available.
        _selectedProductId = _products.isEmpty ? null : _products.first.id;
      }
    } catch (e, stack) {
      debugPrint('Guardian IAP product fetch failed: $e');
      debugPrintStack(stackTrace: stack);
      if (!_disposed) _error = _friendlyError(e);
    } finally {
      if (!_disposed) {
        _loadingProducts = false;
        _safeNotify();
      }
    }
  }

  static int _rankProduct(String id) {
    switch (planForProduct(id)) {
      case PremiumPlan.annual:
        return 0;
      case PremiumPlan.monthly:
        return 1;
      case PremiumPlan.unknown:
        return 2;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Selection
  // ══════════════════════════════════════════════════════════════════════════

  void selectProduct(String productId) {
    if (_disposed) return;
    if (_selectedProductId == productId) return;
    if (!_products.any((p) => p.id == productId)) return;

    _selectedProductId = productId;
    _safeNotify();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Purchase
  // ══════════════════════════════════════════════════════════════════════════

  /// Initiates a purchase of the currently selected product.
  Future<bool> purchaseSelected() async {
    final id = _selectedProductId;
    if (id == null) {
      _error = const IAPProviderError(
        'Please select a plan before continuing.',
      );
      _safeNotify();
      return false;
    }
    return purchase(id);
  }

  /// Initiates a purchase of a specific product.
  ///
  /// Returns true when the store flow was successfully started. The final
  /// entitlement is delivered asynchronously through the entitlement
  /// stream — callers should watch `isPremium` or `entitlement` for the
  /// outcome.
  Future<bool> purchase(String productId) async {
    if (_disposed) return false;

    if (_purchasing) {
      _error = const IAPProviderError('A purchase is already being processed.');
      _safeNotify();
      return false;
    }

    ProductDetails? product;
    for (final p in _products) {
      if (p.id == productId) {
        product = p;
        break;
      }
    }

    if (product == null) {
      _error = const IAPProviderError(
        'The selected plan is unavailable. Please try again.',
      );
      _safeNotify();
      return false;
    }

    _purchasing = true;
    _error = null;
    _safeNotify();

    try {
      final initiated = await _iap.purchase(product);
      if (_disposed) return false;

      if (!initiated) {
        _error = const IAPProviderError(
          'The purchase could not be started. Please try again.',
        );
      }

      return initiated;
    } catch (e, stack) {
      debugPrint('Guardian IAP purchase failed: $e');
      debugPrintStack(stackTrace: stack);
      if (!_disposed) _error = _friendlyError(e);
      return false;
    } finally {
      if (!_disposed) {
        _purchasing = false;
        _safeNotify();
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Restore
  // ══════════════════════════════════════════════════════════════════════════

  /// Restores previous purchases.
  ///
  /// Resolves once the store has replayed restored transactions or the
  /// internal timeout elapses.
  Future<bool> restorePurchases() async {
    if (_disposed) return false;

    if (_restoring) {
      return isPremium;
    }

    _restoring = true;
    _error = null;
    _safeNotify();

    try {
      final restored = await _iap.restorePurchases();
      if (_disposed) return false;

      if (!restored && !isPremium) {
        _error = const IAPProviderError(
          'No active subscription was found for this account.',
        );
      }

      return restored;
    } catch (e, stack) {
      debugPrint('Guardian IAP restore failed: $e');
      debugPrintStack(stackTrace: stack);
      if (!_disposed) _error = _friendlyError(e);
      return false;
    } finally {
      if (!_disposed) {
        _restoring = false;
        _safeNotify();
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Subscription management
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> openManageSubscriptions() async {
    if (_disposed) return;

    _error = null;
    _safeNotify();

    try {
      await _iap.openManageSubscriptions();
    } catch (e, stack) {
      debugPrint('Guardian IAP manage subscriptions failed: $e');
      debugPrintStack(stackTrace: stack);
      if (!_disposed) {
        _error = _friendlyError(e);
        _safeNotify();
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Entitlement refresh
  // ══════════════════════════════════════════════════════════════════════════

  /// Refreshes entitlement state from the backend.
  ///
  /// Call on app resume (handled automatically when observeLifecycle is
  /// true) or after a manual "refresh" tap.
  Future<void> refreshEntitlement() async {
    if (_disposed) return;
    try {
      await _iap.refreshEntitlement();
    } catch (e, stack) {
      debugPrint('Guardian entitlement refresh failed: $e');
      debugPrintStack(stackTrace: stack);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Error handling
  // ══════════════════════════════════════════════════════════════════════════

  void clearError() {
    if (_error == null) return;
    _error = null;
    _safeNotify();
  }

  IAPProviderError _friendlyError(Object error) {
    if (error is IAPException) {
      final msg = error.message;

      if (msg.contains('unavailable') || msg.contains('not available')) {
        return IAPProviderError(
          'Billing is temporarily unavailable. Please try again later.',
          cause: error,
        );
      }
      if (msg.contains('already being processed')) {
        return IAPProviderError(
          'A purchase is already being processed.',
          cause: error,
        );
      }
      if (msg.contains('Unable to open subscription management')) {
        return IAPProviderError(
          'Could not open subscription management.',
          cause: error,
        );
      }

      return IAPProviderError(msg, cause: error);
    }

    return IAPProviderError(
      'Something went wrong. Please try again.',
      cause: error,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Lifecycle
  // ══════════════════════════════════════════════════════════════════════════

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state != AppLifecycleState.resumed) return;

    // Auto-renewals, expirations, refunds and family-sharing revocations
    // happen while the app is backgrounded. Reconcile with the backend
    // every time the app resumes.
    unawaited(refreshEntitlement());
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Notify guard
  // ══════════════════════════════════════════════════════════════════════════

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Dispose
  // ══════════════════════════════════════════════════════════════════════════

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    if (_observeLifecycle) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (e) {
        debugPrint('Guardian IAP observer removal failed: $e');
      }
    }

    _entitlementSubscription?.cancel();
    _entitlementSubscription = null;

    // Do NOT dispose the IAPService — it is shared with InsightProvider.

    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }

    super.dispose();
  }
}
