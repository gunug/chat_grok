// On-device history of image prompts used in the app. Records every prompt the
// moment it's ready (composed or typed), so it survives even if the user
// abandons image generation. Status is updated once a render finishes.
//
// Backed by shared_preferences (text only — small). Newest first.

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// One prompt-history record.
///  status: 'composed' = 프롬프트만 생성(이미지 미생성/포기), 'success' = 생성 성공,
///          'blocked' = 정책 차단, 'failed' = 오류.
class PromptEntry {
  final String id;
  final int createdAt; // epoch ms
  final String prompt; // English / raw prompt actually sent
  final String promptKo; // Korean translation ('' for direct/raw prompts)
  final String model; // image model id used
  final String mode; // 'prompt' = 직접, 'chat' = 대화(AI 생성)
  String status;

  PromptEntry({
    required this.id,
    required this.createdAt,
    required this.prompt,
    this.promptKo = '',
    this.model = '',
    this.mode = 'chat',
    this.status = 'composed',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt,
        'prompt': prompt,
        if (promptKo.isNotEmpty) 'promptKo': promptKo,
        if (model.isNotEmpty) 'model': model,
        'mode': mode,
        'status': status,
      };

  factory PromptEntry.fromJson(Map<String, dynamic> j) => PromptEntry(
        id: j['id'] as String,
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        prompt: (j['prompt'] as String?) ?? '',
        promptKo: (j['promptKo'] as String?) ?? '',
        model: (j['model'] as String?) ?? '',
        mode: (j['mode'] as String?) ?? 'chat',
        status: (j['status'] as String?) ?? 'composed',
      );
}

class PromptStore {
  static const _kIndex = 'prompt_history';
  static const _maxEntries = 500; // 너무 커지지 않도록 오래된 것부터 정리
  static int _seq = 0;

  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  /// Records a new prompt and returns its id (use it to update status later).
  static Future<String> add({
    required String prompt,
    String promptKo = '',
    String model = '',
    String mode = 'chat',
    String status = 'composed',
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final id = 'p${ts}_${_seq++}';
    final items = await list();
    items.insert(
      0,
      PromptEntry(
        id: id,
        createdAt: ts,
        prompt: prompt,
        promptKo: promptKo,
        model: model,
        mode: mode,
        status: status,
      ),
    );
    if (items.length > _maxEntries) items.removeRange(_maxEntries, items.length);
    await _persist(items);
    return id;
  }

  /// Updates the status of an existing entry (success/blocked/failed).
  static Future<void> updateStatus(String id, String status) async {
    final items = await list();
    for (final e in items) {
      if (e.id == id) {
        e.status = status;
        break;
      }
    }
    await _persist(items);
  }

  /// All recorded prompts (newest first).
  static Future<List<PromptEntry>> list() async {
    final p = await _prefs;
    final raw = p.getString(_kIndex);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => PromptEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> delete(String id) async {
    final items = await list();
    items.removeWhere((e) => e.id == id);
    await _persist(items);
  }

  static Future<void> clear() async {
    final p = await _prefs;
    await p.remove(_kIndex);
  }

  static Future<void> _persist(List<PromptEntry> items) async {
    final p = await _prefs;
    await p.setString(
        _kIndex, jsonEncode(items.map((e) => e.toJson()).toList()));
  }
}
