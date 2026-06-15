// Client side of server-complete-and-store: reads/deletes the cg_pending_chat
// row (RLS: own rows only) so an answer that finished server-side while the app
// was backgrounded can be merged back in on resume. Also a UUID v4 generator
// for the per-request idempotency key.

import 'dart:math';
import 'package:supabase_flutter/supabase_flutter.dart';

/// RFC 4122 v4 UUID — used as the chat request id (cg_pending_chat PK).
String newRequestId() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-'
      '${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
}

class PendingChat {
  /// Reads the pending row for [requestId], or null if not found / on error.
  static Future<Map<String, dynamic>?> fetch(String requestId) async {
    try {
      final row = await Supabase.instance.client
          .from('cg_pending_chat')
          .select('status, content, usage')
          .eq('request_id', requestId)
          .maybeSingle();
      return row;
    } catch (_) {
      return null;
    }
  }

  /// Deletes the row once its result has been merged locally (best-effort).
  static Future<void> delete(String requestId) async {
    try {
      await Supabase.instance.client
          .from('cg_pending_chat')
          .delete()
          .eq('request_id', requestId);
    } catch (_) {/* RLS/network — harmless, TTL prune will catch it */}
  }
}
