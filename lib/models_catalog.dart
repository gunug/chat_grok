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

/// Fetches the chat models that are BOTH enabled in our catalog AND actually
/// available on the provider account (server validates via provider model-list
/// APIs — no tokens billed). Already sorted (OpenAI→xAI, price desc). Returns []
/// on error (UI falls back to showing the stored model id).
Future<List<ChatModel>> fetchModels() async {
  try {
    final res = await Supabase.instance.client.functions
        .invoke('chat', body: {'mode': 'models'});
    final data = res.data;
    final list = (data is Map ? data['models'] : null) as List?;
    if (list == null) return [];
    return list
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

/// One selectable image-generation model (cg_image_models row).
class ImageModel {
  final String id;
  final String provider; // 'openai' | 'xai'
  final String label;
  final double? priceUsd; // flat USD per generated image (display estimate)
  ImageModel({
    required this.id,
    required this.provider,
    required this.label,
    this.priceUsd,
  });
}

/// Fetches the image models that are BOTH enabled in our catalog AND actually
/// available on the provider account (server validates via provider model-list
/// APIs — no tokens billed). Returns [] on error (UI falls back to the
/// stored/default image model id).
Future<List<ImageModel>> fetchImageModels() async {
  try {
    final res = await Supabase.instance.client.functions
        .invoke('image', body: {'mode': 'models'});
    final data = res.data;
    final list = (data is Map ? data['models'] : null) as List?;
    if (list == null) return [];
    return list
        .map((r) => ImageModel(
              id: r['id'] as String,
              provider: (r['provider'] as String?) ?? '',
              label: (r['label'] as String?) ?? r['id'] as String,
              priceUsd: (r['price_usd'] as num?)?.toDouble(),
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
