// Smoke test for the Grok Chat app.

import 'package:flutter_test/flutter_test.dart';

import 'package:chat_grok/models.dart';

void main() {
  test('Conversation auto-titles from the first user message', () {
    final c = Conversation.create();
    expect(c.title, '새 대화');
    c.messages.add(Message('user', '세금 관련 질문이 있어요'));
    c.retitleIfNeeded();
    expect(c.title, '세금 관련 질문이 있어요');
  });

  test('Conversation round-trips through JSON', () {
    final c = Conversation.create()
      ..messages.add(Message('user', 'hi'))
      ..messages.add(Message('assistant', 'hello', usage: {'total': 10}))
      ..usageTokens = 10
      ..usageCost = 0.0001;
    final back = Conversation.fromJson(c.toJson());
    expect(back.messages.length, 2);
    expect(back.usageTokens, 10);
    expect(back.messages[1].usage?['total'], 10);
  });
}
