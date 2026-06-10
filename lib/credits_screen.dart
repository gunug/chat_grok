import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Shows this app's credit balance for the signed-in (anonymous) user.
// Reads app_service_credits directly — RLS returns only the user's own row.
class CreditsScreen extends StatefulWidget {
  const CreditsScreen({super.key});
  @override
  State<CreditsScreen> createState() => _CreditsScreenState();
}

class _CreditsScreenState extends State<CreditsScreen> {
  bool _loading = true;
  String? _error;
  double _balance = 0, _spent = 0, _purchased = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = await Supabase.instance.client
          .from('app_service_credits')
          .select('balance_micros, total_purchased_micros, total_spent_micros')
          .eq('service_key', 'chat_grok')
          .maybeSingle();
      setState(() {
        _balance = ((c?['balance_micros'] ?? 0) as num) / 1e6;
        _spent = ((c?['total_spent_micros'] ?? 0) as num) / 1e6;
        _purchased = ((c?['total_purchased_micros'] ?? 0) as num) / 1e6;
        _loading = false;
      });
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
                    _card('남은 크레딧', _balance, big: true),
                    const SizedBox(height: 12),
                    _card('사용', _spent),
                    const SizedBox(height: 12),
                    _card('충전(결제)', _purchased),
                    const SizedBox(height: 24),
                    const Text(
                      '첫 사용 시 \$0.10 체험 크레딧이 지급됩니다. '
                      '차감은 xAI 실제 원가 기준입니다. 결제(충전)는 추후 추가됩니다.',
                      style: TextStyle(fontSize: 12, color: Colors.white60),
                    ),
                  ],
                ),
    );
  }

  Widget _card(String label, double usd, {bool big = false}) {
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
          Text(
            '\$${usd.toStringAsFixed(big ? 4 : 4)}',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: big ? 26 : 16,
              color: big ? const Color(0xFF6C8CFF) : Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
