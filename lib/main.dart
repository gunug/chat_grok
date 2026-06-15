import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';
import 'storage.dart';
import 'chat_service.dart';
import 'pending_chat.dart';
import 'image_service.dart';
import 'image_store.dart';
import 'gallery_screen.dart';
import 'settings_screen.dart';
import 'credits_screen.dart';
import 'credits.dart';
import 'login_screen.dart';
import 'debug_log.dart';
import 'purchase_service.dart';
import 'supa.dart';

final store = Store();

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // 모든 Flutter/비동기 예외를 인앱 로그로 잡는다.
    FlutterError.onError = (details) {
      logD('FlutterError: ${details.exceptionAsString()}');
      FlutterError.presentError(details);
    };
    logD('app start');
    await store.init();
    try {
      await initSupabase(store.supabaseUrl, store.anonKey);
      logD('supabase init ok');
    } catch (e) {
      logD('supabase init FAIL: $e');
    }
    PurchaseService.instance.init(); // 결제 스트림 구독(보류/복원 처리)
    runApp(const GrokApp());
  }, (e, st) {
    logD('Uncaught: $e');
    logD('$st');
  });
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
      title: 'simple chat bot',
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
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      final u = data.session?.user;
      logD('authState: ${data.event} user=${u?.id ?? "null"} '
          'anon=${u?.isAnonymous ?? "-"} email=${u?.email ?? "-"}');
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
    final logged = isLoggedIn;
    logD('AuthGate build: loggedIn=$logged');
    return logged ? const ChatScreen() : const LoginScreen();
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _streaming = false;
  bool _generatingImage = false;

  Conversation? get _conv => store.active;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refreshCredit(); // 로그인 후 잔액 로드
    // 백그라운드에서 서버가 완료해 둔 답변이 있으면 이어받는다.
    WidgetsBinding.instance.addPostFrameCallback((_) => _reconcileAllPending());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 포그라운드 복귀 시 미완료(pending) 답변을 서버에서 이어받는다.
    if (state == AppLifecycleState.resumed) _reconcileAllPending();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
      }
    });
  }

  // user/완료된 assistant 메시지만 추려 xAI에 보낼 히스토리를 만든다.
  List<Map<String, dynamic>> _history(Conversation conv) {
    return conv.messages
        .where((m) =>
            m.role == 'user' ||
            (m.role == 'assistant' &&
                m.imagePath == null &&
                m.content.trim().isNotEmpty &&
                (m.status == null || m.status == 'done')))
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _streaming) return;
    if (currentAccessToken() == null) return; // 안전장치

    _input.clear();
    final conv = store.ensureActive();
    conv.messages.add(Message('user', text));
    conv.retitleIfNeeded();
    conv.updatedAt = DateTime.now().millisecondsSinceEpoch;

    final history = _history(conv); // bot 추가 전에 계산
    await _streamInto(conv, history);
  }

  // 실패(error 상태)한 봇 메시지를 같은 맥락으로 다시 요청한다.
  Future<void> _resend(Message bot) async {
    if (_streaming) return;
    final conv = _conv;
    if (conv == null) return;
    final idx = conv.messages.indexOf(bot);
    if (idx < 0) return;
    setState(() => conv.messages.removeAt(idx)); // 실패한 봇 제거
    await store.save();
    final history = _history(conv);
    await _streamInto(conv, history);
  }

  // 봇 placeholder를 추가하고 스트리밍한다. 결과:
  //  • usage 수신 → 성공(완료·과금됨)
  //  • 서버가 명시적으로 거절(serverError) → status=error(재전송 버튼)
  //  • 연결만 끊김(모호) → status=pending → 서버 결과를 이어받기(reconcile)
  Future<void> _streamInto(
      Conversation conv, List<Map<String, dynamic>> history) async {
    final token = currentAccessToken();
    if (token == null) return;
    final requestId = newRequestId();
    final bot =
        Message('assistant', '', requestId: requestId, status: 'pending');
    conv.messages.add(bot);
    setState(() => _streaming = true);
    await store.save();
    _scrollToBottom();

    Map<String, dynamic>? usage;
    String? serverError;
    try {
      await for (final e in ChatService.stream(
        supabaseUrl: store.supabaseUrl,
        anonKey: store.anonKey,
        accessToken: token,
        messages: history,
        requestId: requestId,
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
            serverError = e.error;
            break;
        }
      }
    } catch (_) {
      // 연결 끊김(백그라운드 등) → 모호. 아래에서 pending/reconcile 처리.
    }

    if (usage != null) {
      // 성공: 완료·과금됨.
      if (bot.content.isEmpty) bot.content = '(빈 응답)';
      bot.usage = usage;
      bot.status = 'done';
      bot.requestId = null;
      final total = (usage['total'] as num?)?.toInt() ?? 0;
      final cost = (usage['costUsd'] as num?)?.toDouble() ?? 0;
      conv.usageTokens += total;
      conv.usageCost += cost;
      final bal = usage['balanceCredits'];
      if (bal is num) setBalanceCredits(bal.toInt());
      PendingChat.delete(requestId); // 서버 행 정리(best-effort)
    } else if (serverError != null) {
      // 서버가 거절(402/xAI 오류 등) → 과금 없음. 재전송 가능 상태로.
      bot.status = 'error';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('⚠ $serverError'),
            backgroundColor: Colors.red[900]));
      }
    } else {
      // 모호(연결 끊김, 답변 미수신) → 서버 결과를 이어받는다.
      bot.status = 'pending';
    }

    conv.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await store.save();
    if (mounted) setState(() => _streaming = false);
    _scrollToBottom();

    if (bot.status == 'pending') await _reconcileOne(conv, bot);
  }

  // 모든 대화의 pending 봇을 서버에서 이어받는다(복귀 시 호출).
  Future<void> _reconcileAllPending() async {
    if (_streaming) return;
    for (final conv in store.conversations) {
      for (final m in conv.messages.toList()) {
        if (m.role == 'assistant' &&
            m.status == 'pending' &&
            m.requestId != null) {
          await _reconcileOne(conv, m);
        }
      }
    }
  }

  // pending 봇 하나를 cg_pending_chat에서 조회해 done/error로 확정한다.
  Future<void> _reconcileOne(Conversation conv, Message bot) async {
    final id = bot.requestId;
    if (id == null) return;
    for (var i = 0; i < 6; i++) {
      final row = await PendingChat.fetch(id);
      if (!mounted) return;
      if (row == null) {
        // 행 없음(저장 실패/이미 삭제) → 결과 확인 불가 → 재전송 유도.
        setState(() => bot.status = 'error');
        await store.save();
        return;
      }
      final st = row['status'] as String?;
      if (st == 'done') {
        final content = row['content'] as String?;
        final usage = row['usage'];
        setState(() {
          if (content != null && content.isNotEmpty) bot.content = content;
          if (bot.content.isEmpty) bot.content = '(빈 응답)';
          if (usage is Map) bot.usage = Map<String, dynamic>.from(usage);
          bot.status = 'done';
          bot.requestId = null;
        });
        if (usage is Map) {
          final total = (usage['total'] as num?)?.toInt() ?? 0;
          final cost = (usage['costUsd'] as num?)?.toDouble() ?? 0;
          conv.usageTokens += total;
          conv.usageCost += cost;
          final bal = usage['balanceCredits'];
          if (bal is num) setBalanceCredits(bal.toInt());
        }
        await store.save();
        PendingChat.delete(id);
        _scrollToBottom();
        return;
      }
      if (st == 'error') {
        setState(() => bot.status = 'error');
        await store.save();
        PendingChat.delete(id);
        return;
      }
      // streaming/finalizing → 잠시 후 재조회.
      await Future.delayed(const Duration(milliseconds: 1500));
    }
    // 폴링 종료까지 미완료면 pending 유지(다음 복귀 때 다시 시도).
  }

  // 지금까지의 대화를 바탕으로 마지막 장면을 이미지로 생성한다.
  // 1) 전송될 프롬프트를 먼저 만들어 사용자에게 보여주고(영어+한글),
  // 2) 확인하면 렌더한다. 차단되더라도 API 비용으로 크레딧이 차감된다.
  Future<void> _generateImage() async {
    if (_streaming || _generatingImage) return;
    final conv = _conv;
    if (conv == null || conv.messages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('먼저 대화를 시작하세요. 마지막 장면을 이미지로 만들어 드립니다.'),
      ));
      return;
    }
    final token = currentAccessToken();
    if (token == null) return;

    setState(() => _generatingImage = true);

    final history = conv.messages
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();

    // 1단계: 프롬프트 생성(과금 없음).
    ComposedPrompt composed;
    try {
      composed = await ImageService.compose(
        supabaseUrl: store.supabaseUrl,
        anonKey: store.anonKey,
        accessToken: token,
        messages: history,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('⚠ $e'), backgroundColor: Colors.red[900]),
        );
        setState(() => _generatingImage = false);
      }
      return;
    }
    // 프롬프트 생성에도 비용이 들었으므로 차감된 잔액을 즉시 반영.
    if (composed.balanceCredits != null) {
      setBalanceCredits(composed.balanceCredits!);
    }

    // 확인창: 전송 프롬프트 + 한글 번역 + 차단 시에도 과금됨 안내.
    final go = mounted ? await _confirmImageDialog(composed) : false;
    if (!go) {
      if (mounted) setState(() => _generatingImage = false);
      return;
    }

    // 2단계: 렌더(성공/차단 무관 과금).
    final bot = Message('assistant', '🖼 마지막 장면을 그리는 중…');
    conv.messages.add(bot);
    await store.save();
    _scrollToBottom();

    try {
      final result = await ImageService.render(
        supabaseUrl: store.supabaseUrl,
        anonKey: store.anonKey,
        accessToken: token,
        prompt: composed.prompt,
      );
      if (result.balanceCredits != null) {
        setBalanceCredits(result.balanceCredits!);
      }
      if (result.blocked || result.bytes == null) {
        conv.messages.remove(bot);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: Colors.orange[900],
            content: Text(
                '이미지가 xAI 정책상 차단되었습니다. API 비용이 부과되어 '
                '${result.creditsCharged ?? 0} 크레딧이 차감되었습니다.'),
          ));
        }
      } else {
        final path = await ImageStore.save(result.bytes!, result.prompt);
        bot.content = '';
        bot.imagePath = path;
      }
    } catch (e) {
      conv.messages.remove(bot);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('⚠ $e'), backgroundColor: Colors.red[900]),
        );
      }
    }
    conv.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await store.save();
    if (mounted) setState(() => _generatingImage = false);
    _scrollToBottom();
  }

  // 전송될 프롬프트와 한글 번역을 보여주고 생성 여부를 확인받는다.
  Future<bool> _confirmImageDialog(ComposedPrompt c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _panel,
        title: const Text('이미지 생성 확인'),
        content: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.6),
          child: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 프롬프트는 스크롤 가능 영역.
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('전송 프롬프트',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold,
                                color: _textDim)),
                        const SizedBox(height: 4),
                        SelectableText(c.prompt,
                            style: const TextStyle(fontSize: 13, height: 1.4)),
                        if (c.promptKo.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          const Text('한글 번역',
                              style: TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.bold,
                                  color: _textDim)),
                          const SizedBox(height: 4),
                          SelectableText(c.promptKo,
                              style:
                                  const TextStyle(fontSize: 13, height: 1.4)),
                        ],
                      ],
                    ),
                  ),
                ),
                // 주의 문구 + 차감 예정 크레딧: 스크롤과 무관하게 버튼 바로 위 고정.
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0x33FF9800),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0x66FF9800)),
                  ),
                  child: Text(
                    '⚠ 프롬프트 생성에 ${c.creditsCharged ?? 0} 크레딧이 차감되었습니다.\n'
                    '‘생성하기’를 누르면 이미지 생성에 약 ${c.imageCredits ?? '?'} 크레딧이 '
                    '추가로 차감되며, xAI 정책상 차단되더라도 비용은 동일하게 부과됩니다.',
                    style: const TextStyle(fontSize: 12.5, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: _accent),
            child: const Text('생성하기'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  void _openGallery() => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const GalleryScreen()),
      );

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

  void _openLogs() => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const DebugLogScreen()),
      );

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
        title: Text(conv?.title ?? 'simple chat bot',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17)),
        actions: [
          const CreditBadge(),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'gallery') _openGallery();
              if (v == 'md') _export(false);
              if (v == 'json') _export(true);
              if (v == 'credits') _openCredits();
              if (v == 'settings') _openSettings();
              if (v == 'logs') _openLogs();
              if (v == 'logout') _logout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'gallery', child: Text('이미지 갤러리')),
              PopupMenuItem(value: 'md', child: Text('Markdown 내보내기')),
              PopupMenuItem(value: 'json', child: Text('JSON 내보내기')),
              PopupMenuItem(value: 'credits', child: Text('크레딧')),
              PopupMenuItem(value: 'settings', child: Text('설정')),
              PopupMenuItem(value: 'logs', child: Text('로그')),
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
                    itemBuilder: (_, i) => _Bubble(
                      message: messages[i],
                      onResend: messages[i].status == 'error'
                          ? () => _resend(messages[i])
                          : null,
                    ),
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
            SizedBox(
              width: 46,
              height: 46,
              child: OutlinedButton(
                onPressed:
                    (_streaming || _generatingImage) ? null : _generateImage,
                style: OutlinedButton.styleFrom(
                  foregroundColor: _accent,
                  side: const BorderSide(color: _border),
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _generatingImage
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _accent))
                    : const Icon(Icons.image_outlined, size: 20),
              ),
            ),
            const SizedBox(width: 8),
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
  final VoidCallback? onResend; // status=='error'일 때 재전송
  const _Bubble({required this.message, this.onResend});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final isFailed = message.status == 'error';
    final isPending = message.status == 'pending';
    final isError = isFailed || message.content.startsWith('⚠');
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
                  if (message.imagePath != null) _image(message.imagePath!),
                  if (message.content.isNotEmpty)
                    SelectableText(
                      message.content,
                      style: TextStyle(
                          color:
                              isError ? const Color(0xFFFF9B8E) : Colors.white,
                          height: 1.5),
                    )
                  else if (message.imagePath == null && !isFailed)
                    SelectableText(message.content.isEmpty ? '…' : '',
                        style: const TextStyle(color: Colors.white, height: 1.5)),
                  if (isPending) _pendingLine(),
                  if (isFailed) _failedLine(),
                  if (u != null) _usageLine(u),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pendingLine() {
    return const Padding(
      padding: EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: _textDim)),
          SizedBox(width: 8),
          Flexible(
            child: Text('응답을 기다리는 중… (앱을 다시 열면 이어받아요)',
                style: TextStyle(fontSize: 12, color: _textDim)),
          ),
        ],
      ),
    );
  }

  Widget _failedLine() {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('⚠ 전송에 실패했어요',
              style: TextStyle(fontSize: 12, color: Color(0xFFFF9B8E))),
          const SizedBox(width: 8),
          if (onResend != null)
            TextButton.icon(
              onPressed: onResend,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('재전송'),
              style: TextButton.styleFrom(
                foregroundColor: _accent,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
        ],
      ),
    );
  }

  Widget _image(String path) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          padding: const EdgeInsets.all(16),
          alignment: Alignment.center,
          child: const Text('이미지를 불러올 수 없습니다 (삭제됨).',
              style: TextStyle(color: _textDim, fontSize: 12)),
        ),
      ),
    );
  }

  Widget _usageLine(Map<String, dynamic> u) {
    final parts = <String>[
      '입력 ${u['prompt']}${(u['cached'] ?? 0) > 0 ? ' (캐시 ${u['cached']})' : ''}',
      '출력 ${u['completion']}${(u['reasoning'] ?? 0) > 0 ? ' (추론 ${u['reasoning']})' : ''}',
      '합계 ${u['total']} tok',
    ];
    if (u['creditsCharged'] != null) {
      parts.add('💳 ${u['creditsCharged']} 크레딧');
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
