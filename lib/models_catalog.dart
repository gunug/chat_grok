// Selectable chat models, read from the cg_models table (RLS: enabled rows).
// Single source of truth shared with the chat Edge Function (which also reads
// cg_models for validation + pricing).

import 'package:supabase_flutter/supabase_flutter.dart';

class ChatModel {
  final String id;
  final String provider; // 'openai' | 'xai'
  final String label;
  ChatModel({required this.id, required this.provider, required this.label});
}

/// Fetches enabled models ordered by `sort`. Returns [] on error (UI falls back
/// to showing the stored model id).
Future<List<ChatModel>> fetchModels() async {
  try {
    final rows = await Supabase.instance.client
        .from('cg_models')
        .select('id, provider, label, sort')
        .order('sort');
    return (rows as List)
        .map((r) => ChatModel(
              id: r['id'] as String,
              provider: (r['provider'] as String?) ?? '',
              label: (r['label'] as String?) ?? r['id'] as String,
            ))
        .toList();
  } catch (_) {
    return [];
  }
}
