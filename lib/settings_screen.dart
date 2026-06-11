import 'package:flutter/material.dart';
import 'storage.dart';
import 'credits.dart';

class SettingsScreen extends StatefulWidget {
  final Store store;
  const SettingsScreen({super.key, required this.store});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _url =
      TextEditingController(text: widget.store.supabaseUrl);
  late final TextEditingController _key =
      TextEditingController(text: widget.store.anonKey);

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.store.setSettings(_url.text, _key.text);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('설정'),
        actions: const [CreditBadge()],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Supabase 연결',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            '기본값이 앱에 내장돼 있어 입력하지 않아도 바로 동작합니다. '
            '다른 Supabase 프로젝트로 바꿀 때만 여기서 덮어쓰세요. '
            'xAI 키는 여기에 넣지 않습니다(서버 시크릿에 보관됨).',
            style: TextStyle(fontSize: 12, color: Colors.white60),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Project URL',
              hintText: 'https://xxxx.supabase.co',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _key,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'anon public key',
              hintText: 'eyJ...',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _save,
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('저장'),
            ),
          ),
        ],
      ),
    );
  }
}
