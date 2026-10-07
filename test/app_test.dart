import 'package:assistant/models/models.dart';
import 'package:assistant/services/chat_session.dart';
import 'package:assistant/services/chat_stream_client.dart';
import 'package:assistant/services/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('ChatStreamClient.parseChunk', () {
    test('reads content', () {
      final d = ChatStreamClient.parseChunk(
        '{"choices":[{"delta":{"content":"hi"}}]}',
      );
      expect(d?.content, 'hi');
      expect(d?.reasoning, isNull);
    });

    test('reads reasoning under any known field name', () {
      for (final key in [
        'reasoning_content',
        'reasoning',
        'reasoning_text',
        'thinking',
      ]) {
        final d = ChatStreamClient.parseChunk(
          '{"choices":[{"delta":{"$key":"hmm"}}]}',
        );
        expect(d?.reasoning, 'hmm', reason: key);
      }
    });

    test('ignores empty and malformed chunks', () {
      expect(ChatStreamClient.parseChunk('{"choices":[]}'), isNull);
      expect(
        ChatStreamClient.parseChunk('{"choices":[{"delta":{"content":null}}]}'),
        isNull,
      );
      expect(ChatStreamClient.parseChunk('not json'), isNull);
    });

    test('throws on error payloads', () {
      expect(
        () => ChatStreamClient.parseChunk('{"error":{"message":"bad"}}'),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('ChatStreamClient.splitThinkTags', () {
    test('plain answer', () {
      expect(ChatStreamClient.splitThinkTags('hello'), ('', 'hello'));
    });

    test('complete think block', () {
      expect(
        ChatStreamClient.splitThinkTags('<think> plan </think>\n\nanswer'),
        ('plan', 'answer'),
      );
    });

    test('opening tag still arriving', () {
      expect(ChatStreamClient.splitThinkTags('<thi'), ('', ''));
    });

    test('closing tag still arriving is hidden', () {
      expect(ChatStreamClient.splitThinkTags('<think>plan</th'), ('plan', ''));
    });

    test('missing opening tag', () {
      expect(ChatStreamClient.splitThinkTags('plan</think>answer'), (
        'plan',
        'answer',
      ));
    });
  });

  group('Storage and ChatSession', () {
    late Storage storage;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      storage = Storage(await SharedPreferences.getInstance());
    });

    test('chat lifecycle', () async {
      final chat = await storage.addChat('First');
      expect(storage.chats.map((c) => c.name), ['First']);

      await storage.saveMessages(chat.id, [
        ChatMessage(text: 'q', isBot: false),
        ChatMessage(text: 'a', isBot: true),
      ]);
      await storage.saveChatSettings(chat.id, ChatSettings(model: 'm1'));

      await storage.renameChat(chat, 'Second');
      final renamed = storage.chats.single;
      expect(renamed.name, 'Second');
      expect(storage.messages(renamed.id).length, 2);
      expect(storage.chatSettings(renamed.id).model, 'm1');
      expect(storage.messages(chat.id), isEmpty);

      await storage.togglePin(renamed);
      expect(storage.chats.single.pinned, isTrue);

      await storage.deleteChat(storage.chats.single);
      expect(storage.chats, isEmpty);
    });

    test('availableChatName skips used names', () async {
      await storage.addChat('New chat 1');
      expect(storage.availableChatName(), 'New chat 2');
    });

    test('request omits defaults and includes overrides', () {
      final session = ChatSession(storage, 'x');
      final history = [ChatMessage(text: 'hi', isBot: false)];

      var body = session.buildRequest(ChatSettings(model: 'gpt-4o'), history);
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
      expect((body['messages'] as List).length, 1);

      body = session.buildRequest(
        ChatSettings(
          model: 'gpt-4o',
          temperature: 1.2,
          topP: 0.5,
          seed: '7',
          systemMessage: 'be brief',
        ),
        history,
      );
      expect(body['temperature'], 1.2);
      expect(body['top_p'], 0.5);
      expect(body['seed'], 7);
      expect((body['messages'] as List).first, {
        'role': 'system',
        'content': 'be brief',
      });

      body = session.buildRequest(
        ChatSettings(model: 'o3-mini', temperature: 0.2),
        history,
      );
      expect(body['temperature'], 1.0);
      session.dispose();
    });
  });
}
