// Data models for conversations, messages, and usage — mirrors the web app's
// localStorage shape so behaviour stays identical.

class Message {
  final String role; // 'user' | 'assistant'
  String content;
  Map<String, dynamic>? usage; // 봇 답변의 토큰/비용(있을 때만)
  String? imagePath; // 생성된 이미지의 기기 내 파일 경로(있을 때만)
  // 서버-완료-저장용. assistant 메시지에서:
  //  status 'pending' = 서버 결과 대기(백그라운드 복귀 시 조회), 'error' = 실패(재전송),
  //  null/'done' = 완료. requestId = cg_pending_chat 행 키.
  String? requestId;
  String? status;

  Message(this.role, this.content,
      {this.usage, this.imagePath, this.requestId, this.status});

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (usage != null) 'usage': usage,
        if (imagePath != null) 'imagePath': imagePath,
        if (requestId != null) 'requestId': requestId,
        if (status != null) 'status': status,
      };

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        j['role'] as String,
        (j['content'] as String?) ?? '',
        usage: j['usage'] != null
            ? Map<String, dynamic>.from(j['usage'] as Map)
            : null,
        imagePath: j['imagePath'] as String?,
        requestId: j['requestId'] as String?,
        status: j['status'] as String?,
      );
}

class Conversation {
  String id;
  String title;
  int createdAt;
  int updatedAt;
  List<Message> messages;
  int usageTokens; // 누적 토큰
  double usageCost; // 누적 비용(USD)
  int usageCredits; // 누적 차감 크레딧

  Conversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
    this.usageTokens = 0,
    this.usageCost = 0,
    this.usageCredits = 0,
  });

  factory Conversation.create() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return Conversation(
      id: 'c${now.toRadixString(36)}',
      title: '새 대화',
      createdAt: now,
      updatedAt: now,
      messages: [],
    );
  }

  // Auto-title from the first user message (matches the web app).
  void retitleIfNeeded() {
    if (title != '새 대화') return;
    final firstUser = messages.where((m) => m.role == 'user');
    if (firstUser.isNotEmpty) {
      final t = firstUser.first.content.replaceAll(RegExp(r'\s+'), ' ').trim();
      title = t.length > 40 ? t.substring(0, 40) : t;
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'messages': messages.map((m) => m.toJson()).toList(),
        'usage': {
          'tokens': usageTokens,
          'cost': usageCost,
          'credits': usageCredits,
        },
      };

  factory Conversation.fromJson(Map<String, dynamic> j) {
    final usage = (j['usage'] as Map?) ?? const {};
    return Conversation(
      id: j['id'] as String,
      title: (j['title'] as String?) ?? '새 대화',
      createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      messages: ((j['messages'] as List?) ?? [])
          .map((e) => Message.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      usageTokens: (usage['tokens'] as num?)?.toInt() ?? 0,
      usageCost: (usage['cost'] as num?)?.toDouble() ?? 0,
      usageCredits: (usage['credits'] as num?)?.toInt() ?? 0,
    );
  }
}
