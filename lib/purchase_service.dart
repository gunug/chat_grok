import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'credits.dart';
import 'debug_log.dart';

/// Google Play in-app purchase of credit packs. Each purchase is verified
/// server-side by the `purchase-verify` Edge Function, which grants the credits
/// (idempotent). The app never grants credits itself.
class PurchaseService {
  PurchaseService._();
  static final PurchaseService instance = PurchaseService._();

  /// The one-time credit pack product (Play Console: 5,000원 → +5,000 크레딧).
  static const String creditPackId = 'credit_5000';

  final InAppPurchase _iap = InAppPurchase.instance;
  bool _started = false;

  /// True while a purchase/verify is in flight.
  final ValueNotifier<bool> busy = ValueNotifier<bool>(false);

  /// Last error message (null when none).
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  /// Increments each time a top-up succeeds (UI can react: refresh + snack).
  final ValueNotifier<int> successTick = ValueNotifier<int>(0);

  /// Subscribe to the purchase stream once at app start (so deliveries/pending
  /// purchases are handled even outside the top-up screen).
  void init() {
    if (_started) return;
    _started = true;
    _iap.purchaseStream.listen(
      _onPurchases,
      onError: (Object e) {
        logD('purchaseStream error: $e');
        lastError.value = '결제 오류: $e';
      },
    );
  }

  Future<bool> available() => _iap.isAvailable();

  /// Loads the credit pack (for showing its localized price). Null if Play has
  /// no such product / billing unavailable.
  Future<ProductDetails?> loadProduct() async {
    final resp = await _iap.queryProductDetails({creditPackId});
    if (resp.error != null) logD('queryProductDetails error: ${resp.error}');
    if (resp.notFoundIDs.isNotEmpty) {
      logD('product not found: ${resp.notFoundIDs}');
    }
    if (resp.productDetails.isEmpty) return null;
    return resp.productDetails.first;
  }

  /// Starts the buy flow. The result arrives on the purchase stream.
  Future<void> buy() async {
    lastError.value = null;
    if (!await available()) {
      lastError.value = 'Play 결제를 사용할 수 없습니다.';
      return;
    }
    final product = await loadProduct();
    if (product == null) {
      lastError.value = '상품을 불러오지 못했습니다 (Play 상품/테스터 계정 확인).';
      return;
    }
    busy.value = true;
    logD('buyConsumable: ${product.id} ${product.price}');
    // Consumable → autoConsume so it can be purchased again.
    await _iap.buyConsumable(
      purchaseParam: PurchaseParam(productDetails: product),
      autoConsume: true,
    );
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      logD('purchase: ${p.productID} status=${p.status}');
      switch (p.status) {
        case PurchaseStatus.pending:
          busy.value = true;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _verifyAndGrant(p);
          busy.value = false;
        case PurchaseStatus.error:
          logD('purchase error: ${p.error}');
          lastError.value = p.error?.message ?? '결제 실패';
          busy.value = false;
        case PurchaseStatus.canceled:
          busy.value = false;
      }
      if (p.pendingCompletePurchase) {
        await _iap.completePurchase(p);
      }
    }
  }

  Future<void> _verifyAndGrant(PurchaseDetails p) async {
    try {
      final token = p.verificationData.serverVerificationData;
      logD('verify: ${p.productID} token.len=${token.length}');
      final res = await Supabase.instance.client.functions.invoke(
        'purchase-verify',
        body: {'productId': p.productID, 'purchaseToken': token},
      );
      final data = res.data;
      if (data is Map && data['ok'] == true) {
        final bal = (data['balanceCredits'] as num?)?.toInt();
        if (bal != null) creditBalance.value = bal;
        logD('verify ok: balance=$bal');
        successTick.value++;
      } else {
        logD('verify failed: $data');
        lastError.value = '결제 검증 실패: ${data is Map ? data['error'] : data}';
      }
    } catch (e) {
      logD('verify exception: $e');
      lastError.value = '검증 오류: $e';
    }
  }
}
