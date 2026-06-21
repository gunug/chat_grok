// Calls the Supabase Edge Function ("image") in two steps:
//   compose -> get the (English) prompt + Korean translation to show the user
//   render  -> generate the image for a confirmed prompt (charged either way)
// The xAI key stays server-side. Single POST per step (not a stream).

import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// The prompt that will be sent, plus a Korean translation for the dialog.
/// Composing the prompt costs an API call, so it carries the credits charged.
class ComposedPrompt {
  final String prompt; // English prompt actually sent to the image model
  final String promptKo; // Korean translation (display only)
  final int? creditsCharged; // credits deducted for composing the prompt
  final int? imageCredits; // credits the image render will cost (preview)
  final int? balanceCredits;
  ComposedPrompt({
    required this.prompt,
    required this.promptKo,
    this.creditsCharged,
    this.imageCredits,
    this.balanceCredits,
  });
}

/// Outcome of a render: either image bytes, or blocked (still charged).
class RenderResult {
  final Uint8List? bytes; // null when blocked
  final bool blocked;
  final String prompt; // (possibly revised) prompt used
  final int? balanceCredits;
  final int? creditsCharged;
  RenderResult({
    required this.bytes,
    required this.blocked,
    required this.prompt,
    this.balanceCredits,
    this.creditsCharged,
  });
}

/// Thrown on a non-success response so the UI can show a friendly message.
class ImageError implements Exception {
  final String message;
  ImageError(this.message);
  @override
  String toString() => message;
}

class ImageService {
  static Uri _uri(String supabaseUrl) =>
      Uri.parse('$supabaseUrl/functions/v1/image');

  static Map<String, String> _headers(String anonKey, String? accessToken) => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${accessToken ?? anonKey}',
        'apikey': anonKey,
      };

  static Never _throwFor(http.Response resp) {
    if (resp.statusCode == 402) {
      throw ImageError('크레딧이 부족합니다. 충전 후 다시 시도하세요.');
    }
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {}
    final msg = j?['error']?.toString() ?? 'HTTP ${resp.statusCode}';
    final detail = j?['detail']?.toString();
    throw ImageError(detail != null ? '$msg: $detail' : msg);
  }

  /// Step 1 — build the scene prompt (cheap; not charged). [model] is the
  /// image model id used only to preview its per-image credit cost.
  static Future<ComposedPrompt> compose({
    required String supabaseUrl,
    required String anonKey,
    required List<Map<String, dynamic>> messages,
    String? accessToken,
    String? model,
    String? promptModel,
  }) async {
    final resp = await http.post(
      _uri(supabaseUrl),
      headers: _headers(anonKey, accessToken),
      body: jsonEncode({
        'mode': 'compose',
        'messages': messages,
        'model': ?model,
        'promptModel': ?promptModel,
      }),
    );
    if (resp.statusCode != 200) _throwFor(resp);
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final prompt = (j['prompt'] as String?)?.trim() ?? '';
    if (prompt.isEmpty) throw ImageError('프롬프트를 생성하지 못했습니다.');
    return ComposedPrompt(
      prompt: prompt,
      promptKo: (j['promptKo'] as String?)?.trim() ?? '',
      creditsCharged: (j['creditsCharged'] as num?)?.toInt(),
      imageCredits: (j['imageCredits'] as num?)?.toInt(),
      balanceCredits: (j['balanceCredits'] as num?)?.toInt(),
    );
  }

  /// Step 2 — render the confirmed prompt with [model]. xAI charges credits
  /// even if blocked; OpenAI does not.
  static Future<RenderResult> render({
    required String supabaseUrl,
    required String anonKey,
    required String prompt,
    String? accessToken,
    String? model,
  }) async {
    final resp = await http.post(
      _uri(supabaseUrl),
      headers: _headers(anonKey, accessToken),
      body: jsonEncode({
        'mode': 'render',
        'prompt': prompt,
        'model': ?model,
      }),
    );
    if (resp.statusCode != 200) _throwFor(resp);
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final blocked = j['blocked'] == true;
    final b64 = j['imageB64'] as String?;
    return RenderResult(
      bytes: (!blocked && b64 != null && b64.isNotEmpty)
          ? base64Decode(b64)
          : null,
      blocked: blocked,
      prompt: (j['revisedPrompt'] as String?) ?? prompt,
      balanceCredits: (j['balanceCredits'] as num?)?.toInt(),
      creditsCharged: (j['creditsCharged'] as num?)?.toInt(),
    );
  }
}
