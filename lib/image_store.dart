// Storage for images generated through this app.
// Bytes live in an app-private folder (path_provider); a lightweight index in
// shared_preferences keeps the prompt + timestamp so the gallery can list and
// delete them. Deleting removes both the file and its index entry (on-device).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One saved image: where its bytes are + how it was made.
class GalleryImage {
  final String path;
  final String prompt; // English prompt actually sent to the image model
  final String promptKo; // Korean translation (display only; '' for old entries)
  final int createdAt; // epoch ms

  GalleryImage({
    required this.path,
    required this.prompt,
    this.promptKo = '',
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'prompt': prompt,
        if (promptKo.isNotEmpty) 'promptKo': promptKo,
        'createdAt': createdAt,
      };

  factory GalleryImage.fromJson(Map<String, dynamic> j) => GalleryImage(
        path: j['path'] as String,
        prompt: (j['prompt'] as String?) ?? '',
        promptKo: (j['promptKo'] as String?) ?? '',
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      );

  File get file => File(path);
  bool get exists => file.existsSync();
}

class ImageStore {
  static const _kIndex = 'gallery_index';
  static const _dirName = 'generated_images';

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_dirName');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  /// Saves [bytes] to a new file and records it in the index. Returns its path.
  static Future<String> save(Uint8List bytes, String prompt,
      {String promptKo = ''}) async {
    final dir = await _dir();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final path = '${dir.path}/img_$ts.jpg';
    await File(path).writeAsBytes(bytes, flush: true);

    final entry = GalleryImage(
        path: path, prompt: prompt, promptKo: promptKo, createdAt: ts);
    final items = await list();
    items.insert(0, entry); // newest first
    await _persist(items);
    return path;
  }

  /// All saved images (newest first), pruned of any whose file is gone.
  static Future<List<GalleryImage>> list() async {
    final p = await _prefs;
    final raw = p.getString(_kIndex);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => GalleryImage.fromJson(Map<String, dynamic>.from(e)))
          .where((g) => g.exists)
          .toList();
      return list;
    } catch (_) {
      return [];
    }
  }

  /// Deletes one image (file + index entry) from the device.
  static Future<void> delete(GalleryImage image) async {
    try {
      if (image.exists) await image.file.delete();
    } catch (_) {/* file already gone */}
    final items = await list();
    items.removeWhere((g) => g.path == image.path);
    await _persist(items);
  }

  /// Deletes many images (files + index entries) from the device.
  static Future<void> deleteMany(Iterable<GalleryImage> images) async {
    final paths = images.map((g) => g.path).toSet();
    for (final img in images) {
      try {
        if (img.exists) await img.file.delete();
      } catch (_) {/* file already gone */}
    }
    final items = await list();
    items.removeWhere((g) => paths.contains(g.path));
    await _persist(items);
  }

  static Future<void> _persist(List<GalleryImage> items) async {
    final p = await _prefs;
    await p.setString(
        _kIndex, jsonEncode(items.map((g) => g.toJson()).toList()));
  }
}
