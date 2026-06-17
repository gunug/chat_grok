// Selectable chat models, read from the cg_models table (RLS: enabled rows).
// Single source of truth shared with the chat Edge Function (which also reads
// cg_models for validation + pricing).

import 'package:supabase_flutter/supabase_flutter.dart';

class ChatModel {
  final String id;
  final String provider; // 'openai' | 'xai'
  final String label;
  final double? inputRate; // USD / 1M input tokens (display estimate)
  final double? outputRate; // USD / 1M output tokens
  ChatModel({
    required this.id,
    required this.provider,
    required this.label,
    this.inputRate,
    this.outputRate,
  });
}

/// Fetches enabled models ordered by `sort`. Returns [] on error (UI falls back
/// to showing the stored model id).
Future<List<ChatModel>> fetchModels() async {
  try {
    final rows = await Supabase.instance.client
        .from('cg_models')
        .select('id, provider, label, sort, input_per_mtok, output_per_mtok')
        .order('sort');
    return (rows as List)
        .map((r) => ChatModel(
              id: r['id'] as String,
              provider: (r['provider'] as String?) ?? '',
              label: (r['label'] as String?) ?? r['id'] as String,
              inputRate: (r['input_per_mtok'] as num?)?.toDouble(),
              outputRate: (r['output_per_mtok'] as num?)?.toDouble(),
            ))
        .toList();
  } catch (_) {
    return [];
  }
}

/// Credits charged per 1 USD of provider cost (markup applied), via the shared
/// `app_usage_credits` RPC. Lets the picker convert USD rates → credits the
/// user actually spends. Returns null on error.
Future<double?> fetchCreditPerUsd() async {
  try {
    final v = await Supabase.instance.client.rpc('app_usage_credits',
        params: {'p_service': 'chat_grok', 'p_cost_micros': 1000000}); // $1
    return (v as num?)?.toDouble();
  } catch (_) {
    return null;
  }
}
