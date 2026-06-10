// Persistence layer backed by shared_preferences: conversations + settings
// (Supabase project URL and anon key).

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';
import 'config.dart';

class Store {
  static const _kConversations = 'conversations';
  static const _kActiveId = 'activeId';
  static const _kSupabaseUrl = 'supabaseUrl';
  static const _kAnonKey = 'supabaseAnonKey';

  late SharedPreferences _prefs;
  List<Conversation> conversations = [];
  String? activeId;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _load();
  }

  void _load() {
    final raw = _prefs.getString(_kConversations);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        conversations = list
            .map((e) => Conversation.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      } catch (_) {
        conversations = [];
      }
    }
    activeId = _prefs.getString(_kActiveId);
  }

  Future<void> save() async {
    await _prefs.setString(
      _kConversations,
      jsonEncode(conversations.map((c) => c.toJson()).toList()),
    );
    if (activeId != null) await _prefs.setString(_kActiveId, activeId!);
  }

  Conversation? get active {
    if (activeId == null) return null;
    for (final c in conversations) {
      if (c.id == activeId) return c;
    }
    return null;
  }

  Conversation createConversation() {
    final c = Conversation.create();
    conversations.insert(0, c);
    activeId = c.id;
    save();
    return c;
  }

  Conversation ensureActive() => active ?? createConversation();

  void remove(String id) {
    conversations.removeWhere((c) => c.id == id);
    if (activeId == id) {
      activeId = conversations.isNotEmpty ? conversations.first.id : null;
    }
    save();
  }

  // --- Settings -------------------------------------------------------------
  // Falls back to the values baked into config.dart, so the app works with no
  // setup. A stored value (entered in Settings) overrides the default.
  String get supabaseUrl {
    final v = _prefs.getString(_kSupabaseUrl) ?? '';
    return v.isNotEmpty ? v : kSupabaseUrl;
  }

  String get anonKey {
    final v = _prefs.getString(_kAnonKey) ?? '';
    return v.isNotEmpty ? v : kSupabaseAnonKey;
  }

  bool get isConfigured => supabaseUrl.isNotEmpty && anonKey.isNotEmpty;

  Future<void> setSettings(String url, String key) async {
    await _prefs.setString(_kSupabaseUrl, url.trim().replaceAll(RegExp(r'/$'), ''));
    await _prefs.setString(_kAnonKey, key.trim());
  }
}
