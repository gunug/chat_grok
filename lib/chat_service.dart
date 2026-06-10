// Streams a chat completion from the Supabase Edge Function ("chat"), which
// proxies xAI and emits SSE events: text deltas, a usage event, then done.

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// One parsed event from the SSE stream.
class ChatEvent {
  final String type; // 'delta' | 'usage' | 'error' | 'done'
  final String? delta;
  final Map<String, dynamic>? usage;
  final String? error;
  ChatEvent.delta(this.delta)
      : type = 'delta',
        usage = null,
        error = null;
  ChatEvent.usage(this.usage)
      : type = 'usage',
        delta = null,
        error = null;
  ChatEvent.error(this.error)
      : type = 'error',
        delta = null,
        usage = null;
  ChatEvent.done()
      : type = 'done',
        delta = null,
        usage = null,
        error = null;
}

class ChatService {
  /// Sends [messages] and yields events as the answer streams in.
  /// [supabaseUrl] e.g. https://abcd.supabase.co ; [anonKey] = project anon key
  /// (sent as the gateway apikey); [accessToken] = the signed-in (anonymous)
  /// user's JWT, sent as the Bearer so the function sees an authenticated user.
  static Stream<ChatEvent> stream({
    required String supabaseUrl,
    required String anonKey,
    required List<Map<String, dynamic>> messages,
    String? accessToken,
  }) async* {
    final uri = Uri.parse('$supabaseUrl/functions/v1/chat');
    final client = http.Client();
    try {
      final req = http.Request('POST', uri);
      req.headers['Content-Type'] = 'application/json';
      req.headers['Authorization'] = 'Bearer ${accessToken ?? anonKey}';
      req.headers['apikey'] = anonKey;
      req.body = jsonEncode({'messages': messages});

      final resp = await client.send(req);

      if (resp.statusCode != 200) {
        final body = await resp.stream.bytesToString();
        // 크레딧 부족은 별도 안내(충전 유도).
        if (resp.statusCode == 402) {
          yield ChatEvent.error('크레딧이 부족합니다. 충전 후 다시 시도하세요.');
          return;
        }
        String msg = 'HTTP ${resp.statusCode}';
        try {
          final j = jsonDecode(body);
          msg = j['error']?.toString() ?? msg;
          if (j['detail'] != null) msg = '$msg: ${j['detail']}';
        } catch (_) {
          if (body.isNotEmpty) msg = '$msg: ${body.substring(0, body.length.clamp(0, 300))}';
        }
        yield ChatEvent.error(msg);
        return;
      }

      var buffer = '';
      await for (final chunk in resp.stream.transform(utf8.decoder)) {
        buffer += chunk;
        final events = buffer.split('\n\n');
        buffer = events.removeLast();
        for (final evt in events) {
          final parsed = _parseEvent(evt);
          if (parsed != null) yield parsed;
        }
      }
    } catch (e) {
      yield ChatEvent.error(e.toString());
    } finally {
      client.close();
    }
  }

  static ChatEvent? _parseEvent(String raw) {
    var eventType = 'message';
    var dataStr = '';
    for (final line in raw.split('\n')) {
      if (line.startsWith('event:')) {
        eventType = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataStr += line.substring(5).trim();
      }
    }
    if (dataStr.isEmpty) return null;

    dynamic data;
    try {
      data = jsonDecode(dataStr);
    } catch (_) {
      return null;
    }

    switch (eventType) {
      case 'usage':
        return ChatEvent.usage(Map<String, dynamic>.from(data));
      case 'error':
        final d = data['detail'];
        return ChatEvent.error(
            d != null ? '${data['error']}: $d' : '${data['error']}');
      case 'done':
        return ChatEvent.done();
      default:
        final delta = data['delta'];
        if (delta is String && delta.isNotEmpty) return ChatEvent.delta(delta);
        return null;
    }
  }
}
