import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';
import 'storage.dart';
import 'chat_service.dart';
import 'models_catalog.dart';
import 'pending_chat.dart';
import 'image_service.dart';
import 'image_store.dart';
import 'prompt_store.dart';
import 'gallery_screen.dart';
import 'prompt_history_screen.dart';
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

// 이미지 생성 버튼 노출 여부. 기능 코드(image_service/gallery 등)는 유지하고
// 진입 버튼만 숨긴다 — 나중에 true로 되돌리면 즉시 복구.
const bool _showImageButton = false;

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
  bool _atBottom = true; // "맨 아래로" 버튼 표시용
  // 전송한 질문을 화면 상단에 고정하기 위한 앵커(생성 중 화면은 움직이지 않음).
  Message? _anchorMsg;
  final _anchorKey = GlobalKey();
  List<ChatModel> _models = const []; // cg_models에서 로드한 선택 가능한 모델
  List<ImageModel> _imageModels = const []; // cg_image_models에서 로드한 이미지 모델
  double? _creditPerUsd; // $1당 차감 크레딧(마크업 반영) — 예상 단가 표시용

  Conversation? get _conv => store.active;
  bool get _isImageConv => _conv?.isImage ?? false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    refreshCredit(); // 로그인 후 잔액 로드
    fetchModels().then((m) {
      if (mounted && m.isNotEmpty) setState(() => _models = m);
    });
    fetchImageModels().then((m) {
      if (mounted && m.isNotEmpty) setState(() => _imageModels = m);
    });
    fetchCreditPerUsd().then((f) {
      if (mounted && f != null) setState(() => _creditPerUsd = f);
    });
    // 백그라운드에서 서버가 완료해 둔 답변이 있으면 이어받는다.
    WidgetsBinding.instance.addPostFrameCallback((_) => _reconcileAllPending());
  }

  String get _modelLabel {
    final id = store.model;
    for (final m in _models) {
      if (m.id == id) return m.label;
    }
    return id;
  }

  String get _imageModelLabel {
    final id = store.imageModel;
    for (final m in _imageModels) {
      if (m.id == id) return m.label;
    }
    return id;
  }

  // 이미지 모델별 1장당 예상 크레딧(마크업 반영). 가격/환산계수 없으면 빈 문자열.
  String _imageModelPriceLine(ImageModel m) {
    final f = _creditPerUsd;
    if (f == null || m.priceUsd == null) return '';
    return '≈ 1장당 ${formatCredits((m.priceUsd! * f).round())} 크레딧';
  }

  // 이미지 모델 선택 시트(provider별 표시).
  Future<void> _pickImageModel() async {
    final models = _imageModels.isNotEmpty
        ? _imageModels
        : [ImageModel(id: store.imageModel, provider: '', label: store.imageModel)];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text('이미지 모델 선택',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              for (final m in models)
                ListTile(
                  onTap: () async {
                    final nav = Navigator.of(context);
                    await store.setImageModel(m.id);
                    nav.pop();
                    if (mounted) setState(() {});
                  },
                  title: Text(m.label),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (m.provider.isNotEmpty)
                        Text(m.provider == 'openai' ? 'OpenAI' : 'xAI (Grok)',
                            style: const TextStyle(
                                fontSize: 11, color: _textDim)),
                      if (_imageModelPriceLine(m).isNotEmpty)
                        Text(_imageModelPriceLine(m),
                            style: const TextStyle(
                                fontSize: 11, color: _textDim)),
                    ],
                  ),
                  trailing: m.id == store.imageModel
                      ? const Icon(Icons.check, color: _accent)
                      : null,
                ),
            ],
          ),
        );
      },
    );
  }

  // 대화 이미지 모드 모델 시트: 프롬프트 생성 모델(cg_models) + 이미지 모델
  // (cg_image_models)을 한 시트에서 함께 고른다.
  Future<void> _pickImageChatModels() async {
    final chatModels = _models.isNotEmpty
        ? _models
        : [ChatModel(id: store.promptModel, provider: '', label: store.promptModel)];
    final imgModels = _imageModels.isNotEmpty
        ? _imageModels
        : [ImageModel(id: store.imageModel, provider: '', label: store.imageModel)];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setSheet) {
              return ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.8),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text('프롬프트 생성 모델',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    for (final m in chatModels)
                      ListTile(
                        dense: true,
                        onTap: () async {
                          await store.setPromptModel(m.id);
                          setSheet(() {});
                          if (mounted) setState(() {});
                        },
                        title: Text(m.label),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (m.provider.isNotEmpty)
                              Text(
                                  m.provider == 'openai'
                                      ? 'OpenAI'
                                      : 'xAI (Grok)',
                                  style: const TextStyle(
                                      fontSize: 11, color: _textDim)),
                            if (_modelPriceLine(m).isNotEmpty)
                              Text(_modelPriceLine(m),
                                  style: const TextStyle(
                                      fontSize: 11, color: _textDim)),
                          ],
                        ),
                        trailing: m.id == store.promptModel
                            ? const Icon(Icons.check, color: _accent)
                            : null,
                      ),
                    const Divider(color: _border, height: 16),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: Text('이미지 모델',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    for (final m in imgModels)
                      ListTile(
                        dense: true,
                        onTap: () async {
                          await store.setImageModel(m.id);
                          setSheet(() {});
                          if (mounted) setState(() {});
                        },
                        title: Text(m.label),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (m.provider.isNotEmpty)
                              Text(
                                  m.provider == 'openai'
                                      ? 'OpenAI'
                                      : 'xAI (Grok)',
                                  style: const TextStyle(
                                      fontSize: 11, color: _textDim)),
                            if (_imageModelPriceLine(m).isNotEmpty)
                              Text(_imageModelPriceLine(m),
                                  style: const TextStyle(
                                      fontSize: 11, color: _textDim)),
                          ],
                        ),
                        trailing: m.id == store.imageModel
                            ? const Icon(Icons.check, color: _accent)
                            : null,
                      ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  // 모델별 예상 단가(마크업 반영 크레딧, 1K토큰당). 입력·출력 평균으로 합쳐
  // 단일 값 표시. 단가/환산계수 없으면 빈 문자열.
  String _modelPriceLine(ChatModel m) {
    final f = _creditPerUsd;
    if (f == null || m.inputRate == null || m.outputRate == null) return '';
    final avgPerMtok = (m.inputRate! + m.outputRate!) / 2; // USD/1M
    final per1k = (avgPerMtok * f / 1000).round();
    return '≈ 1K토큰당 ${formatCredits(per1k)} 크레딧';
  }

  // 모델 선택 시트(provider별 그룹).
  Future<void> _pickModel() async {
    final models = _models.isNotEmpty
        ? _models
        : [ChatModel(id: store.model, provider: '', label: store.model)];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text('모델 선택',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              for (final m in models)
                ListTile(
                  onTap: () async {
                    final nav = Navigator.of(context);
                    await store.setModel(m.id);
                    nav.pop();
                    if (mounted) setState(() {});
                  },
                  title: Text(m.label),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (m.provider.isNotEmpty)
                        Text(m.provider == 'openai' ? 'OpenAI' : 'xAI (Grok)',
                            style: const TextStyle(
                                fontSize: 11, color: _textDim)),
                      if (_modelPriceLine(m).isNotEmpty)
                        Text(_modelPriceLine(m),
                            style: const TextStyle(
                                fontSize: 11, color: _textDim)),
                    ],
                  ),
                  trailing: m.id == store.model
                      ? const Icon(Icons.check, color: _accent)
                      : null,
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom =
        (_scroll.position.maxScrollExtent - _scroll.position.pixels) <= 80;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
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
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  // 방금 보낸 질문을 화면 상단으로 올린다. 이후 답변은 그 아래로 채워지며
  // 화면은 더 움직이지 않으므로, 사용자가 답변을 처음부터 읽을 수 있다.
  void _anchorQuestionToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _anchorKey.currentContext;
      if (ctx == null) {
        // 앵커가 아직 안 그려졌으면 최소한 바닥으로(질문이 보이도록).
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
        return;
      }
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.0, // 뷰포트 상단
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
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
    final c = _conv;
    if (c != null && c.isImagePrompt) {
      await _sendDirectImage();
      return;
    }
    if (c != null && c.isImageChat) {
      await _sendComposeImage();
      return;
    }
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

  // 선택한 이미지 모델의 1장당 예상 크레딧(없으면 null).
  int? _imageCreditEstimate() {
    final f = _creditPerUsd;
    if (f == null) return null;
    for (final m in _imageModels) {
      if (m.id == store.imageModel && m.priceUsd != null) {
        return (m.priceUsd! * f).round();
      }
    }
    return null;
  }

  // 프롬프트 이미지(직접): 입력한 프롬프트를 그대로(raw) 보낸다. compose 없음.
  // 차단돼도 과금되므로 간단한 비용 확인창만 띄운다.
  Future<void> _sendDirectImage() async {
    final text = _input.text.trim();
    if (text.isEmpty || _generatingImage || _streaming) return;
    final token = currentAccessToken();
    if (token == null) return;
    final conv = _conv;
    if (conv == null) return;

    final go = await _confirmDirectImageDialog(text);
    if (!go) return;

    _input.clear();
    conv.messages.add(Message('user', text));
    conv.retitleIfNeeded();
    conv.updatedAt = DateTime.now().millisecondsSinceEpoch;
    setState(() => _generatingImage = true);
    await store.save();
    _scrollToBottom();

    // 직접 입력 프롬프트를 히스토리에 기록(렌더 결과로 상태 갱신).
    final promptId = await PromptStore.add(
        prompt: text, model: store.imageModel, mode: 'prompt');

    await _renderInto(conv,
        prompt: text, promptKo: '', token: token, promptId: promptId);
  }

  // 대화 이미지(자동): 입력 + 이전 대화 맥락을 서버가 안전한 영문 프롬프트로
  // 변환(compose)해 확인창에 보여주고, 확인하면 렌더한다.
  Future<void> _sendComposeImage() async {
    final text = _input.text.trim();
    if (text.isEmpty || _generatingImage || _streaming) return;
    final token = currentAccessToken();
    if (token == null) return;
    final conv = _conv;
    if (conv == null) return;

    _input.clear();
    conv.messages.add(Message('user', text));
    conv.retitleIfNeeded();
    conv.updatedAt = DateTime.now().millisecondsSinceEpoch;
    setState(() => _generatingImage = true);
    await store.save();
    _scrollToBottom();

    // 1단계: 입력+맥락 → 안전한 영문 프롬프트(+한글). grok-3 토큰 비용 차감.
    // 이전 대화 맥락(비어있지 않은 메시지)을 함께 보내 여러 턴 다듬기를 지원.
    final history = conv.messages
        .where((m) => m.content.trim().isNotEmpty)
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();
    ComposedPrompt composed;
    try {
      composed = await ImageService.compose(
        supabaseUrl: store.supabaseUrl,
        anonKey: store.anonKey,
        accessToken: token,
        messages: history,
        model: store.imageModel, // 선택 모델의 1장당 예상 크레딧 미리보기용
        promptModel: store.promptModel, // 프롬프트 생성용 텍스트 모델
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('⚠ $e'), backgroundColor: Colors.red[900]),
        );
        setState(() => _generatingImage = false);
      }
      await store.save();
      return;
    }
    // compose에도 비용이 들었으므로 차감된 잔액/누적을 즉시 반영.
    if (composed.balanceCredits != null) {
      setBalanceCredits(composed.balanceCredits!);
    }
    conv.usageCredits += composed.creditsCharged ?? 0;

    // 프롬프트가 만들어진 즉시 히스토리에 기록 → 아래에서 생성을 포기(취소)해도
    // 'composed'(프롬프트만) 상태로 남는다. 생성하면 결과로 상태 갱신.
    final promptId = await PromptStore.add(
        prompt: composed.prompt,
        promptKo: composed.promptKo,
        model: store.imageModel,
        mode: 'chat');

    // 확인창: 영문 프롬프트 + 한글 번역 + 예상 크레딧/차단 시에도 과금 고지.
    final go = mounted ? await _confirmImageDialog(composed) : false;
    if (!go) {
      if (mounted) setState(() => _generatingImage = false);
      return; // 프롬프트만 기록된 채로 종료(포기).
    }

    await _renderInto(conv,
        prompt: composed.prompt,
        promptKo: composed.promptKo,
        token: token,
        promptId: promptId);
  }

  // 확인된 프롬프트로 렌더 → 성공 시 이미지 저장, 차단/오류 처리. 두 이미지
  // 모드가 공유한다. 호출 전 _generatingImage=true 가정, 끝나면 false로 해제.
  Future<void> _renderInto(Conversation conv,
      {required String prompt,
      required String promptKo,
      required String token,
      String? promptId}) async {
    final bot = Message('assistant', '🖼 이미지를 생성하는 중…');
    conv.messages.add(bot);
    await store.save();
    _scrollToBottom();

    String status = 'failed';
    try {
      final result = await ImageService.render(
        supabaseUrl: store.supabaseUrl,
        anonKey: store.anonKey,
        accessToken: token,
        prompt: prompt,
        model: store.imageModel,
      );
      if (result.balanceCredits != null) {
        setBalanceCredits(result.balanceCredits!);
      }
      conv.usageCredits += result.creditsCharged ?? 0;
      if (result.blocked || result.bytes == null) {
        status = result.blocked ? 'blocked' : 'failed';
        conv.messages.remove(bot);
        if (mounted) {
          final charged = result.creditsCharged ?? 0;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: Colors.orange[900],
            content: Text(charged > 0
                ? '이미지가 정책상 차단되었습니다. API 비용이 부과되어 '
                    '$charged 크레딧이 차감되었습니다.'
                : '이미지가 정책상 차단되었습니다. (과금 없음)'),
          ));
        }
      } else {
        status = 'success';
        final path = await ImageStore.save(result.bytes!, result.prompt,
            promptKo: promptKo);
        bot.content = '';
        bot.imagePath = path;
      }
    } catch (e) {
      status = 'failed';
      conv.messages.remove(bot);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('⚠ $e'), backgroundColor: Colors.red[900]),
        );
      }
    }
    if (promptId != null) await PromptStore.updateStatus(promptId, status);
    conv.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await store.save();
    if (mounted) setState(() => _generatingImage = false);
    _scrollToBottom();
  }

  // 프롬프트 이미지(직접) 모드의 간단 비용 확인창.
  Future<bool> _confirmDirectImageDialog(String prompt) async {
    final est = _imageCreditEstimate();
    final estText = est != null ? formatCredits(est) : '?';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _panel,
        title: const Text('이미지 생성 확인'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('전송 프롬프트',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: _textDim)),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.35),
              child: SingleChildScrollView(
                child: SelectableText(prompt,
                    style: const TextStyle(fontSize: 13, height: 1.4)),
              ),
            ),
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
                '⚠ 이미지 생성에 약 $estText 크레딧이 차감되며, 정책상 '
                '차단되더라도 비용이 부과될 수 있습니다(입력 그대로 전송).',
                style: const TextStyle(fontSize: 12.5, height: 1.5),
              ),
            ),
          ],
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
    // 답변 대상 질문(가장 최근 user 메시지)을 상단 고정 앵커로.
    final lastUserIdx = conv.messages.lastIndexWhere((m) => m.role == 'user');
    _anchorMsg = lastUserIdx >= 0 ? conv.messages[lastUserIdx] : null;
    conv.messages.add(bot);
    setState(() => _streaming = true);
    await store.save();
    // 질문을 화면 상단으로. 이후 생성 중에는 화면을 움직이지 않는다.
    _anchorQuestionToTop();

    Map<String, dynamic>? usage;
    String? serverError;
    try {
      await for (final e in ChatService.stream(
        supabaseUrl: store.supabaseUrl,
        anonKey: store.anonKey,
        accessToken: token,
        messages: history,
        requestId: requestId,
        model: store.model,
      )) {
        switch (e.type) {
          case 'delta':
            // 생성 중에는 따라 내려가지 않는다(사용자가 읽는 위치 유지).
            setState(() => bot.content += e.delta!);
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
      final charged = (usage['creditsCharged'] as num?)?.toInt() ?? 0;
      conv.usageCredits += charged;
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
    // 완료 시에도 화면은 움직이지 않는다(질문 상단 고정 유지).

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
          final charged = (usage['creditsCharged'] as num?)?.toInt() ?? 0;
          conv.usageCredits += charged;
          final bal = usage['balanceCredits'];
          if (bal is num) setBalanceCredits(bal.toInt());
        }
        await store.save();
        PendingChat.delete(id);
        // 백그라운드 복귀로 채워진 답변이므로 화면을 끌어내리지 않는다.
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
    // 프롬프트 생성에도 비용이 들었으므로 차감된 잔액을 즉시 반영 + 대화 누적.
    if (composed.balanceCredits != null) {
      setBalanceCredits(composed.balanceCredits!);
    }
    conv.usageCredits += composed.creditsCharged ?? 0;

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
        model: store.imageModel,
      );
      if (result.balanceCredits != null) {
        setBalanceCredits(result.balanceCredits!);
      }
      conv.usageCredits += result.creditsCharged ?? 0;
      if (result.blocked || result.bytes == null) {
        conv.messages.remove(bot);
        if (mounted) {
          final charged = result.creditsCharged ?? 0;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: Colors.orange[900],
            content: Text(charged > 0
                ? '이미지가 정책상 차단되었습니다. API 비용이 부과되어 '
                    '$charged 크레딧이 차감되었습니다.'
                : '이미지가 정책상 차단되었습니다. (과금 없음)'),
          ));
        }
      } else {
        final path = await ImageStore.save(result.bytes!, result.prompt,
            promptKo: composed.promptKo);
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

  void _openPromptHistory() => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const PromptHistoryScreen()),
      );

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

  void _newPromptImage() {
    setState(() => store.createConversation(kind: 'image_prompt'));
    Navigator.pop(context); // close drawer
  }

  void _newChatImage() {
    setState(() => store.createConversation(kind: 'image_chat'));
    Navigator.pop(context); // close drawer
  }

  void _selectConv(String id) {
    setState(() => store.activeId = id);
    store.save();
    Navigator.pop(context);
    // 이전 대화를 열면 가장 최근 메시지가 보이도록 바닥으로(애니메이션 없이 즉시).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _deleteConv(String id) {
    setState(() => store.remove(id));
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
              if (v == 'prompts') _openPromptHistory();
              if (v == 'credits') _openCredits();
              if (v == 'logs') _openLogs();
              if (v == 'logout') _logout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'gallery', child: Text('이미지 갤러리')),
              PopupMenuItem(value: 'prompts', child: Text('프롬프트 히스토리')),
              PopupMenuItem(value: 'credits', child: Text('크레딧')),
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
                ? _EmptyState(kind: conv?.kind ?? 'chat')
                : Stack(
                    children: [
                      ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(16),
                        itemCount: messages.length,
                        itemBuilder: (_, i) => _Bubble(
                          key: messages[i] == _anchorMsg ? _anchorKey : null,
                          message: messages[i],
                          onResend: messages[i].status == 'error'
                              ? () => _resend(messages[i])
                              : null,
                        ),
                      ),
                      if (!_atBottom)
                        Positioned(
                          right: 12,
                          bottom: 12,
                          child: _ScrollToBottomButton(onTap: () {
                            if (_scroll.hasClients) {
                              _scroll.animateTo(
                                _scroll.position.maxScrollExtent,
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeOut,
                              );
                            }
                          }),
                        ),
                    ],
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
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _newPromptImage,
                  icon: const Icon(Icons.brush_outlined),
                  label: const Text('프롬프트 이미지'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: _border),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    alignment: Alignment.centerLeft,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _newChatImage,
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: const Text('대화 이미지'),
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
                    leading: Icon(
                      c.isImagePrompt
                          ? Icons.brush_outlined
                          : c.isImageChat
                              ? Icons.auto_awesome_outlined
                              : Icons.chat_bubble_outline,
                      size: 20,
                      color: _textDim,
                    ),
                    title: Text(c.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: (c.usageTokens > 0 || c.usageCredits > 0)
                        ? Text(
                            '${c.usageTokens} tok · 💳 ${formatCredits(c.usageCredits)} 크레딧',
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
            // 이미지 생성 진입 버튼(현재 숨김 — _showImageButton로 토글).
            if (_showImageButton) ...[
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
            ],
            // 모델 선택 버튼 (입력창 왼쪽). 채팅 대화는 채팅 모델, 이미지
            // 대화는 이미지 모델 선택 버튼을 보여준다.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 124),
              child: OutlinedButton(
                onPressed: (_streaming || _generatingImage)
                    ? null
                    : ((_conv?.isImageChat ?? false)
                        ? _pickImageChatModels
                        : _isImageConv
                            ? _pickImageModel
                            : _pickModel),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _textDim,
                  side: const BorderSide(color: _border),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 46),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_isImageConv ? Icons.image_outlined : Icons.tune,
                        size: 16),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(_isImageConv ? _imageModelLabel : _modelLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
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
                  hintText: (_conv?.isImagePrompt ?? false)
                      ? '이미지 프롬프트를 입력하세요 (영문 권장)…'
                      : (_conv?.isImageChat ?? false)
                          ? '만들 이미지를 설명하세요…'
                          : '메시지를 입력하세요…',
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
                onPressed: (_streaming || _generatingImage) ? null : _send,
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: (_streaming || _generatingImage)
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

// 사용자가 위로 올라가 있을 때만 보이는 "맨 아래로 ↓" 버튼.
class _ScrollToBottomButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ScrollToBottomButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _panel2,
      shape: const CircleBorder(side: BorderSide(color: _border)),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.all(10),
          child: Icon(Icons.arrow_downward, size: 22, color: Colors.white),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String kind; // 'chat' | 'image_prompt' | 'image_chat'
  const _EmptyState({this.kind = 'chat'});
  @override
  Widget build(BuildContext context) {
    final isPrompt = kind == 'image_prompt';
    final isChatImage = kind == 'image_chat';
    final title = isPrompt
        ? '프롬프트로 이미지 만들기'
        : isChatImage
            ? '대화로 이미지 만들기'
            : '무엇을 도와드릴까요?';
    final sub = isPrompt
        ? '생성할 이미지의 프롬프트를 직접 입력하세요 (영문 권장).'
        : isChatImage
            ? '만들고 싶은 이미지를 설명하면 AI가 프롬프트를 만들어 드려요.'
            : '선택한 AI 모델에게 무엇이든 물어보세요.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(sub,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _textDim)),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final Message message;
  final VoidCallback? onResend; // status=='error'일 때 재전송
  const _Bubble({super.key, required this.message, this.onResend});

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
                  if (message.imagePath != null)
                    _downloadButton(context, message.imagePath!),
                  if (message.content.trim().isNotEmpty)
                    _copyButton(context),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 생성된 이미지를 기기 갤러리에 저장(다운로드)하는 버튼.
  Widget _downloadButton(BuildContext context, String path) {
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: () => _downloadImage(context, path),
        icon: const Icon(Icons.download, size: 16),
        label: const Text('다운로드'),
        style: TextButton.styleFrom(
          foregroundColor: _accent,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  Future<void> _downloadImage(BuildContext context, String path) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Gal.putImage(path);
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

  // 메시지 본문을 클립보드로 복사하는 버튼(텍스트가 있을 때만 노출).
  Widget _copyButton(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          Clipboard.setData(ClipboardData(text: message.content));
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('복사되었습니다'),
            duration: Duration(seconds: 1),
          ));
        },
        child: const Padding(
          padding: EdgeInsets.only(top: 6, left: 6, right: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.copy, size: 14, color: _textDim),
              SizedBox(width: 4),
              Text('복사', style: TextStyle(fontSize: 11, color: _textDim)),
            ],
          ),
        ),
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
