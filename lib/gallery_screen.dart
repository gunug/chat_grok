// Image gallery: browse images generated through this app and delete them
// (removed from the device — file + index entry). Backed by ImageStore.

import 'package:flutter/material.dart';

import 'image_store.dart';

const _bg = Color(0xFF0D0F14);
const _panel = Color(0xFF161922);
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
                      '아직 생성된 이미지가 없습니다.\n대화 화면에서 🖼 버튼으로 마지막 장면을 이미지로 만들어 보세요.',
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        actions: [
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
          if (image.prompt.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: _panel,
              child: SingleChildScrollView(
                child: Text(image.prompt,
                    style: const TextStyle(color: _textDim, fontSize: 12)),
              ),
            ),
        ],
      ),
    );
  }
}
