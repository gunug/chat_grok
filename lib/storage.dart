// Persistence layer backed by shared_preferences: conversations + selected
// model. The Supabase project URL and anon key are NOT user-editable — they are
// baked into config.dart and never surfaced in the UI.

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';
import 'config.dart';

class Store {
  static const _kConversations = 'conversations';
  static const _kActiveId = 'activeId';
  static const _kModel = 'chatModel';
  static const _kImageModel = 'imageModel';
  static const _kPromptModel = 'promptModel';
  static const defaultModel = 'gpt-4.1-mini';
  static const defaultImageModel = 'grok-imagine-image-quality';
  static const defaultPromptModel = 'grok-3'; // 이미지 프롬프트 생성용(compose)

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

  Conversation createConversation({String kind = 'chat'}) {
    final c = Conversation.create(kind: kind);
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

  // --- Supabase connection (read-only; from config.dart) --------------------
  // These are public project identifiers, baked into the app. They are never
  // shown or editable in the UI — the user cannot read them through the app.
  String get supabaseUrl => kSupabaseUrl;
  String get anonKey => kSupabaseAnonKey;

  // 선택된 채팅 모델 id(cg_models.id). 미설정 시 기본 모델.
  String get model {
    final v = _prefs.getString(_kModel) ?? '';
    return v.isNotEmpty ? v : defaultModel;
  }

  Future<void> setModel(String id) async => _prefs.setString(_kModel, id);

  // 선택된 이미지 모델 id(cg_image_models.id). 미설정 시 기본 이미지 모델.
  String get imageModel {
    final v = _prefs.getString(_kImageModel) ?? '';
    return v.isNotEmpty ? v : defaultImageModel;
  }

  Future<void> setImageModel(String id) async =>
      _prefs.setString(_kImageModel, id);

  // 대화 이미지(compose)에서 프롬프트를 만드는 텍스트 모델 id(cg_models.id).
  String get promptModel {
    final v = _prefs.getString(_kPromptModel) ?? '';
    return v.isNotEmpty ? v : defaultPromptModel;
  }

  Future<void> setPromptModel(String id) async =>
      _prefs.setString(_kPromptModel, id);
}
