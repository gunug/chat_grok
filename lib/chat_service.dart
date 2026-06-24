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
    String? requestId,
    String? model,
  }) async* {
    final uri = Uri.parse('$supabaseUrl/functions/v1/chat');
    final client = http.Client();
    var completed = false; // usage/done까지 받았으면 답변은 사실상 완성됨
    try {
      final req = http.Request('POST', uri);
      req.headers['Content-Type'] = 'application/json';
      req.headers['Authorization'] = 'Bearer ${accessToken ?? anonKey}';
      req.headers['apikey'] = anonKey;
      req.body = jsonEncode({
        'messages': messages,
        'requestId': ?requestId,
        'model': ?model,
      });

      final resp = await client.send(req);

      if (resp.statusCode != 200) {
        final body = await resp.stream.bytesToString();
        // 크레딧 부족은 별도 안내(충전 유도).
        if (resp.statusCode == 402) {
          yield ChatEvent.error(
              '토큰 잔여량이 AI기능을 수행하기에 부족합니다.\n충전 후 다시 시도하세요.');
          return;
        }
        String msg = 'HTTP ${resp.statusCode}';
        String raw = '';
        try {
          final j = jsonDecode(body);
          msg = j['error']?.toString() ?? msg;
          if (j['detail'] != null) raw = j['detail'].toString();
          if (raw.isNotEmpty) msg = '$msg: $raw';
        } catch (_) {
          if (body.isNotEmpty) {
            raw = body;
            msg = '$msg: ${body.substring(0, body.length.clamp(0, 300))}';
          }
        }
        // 제공자(xAI/OpenAI) 잔액 소진 = 운영자가 API 비용을 충전해야 함.
        // 업스트림 429/402/403 또는 billing/quota/credit 류 메시지를 잡아낸다.
        final probe = '$msg $raw'.toLowerCase();
        final providerOutOfFunds = resp.statusCode == 502 &&
            (RegExp(r'\b(402|403|429)\b').hasMatch(probe) ||
                RegExp(r'quota|billing|credit|insufficient|payment|balance|exceeded|rate.?limit')
                    .hasMatch(probe));
        if (providerOutOfFunds) {
          yield ChatEvent.error(
              '현재 서비스 이용이 일시 중단되었습니다.\n'
              '운영자의 API 사용 잔액이 소진되어 비용 충전이 필요합니다. '
              '잠시 후 다시 시도해 주세요.');
          return;
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
          if (parsed == null) continue;
          if (parsed.type == 'usage' || parsed.type == 'done') {
            completed = true;
          }
          yield parsed;
        }
      }
    } catch (e) {
      // 앱이 백그라운드로 가면 소켓이 끊겨 "Connection closed" 예외가 난다.
      // 답변을 이미 다 받은 뒤(완료)라면 가짜 실패이므로 무시한다.
      if (!completed) yield ChatEvent.error(e.toString());
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
