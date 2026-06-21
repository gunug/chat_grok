// Image gallery: browse images generated through this app and delete them
// (removed from the device — file + index entry). Backed by ImageStore.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';

import 'image_store.dart';

const _bg = Color(0xFF0D0F14);
const _panel = Color(0xFF161922);
const _accent = Color(0xFF6C8CFF);
const _textDim = Color(0xFF9AA3B2);

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});
  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<GalleryImage> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await ImageStore.list();
    if (mounted) {
      setState(() {
        _items = items;
        _loading = false;
      });
    }
  }

  Future<void> _delete(GalleryImage img) async {
    await ImageStore.delete(img);
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('이미지를 삭제했습니다.')),
      );
    }
  }

  Future<void> _confirmDelete(GalleryImage img) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _panel,
        title: const Text('이미지 삭제'),
        content: const Text('이 이미지를 기기에서 삭제할까요? 되돌릴 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제', style: TextStyle(color: Color(0xFFFF6B6B))),
          ),
        ],
      ),
    );
    if (ok == true) await _delete(img);
  }

  void _openViewer(GalleryImage img) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ImageViewer(image: img, onDelete: () => _confirmDelete(img)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(title: const Text('이미지 갤러리')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '아직 생성된 이미지가 없습니다.\n‘새 이미지’ 대화에서 만들고 싶은 이미지를 입력해 보세요.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _textDim, height: 1.5),
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: _items.length,
                    itemBuilder: (_, i) {
                      final img = _items[i];
                      return GestureDetector(
                        onTap: () => _openViewer(img),
                        onLongPress: () => _confirmDelete(img),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.file(
                            img.file,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              color: _panel,
                              child: const Icon(Icons.broken_image,
                                  color: _textDim),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

class _ImageViewer extends StatelessWidget {
  final GalleryImage image;
  final VoidCallback onDelete;
  const _ImageViewer({required this.image, required this.onDelete});

  void _copy(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('복사되었습니다'),
      duration: Duration(seconds: 1),
    ));
  }

  Widget _copyButton(BuildContext context, String text) {
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: () => _copy(context, text),
        icon: const Icon(Icons.copy, size: 14),
        label: const Text('복사'),
        style: TextButton.styleFrom(
          foregroundColor: _accent,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  Future<void> _download(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Gal.putImage(image.path);
      messenger.showSnackBar(const SnackBar(
        content: Text('갤러리에 저장했습니다'),
        duration: Duration(seconds: 1),
      ));
    } on GalException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('저장 실패: ${e.type.message}'),
        backgroundColor: Colors.red[900],
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('저장 실패: $e'),
        backgroundColor: Colors.red[900],
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: '다운로드',
            onPressed: () => _download(context),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              onDelete();
              Navigator.pop(context); // 삭제 다이얼로그 확인 후 목록으로 복귀
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              child: Center(
                child: Image.file(
                  image.file,
                  errorBuilder: (_, _, _) => const Text('이미지를 불러올 수 없습니다.',
                      style: TextStyle(color: Colors.white70)),
                ),
              ),
            ),
          ),
          if (image.prompt.isNotEmpty || image.promptKo.isNotEmpty)
            Container(
              width: double.infinity,
              color: _panel,
              // 높이를 제한해야 내부 SingleChildScrollView가 실제로 스크롤된다
              // (제한이 없으면 내용만큼 늘어나 긴 프롬프트가 화면 밖으로 잘림).
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.35),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (image.prompt.isNotEmpty) ...[
                      const Text('영문 프롬프트',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: _textDim)),
                      const SizedBox(height: 4),
                      SelectableText(image.prompt,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13, height: 1.4)),
                      _copyButton(context, image.prompt),
                    ],
                    if (image.promptKo.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      const Text('한글 번역',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: _textDim)),
                      const SizedBox(height: 4),
                      SelectableText(image.promptKo,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13, height: 1.4)),
                      _copyButton(context, image.promptKo),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
