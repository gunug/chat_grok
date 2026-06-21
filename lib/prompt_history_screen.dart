// Prompt history: every image prompt used in the app (composed or typed),
// with its outcome (success / blocked / failed / prompt-only) and copy buttons.
// Recording happens even when the user composes a prompt but abandons the
// image generation, so nothing is lost. Backed by PromptStore.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'prompt_store.dart';

const _bg = Color(0xFF0D0F14);
const _panel = Color(0xFF161922);
const _panel2 = Color(0xFF1E222E);
const _border = Color(0xFF2A2F3D);
const _accent = Color(0xFF6C8CFF);
const _textDim = Color(0xFF9AA3B2);

class PromptHistoryScreen extends StatefulWidget {
  const PromptHistoryScreen({super.key});
  @override
  State<PromptHistoryScreen> createState() => _PromptHistoryScreenState();
}

class _PromptHistoryScreenState extends State<PromptHistoryScreen> {
  List<PromptEntry> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await PromptStore.list();
    if (mounted) {
      setState(() {
        _items = items;
        _loading = false;
      });
    }
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('복사되었습니다'),
      duration: Duration(seconds: 1),
    ));
  }

  Future<void> _delete(PromptEntry e) async {
    await PromptStore.delete(e.id);
    await _reload();
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _panel,
        title: const Text('히스토리 전체 삭제'),
        content: const Text('모든 프롬프트 기록을 삭제할까요? 되돌릴 수 없습니다.'),
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
    if (ok == true) {
      await PromptStore.clear();
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: const Text('프롬프트 히스토리'),
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '전체 삭제',
              onPressed: _confirmClear,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '아직 기록된 프롬프트가 없습니다.\n이미지 세션에서 프롬프트를 만들면 여기에 쌓입니다.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _textDim, height: 1.5),
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _PromptCard(
                      entry: _items[i],
                      onCopy: _copy,
                      onDelete: () => _delete(_items[i]),
                    ),
                  ),
                ),
    );
  }
}

class _PromptCard extends StatefulWidget {
  final PromptEntry entry;
  final void Function(String text) onCopy;
  final VoidCallback onDelete;
  const _PromptCard(
      {required this.entry, required this.onCopy, required this.onDelete});

  @override
  State<_PromptCard> createState() => _PromptCardState();
}

class _PromptCardState extends State<_PromptCard> {
  bool _expanded = false; // 기본 접힘

  // 접힘 상태 미리보기: 한글이 있으면 한글, 없으면 영문. 한 줄로 요약.
  String get _preview {
    final e = widget.entry;
    final base = e.promptKo.isNotEmpty ? e.promptKo : e.prompt;
    return base.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 상태 배지 + 모드 + 펼치기/접기 + 삭제.
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        _statusBadge(entry.status),
                        const SizedBox(width: 8),
                        Text(entry.mode == 'prompt' ? '직접' : '대화',
                            style:
                                const TextStyle(fontSize: 11, color: _textDim)),
                        const Spacer(),
                        Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                            size: 20, color: _textDim),
                      ],
                    ),
                  ),
                ),
              ),
              InkWell(
                onTap: widget.onDelete,
                borderRadius: BorderRadius.circular(6),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.delete_outline, size: 18, color: _textDim),
                ),
              ),
            ],
          ),
          if (!_expanded)
            // 접힘: 프롬프트 일부 요약 + 생략(...). 탭하면 펼친다.
            InkWell(
              onTap: () => setState(() => _expanded = true),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: _textDim, fontSize: 13, height: 1.4),
                ),
              ),
            )
          else ...[
            if (entry.model.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(entry.model,
                  style: const TextStyle(fontSize: 11, color: _textDim)),
            ],
            // 영문 프롬프트 + 복사.
            const SizedBox(height: 10),
            _promptBlock(context, '영문 프롬프트', entry.prompt),
            // 한글 번역 + 복사(있을 때만).
            if (entry.promptKo.isNotEmpty) ...[
              const SizedBox(height: 12),
              _promptBlock(context, '한글 번역', entry.promptKo),
            ],
          ],
        ],
      ),
    );
  }

  Widget _promptBlock(BuildContext context, String label, String text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.bold, color: _textDim)),
        const SizedBox(height: 4),
        SelectableText(text,
            style: const TextStyle(
                color: Colors.white, fontSize: 13, height: 1.4)),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => widget.onCopy(text),
            icon: const Icon(Icons.copy, size: 14),
            label: const Text('복사'),
            style: TextButton.styleFrom(
              foregroundColor: _accent,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
      ],
    );
  }

  Widget _statusBadge(String status) {
    late final String text;
    late final Color color;
    switch (status) {
      case 'success':
        text = '✅ 성공';
        color = const Color(0xFF4CAF50);
        break;
      case 'blocked':
        text = '🚫 차단';
        color = const Color(0xFFFF9800);
        break;
      case 'failed':
        text = '⚠ 실패';
        color = const Color(0xFFFF6B6B);
        break;
      default: // composed
        text = '📝 프롬프트만';
        color = _textDim;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _panel2,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}
