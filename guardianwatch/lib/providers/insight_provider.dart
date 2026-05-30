// ─── lib/providers/insight_provider.dart ─────────────────────────────────────

import 'package:flutter/foundation.dart';
import '../models/insight.dart';
import '../services/api_service.dart';
import '../services/iap_service.dart';

class InsightProvider extends ChangeNotifier {
  final ApiService _api = ApiService();
  final IAPService _iap;

  List<Insight> _insights = [];
  bool _loading = false;
  bool _generating = false;
  String? _error;

  InsightProvider(this._iap) {
    _iap.premiumStream.listen((_) {
      // Refresh insights when premium status changes
      loadInsights();
    });
  }

  List<Insight> get insights => _insights;
  bool get isLoading => _loading;
  bool get isGenerating => _generating;
  String? get error => _error;
  bool get isPremium => _iap.isPremium;

  Future<void> loadInsights() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _insights = await _api.fetchInsights();
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> generateDailyInsights() async {
    if (_generating) return;
    _generating = true;
    _error = null;
    notifyListeners();

    try {
      // Call backend to generate insights from recent data
      final newInsights = await _api.generateInsights();
      _insights = [...newInsights, ..._insights];
      await loadInsights(); // Refresh full list
    } catch (e) {
      _error = e.toString();
    } finally {
      _generating = false;
      notifyListeners();
    }
  }

  Future<bool> purchase(String productId) async {
    try {
      final products = await _iap.fetchProducts();
      final product = products.firstWhere((p) => p.id == productId);
      final success = await _iap.purchase(product);
      if (success) await loadInsights();
      return success;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> restorePurchases() async {
    try {
      final restored = await _iap.restorePurchases();
      if (restored) await loadInsights();
      return restored;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<void> openManageSubscriptions() async {
    await _iap.openManageSubscriptions();
  }
}