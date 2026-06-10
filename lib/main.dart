import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';
import 'storage.dart';
import 'chat_service.dart';
import 'settings_screen.dart';
import 'credits_screen.dart';
import 'login_screen.dart';
import 'supa.dart';

final store = Store();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await store.init();
  try {
    await initSupabase(store.supabaseUrl, store.anonKey);
  } catch (_) {
    // 네트워크 문제 시에도 앱은 뜬다(로그인 화면에서 재시도).
  }
  runApp(const GrokApp());
}

const _bg = Color(0xFF0D0F14);
const _panel = Color(0xFF161922);
const _panel2 = Color(0xFF1E222E);
const _border = Color(0xFF2A2F3D);
const _accent = Color(0xFF6C8CFF);
const _textDim = Color(0xFF9AA3B2);

class GrokApp extends StatelessWidget {
  const GrokApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark(useMaterial3: true);
    return MaterialApp(
      title: 'Grok Chat',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: _bg,
        colorScheme: base.colorScheme.copyWith(
          primary: _accent,
          surface: _panel,
        ),
        appBarTheme: const AppBarTheme(backgroundColor: _bg, elevation: 0),
        drawerTheme: const DrawerThemeData(backgroundColor: Color(0xFF0A0C11)),
      ),
      home: const AuthGate(),
    );
  }
}

// Shows the login screen until a real (non-anonymous) Google session exists.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthState>? _sub;

  @override
  void initState() {
    super.initState();
    // 남아있는 익명 세션은 제거(이제 Google 로그인만 사용).
    final u = Supabase.instance.client.auth.currentUser;
    if (u != null && u.isAnonymous) {
      Supabase.instance.client.auth.signOut();
    }
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return isLoggedIn ? const ChatScreen() : const LoginScreen();
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _streaming = false;
  int _sessionTokens = 0;
  double _sessionCost = 0;

  Conversation? get _conv => store.active;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _streaming) return;

    // 로그인 게이트를 통과했으므로 세션이 있다.
    final token = currentAccessToken();
    if (token == null) return; // 안전장치

    _input.clear();
    final conv = store.ensureActive();
    conv.messages.add(Message('user', text));
    conv.retitleIfNeeded();
    conv.updatedAt = DateTime.now().millisecondsSinceEpoch;

    final bot = Message('assistant', '');
    conv.messages.add(bot);
    setState(() => _streaming = true);
    await store.save();
    _scrollToBottom();

    Map<String, dynamic>? usage;
    String? error;
    final history = conv.messages
        .where((m) => m != bot)
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();

    try {
      await for (final e in ChatService.stream(
        supabaseUrl: store.supabaseUrl,
        anonKey: store.anonKey,
        accessToken: token,
        messages: history,
      )) {
        switch (e.type) {
          case 'delta':
            setState(() => bot.content += e.delta!);
            _scrollToBottom();
            break;
          case 'usage':
            usage = e.usage;
            break;
          case 'error':
            error = e.error;
            break;
        }
      }
    } catch (e) {
      error = e.toString();
    }

    if (error != null) {
      // 실패한 두 턴(사용자+봇 placeholder)을 롤백해 재시도 시 중복 방지.
      conv.messages.remove(bot);
      if (conv.messages.isNotEmpty && conv.messages.last.role == 'user') {
        conv.messages.removeLast();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('⚠ $error'), backgroundColor: Colors.red[900]),
        );
      }
    } else {
      if (bot.content.isEmpty) bot.content = '(빈 응답)';
      if (usage != null) {
        bot.usage = usage;
        final total = (usage['total'] as num?)?.toInt() ?? 0;
        final cost = (usage['costUsd'] as num?)?.toDouble() ?? 0;
        conv.usageTokens += total;
        conv.usageCost += cost;
        _sessionTokens += total;
        _sessionCost += cost;
      }
    }
    conv.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await store.save();
    if (mounted) setState(() => _streaming = false);
    _scrollToBottom();
  }

  Future<void> _openSettings({bool prompt = false}) async {
    if (prompt) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('먼저 설정에서 Supabase URL과 anon key를 입력하세요.'),
      ));
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SettingsScreen(store: store)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openCredits() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CreditsScreen()),
    );
  }

  Future<void> _logout() async {
    await signOut(); // AuthGate가 로그인 화면으로 전환.
  }

  void _newChat() {
    setState(() => store.createConversation());
    Navigator.pop(context); // close drawer
  }

  void _selectConv(String id) {
    setState(() => store.activeId = id);
    store.save();
    Navigator.pop(context);
  }

  void _deleteConv(String id) {
    setState(() => store.remove(id));
  }

  void _export(bool asJson) {
    final c = _conv;
    if (c == null || c.messages.isEmpty) return;
    final String content;
    if (asJson) {
      content = const JsonEncoder.withIndent('  ').convert(c.toJson());
    } else {
      final b = StringBuffer('# ${c.title}\n\n');
      for (final m in c.messages) {
        b.writeln(m.role == 'user' ? '**🧑 나**' : '**✦ Grok**');
        b.writeln('\n${m.content}\n\n---\n');
      }
      content = b.toString();
    }
    Share.share(content, subject: c.title);
  }

  @override
  Widget build(BuildContext context) {
    final conv = _conv;
    final messages = conv?.messages ?? const <Message>[];
    return Scaffold(
      appBar: AppBar(
        title: Text(conv?.title ?? 'Grok Chat',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17)),
        actions: [
          if (_sessionTokens > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  '∑ $_sessionTokens tok'
                  '${_sessionCost > 0 ? ' · \$${_sessionCost.toStringAsFixed(4)}' : ''}',
                  style: const TextStyle(fontSize: 11, color: _textDim),
                ),
              ),
            ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'md') _export(false);
              if (v == 'json') _export(true);
              if (v == 'credits') _openCredits();
              if (v == 'settings') _openSettings();
              if (v == 'logout') _logout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'md', child: Text('Markdown 내보내기')),
              PopupMenuItem(value: 'json', child: Text('JSON 내보내기')),
              PopupMenuItem(value: 'credits', child: Text('크레딧')),
              PopupMenuItem(value: 'settings', child: Text('설정')),
              PopupMenuItem(value: 'logout', child: Text('로그아웃')),
            ],
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const _EmptyState()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: messages.length,
                    itemBuilder: (_, i) => _Bubble(message: messages[i]),
                  ),
          ),
          _buildComposer(),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _newChat,
                  icon: const Icon(Icons.add),
                  label: const Text('새 대화'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: _border),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    alignment: Alignment.centerLeft,
                  ),
                ),
              ),
            ),
            const Divider(height: 1, color: _border),
            Expanded(
              child: ListView(
                children: store.conversations.map((c) {
                  final selected = c.id == store.activeId;
                  return ListTile(
                    selected: selected,
                    selectedTileColor: _panel,
                    title: Text(c.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: c.usageTokens > 0
                        ? Text(
                            '${c.usageTokens} tok · \$${c.usageCost.toStringAsFixed(4)}',
                            style: const TextStyle(
                                fontSize: 11, color: _textDim))
                        : null,
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      color: _textDim,
                      onPressed: () => _deleteConv(c.id),
                    ),
                    onTap: () => _selectConv(c.id),
                  );
                }).toList(),
              ),
            ),
            const Divider(height: 1, color: _border),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('기기에 저장됨 · xAI 키는 서버 보관',
                  style: TextStyle(fontSize: 11, color: _textDim)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComposer() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _border)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: '메시지를 입력하세요…',
                  filled: true,
                  fillColor: _panel,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: _border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: _border),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 46,
              height: 46,
              child: FilledButton(
                onPressed: _streaming ? null : _send,
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _streaming
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('무엇을 도와드릴까요?',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          Text('xAI Grok에게 무엇이든 물어보세요.', style: TextStyle(color: _textDim)),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final Message message;
  const _Bubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final isError = message.content.startsWith('⚠');
    final u = message.usage;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isUser ? _panel2 : _accent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(isUser ? '나' : '✦',
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser ? _panel2 : _panel,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: isError ? Colors.red : _border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    message.content.isEmpty ? '…' : message.content,
                    style: TextStyle(
                        color: isError ? const Color(0xFFFF9B8E) : Colors.white,
                        height: 1.5),
                  ),
                  if (u != null) _usageLine(u),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _usageLine(Map<String, dynamic> u) {
    final parts = <String>[
      '입력 ${u['prompt']}${(u['cached'] ?? 0) > 0 ? ' (캐시 ${u['cached']})' : ''}',
      '출력 ${u['completion']}${(u['reasoning'] ?? 0) > 0 ? ' (추론 ${u['reasoning']})' : ''}',
      '합계 ${u['total']} tok',
    ];
    if (u['costUsd'] != null) {
      parts.add('💵 \$${(u['costUsd'] as num).toStringAsFixed(6)}');
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.only(top: 6),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: _border)),
        ),
        child: Text('🔢 ${parts.join(' · ')}',
            style: const TextStyle(fontSize: 11, color: _textDim)),
      ),
    );
  }
}
