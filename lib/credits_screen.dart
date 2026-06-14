import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'credits.dart';
import 'purchase_service.dart';

// Shows this app's credit balance for the signed-in user.
// Reads app_service_credits directly — RLS returns only the user's own row.
class CreditsScreen extends StatefulWidget {
  const CreditsScreen({super.key});
  @override
  State<CreditsScreen> createState() => _CreditsScreenState();
}

class _CreditsScreenState extends State<CreditsScreen> {
  bool _loading = true;
  String? _error;
  int _balance = 0, _spent = 0, _purchased = 0;
  int? _balanceKrw;
  String? _price;

  PurchaseService get _ps => PurchaseService.instance;

  @override
  void initState() {
    super.initState();
    _load();
    _ps.successTick.addListener(_onTopUpSuccess);
    _ps.lastError.addListener(_onPurchaseError);
    _ps.loadProduct().then((p) {
      if (mounted) setState(() => _price = p?.price);
    });
  }

  @override
  void dispose() {
    _ps.successTick.removeListener(_onTopUpSuccess);
    _ps.lastError.removeListener(_onPurchaseError);
    super.dispose();
  }

  void _onTopUpSuccess() {
    if (!mounted) return;
    _load();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('충전 완료 — 크레딧이 적립되었습니다.')),
    );
  }

  void _onPurchaseError() {
    final msg = _ps.lastError.value;
    if (!mounted || msg == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red[900]),
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final c = await client
          .from('app_service_credits')
          .select(
              'balance_credits, total_purchased_credits, total_spent_credits')
          .eq('service_key', 'chat_grok')
          .maybeSingle();
      _balance = ((c?['balance_credits'] ?? 0) as num).toInt();
      _spent = ((c?['total_spent_credits'] ?? 0) as num).toInt();
      _purchased = ((c?['total_purchased_credits'] ?? 0) as num).toInt();
      creditBalance.value = _balance; // 전역 배지 동기화

      // 표시용 원화 환산(단가표 기반, RPC).
      try {
        final krw = await client.rpc('app_credits_to_krw',
            params: {'p_service': 'chat_grok', 'p_credits': _balance});
        _balanceKrw = (krw as num?)?.toInt();
      } catch (_) {
        _balanceKrw = null;
      }

      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('크레딧'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('불러오기 실패: $_error',
                        textAlign: TextAlign.center),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    _balanceCard(),
                    const SizedBox(height: 12),
                    _card('사용', _spent),
                    const SizedBox(height: 12),
                    _card('충전', _purchased),
                    const SizedBox(height: 24),
                    ValueListenableBuilder<bool>(
                      valueListenable: _ps.busy,
                      builder: (_, busy, _) => SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: busy ? null : () => _ps.buy(),
                          icon: busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.add_card),
                          label: Text(busy
                              ? '진행 중…'
                              : '크레딧 충전하기${_price != null ? ' ($_price)' : ''}'),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF6C8CFF),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '첫 사용 시 체험 크레딧이 지급됩니다. 메시지 1건당 실제 사용량에 따라 '
                      '크레딧이 차감됩니다. 충전은 Google Play 인앱결제(credit_5000: 5,000원 → '
                      '5,000 크레딧)로 처리되며, 서버에서 결제를 검증한 뒤 적립됩니다.',
                      style: TextStyle(fontSize: 12, color: Colors.white60),
                    ),
                  ],
                ),
    );
  }

  Widget _balanceCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161922),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A2F3D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('남은 크레딧',
              style: TextStyle(color: Color(0xFF9AA3B2), fontSize: 14)),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(formatCredits(_balance),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 30,
                      color: Color(0xFF6C8CFF))),
              const SizedBox(width: 6),
              const Text('크레딧',
                  style: TextStyle(color: Color(0xFF9AA3B2), fontSize: 14)),
              const Spacer(),
              if (_balanceKrw != null)
                Text('≈ ₩${formatCredits(_balanceKrw!)}',
                    style: const TextStyle(
                        color: Color(0xFF9AA3B2), fontSize: 14)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _card(String label, int credits) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161922),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A2F3D)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Color(0xFF9AA3B2), fontSize: 14)),
          Text('${formatCredits(credits)} 크레딧',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 16)),
        ],
      ),
    );
  }
}
