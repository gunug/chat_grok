// Global credit balance shared across all screens + a reusable badge widget.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'credits_screen.dart';

// 전역 크레딧 잔액(USD). null = 아직 모름/로딩.
final ValueNotifier<double?> creditBalance = ValueNotifier<double?>(null);

/// 서버에서 권위 잔액을 다시 읽어 전역값 갱신(실패 시 기존값 유지).
Future<void> refreshCredit() async {
  try {
    final c = await Supabase.instance.client
        .from('app_service_credits')
        .select('balance_micros')
        .eq('service_key', 'chat_grok')
        .maybeSingle();
    creditBalance.value = ((c?['balance_micros'] ?? 0) as num) / 1e6;
  } catch (_) {
    // 네트워크 오류 등은 무시(이전 표시 유지).
  }
}

/// usage 이벤트의 balanceMicros로 즉시(낙관적) 갱신.
void setBalanceMicros(num micros) {
  creditBalance.value = micros / 1e6;
}

/// AppBar actions 등에 넣는 크레딧 칩. 탭하면 크레딧 화면으로 이동.
class CreditBadge extends StatelessWidget {
  final bool tappable;
  const CreditBadge({super.key, this.tappable = true});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ValueListenableBuilder<double?>(
        valueListenable: creditBalance,
        builder: (_, v, _) {
          final text = v == null ? '…' : '\$${v.toStringAsFixed(4)}';
          final chip = Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFF1E222E),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0xFF2A2F3D)),
            ),
            child: Text('💳 $text',
                style: const TextStyle(
                    fontSize: 12, color: Color(0xFF9AA3B2))),
          );
          if (!tappable) return chip;
          return InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CreditsScreen()),
            ),
            child: chip,
          );
        },
      ),
    );
  }
}
