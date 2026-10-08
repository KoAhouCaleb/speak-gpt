import 'package:assistant/models/models.dart';
import 'package:assistant/services/chat_session.dart';
import 'package:assistant/services/chat_stream_client.dart';
import 'package:assistant/services/searxng_client.dart';
import 'package:assistant/services/speech_stream.dart';
import 'fake_speech_output.dart';
import 'package:assistant/services/storage.dart';
import 'package:assistant/services/tools.dart';
import 'package:assistant/util.dart';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
      List<Map<String, dynamic>> msgs(ChatSettings s) =>
          session.buildMessages(s, history);

      var s = ChatSettings(model: 'gpt-4o');
      var body = session.buildRequest(s, msgs(s));
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
      expect(body.containsKey('max_tokens'), isFalse);
      expect(body.containsKey('tools'), isFalse);
      expect((body['messages'] as List).length, 1);

      s = ChatSettings(
        model: 'gpt-4o',
        temperature: 1.2,
        topP: 0.5,
        seed: '7',
        systemMessage: 'be brief',
        maxTokens: 200,
      );
      body = session.buildRequest(s, msgs(s));
      expect(body['temperature'], 1.2);
      expect(body['top_p'], 0.5);
      expect(body['seed'], 7);
      expect(body['max_tokens'], 200);
      expect((body['messages'] as List).first, {
        'role': 'system',
        'content': 'be brief',
      });

      s = ChatSettings(model: 'o3-mini', temperature: 0.2, maxTokens: 200);
      body = session.buildRequest(s, msgs(s));
      expect(body['temperature'], 1.0);
      expect(body.containsKey('max_tokens'), isFalse);
      session.dispose();
    });

    test('logit bias set is sent', () async {
      await storage.saveLogitBiasSet(
        LogitBiasSet(id: 'b1', name: 'no', biases: {'1234': -100}),
      );
      final session = ChatSession(storage, 'x');
      final s = ChatSettings(model: 'gpt-4o', logitBiasSetId: 'b1');
      final body = session.buildRequest(s, session.buildMessages(s, []));
      expect(body['logit_bias'], {'1234': -100});
      session.dispose();
    });

    test('screen text is prepended to the user message', () {
      final session = ChatSession(storage, 'x');
      final s = ChatSettings();
      final msgs = session.buildMessages(s, [
        ChatMessage(
          text: 'summarize',
          isBot: false,
          contextText: 'Hello world',
        ),
      ]);
      final content = msgs.single['content'] as String;
      expect(content, contains('Hello world'));
      expect(content.trim(), endsWith('summarize'));
      session.dispose();
    });

    test('bot messages without text are not sent', () {
      final session = ChatSession(storage, 'x');
      final msgs = session.buildMessages(ChatSettings(), [
        ChatMessage(text: 'a', isBot: false),
        ChatMessage(text: '', isBot: true, imagePath: '/nope.png'),
      ]);
      expect(msgs.length, 1);
      session.dispose();
    });

    group('ToolCallAccumulator', () {
      test('joins fragments and fills missing ids', () {
        final acc = ToolCallAccumulator();
        acc.add(const [
          ToolCallDelta(
            index: 0,
            id: 'c1',
            name: 'search_internet',
            arguments: '{"que',
          ),
        ]);
        acc.add(const [ToolCallDelta(index: 0, arguments: 'ry":"x"}')]);
        acc.add(const [ToolCallDelta(index: 1, name: 'get_datetime')]);
        final calls = acc.build();
        expect(calls.length, 2);
        expect(calls[0].id, 'c1');
        expect(calls[0].arguments, '{"query":"x"}');
        expect(calls[1].id, 'call_1');
        expect(calls[1].arguments, '{}');
      });

      test('parseChunk reads tool call fragments', () {
        final d = ChatStreamClient.parseChunk(
          '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"f","arguments":"{}"}}]}}]}',
        );
        expect(d?.toolCalls.single.name, 'f');
        expect(d?.toolCalls.single.arguments, '{}');
      });
    });

    group('Tools', () {
      test('every tool has a valid schema', () {
        for (final t in allTools) {
          final json = t.toRequestJson();
          expect((json['function'] as Map)['name'], t.name);
          for (final r in t.required) {
            expect(t.properties.containsKey(r), isTrue, reason: '${t.name}.$r');
          }
        }
        expect(allTools.map((t) => t.name).toSet().length, allTools.length);
      });

      test('maps and music urls', () {
        final nav = mapsDirections('Eiffel Tower', 'walking', [
          'Cafe A',
          'Cafe B',
        ]);
        expect(nav.host, 'www.google.com');
        expect(nav.queryParameters['destination'], 'Eiffel Tower');
        expect(nav.queryParameters['travelmode'], 'walking');
        expect(nav.queryParameters['waypoints'], 'Cafe A|Cafe B');
        expect(
          mapsDirections('x', 'bogus', []).queryParameters['travelmode'],
          'driving',
        );

        expect(
          musicSearch(
            'Yesterday',
            type: 'song',
            artist: 'Beatles',
          ).queryParameters['q'],
          'Yesterday Beatles',
        );
        expect(
          musicSearch(
            'Beatles',
            type: 'artist',
            artist: 'Beatles',
          ).queryParameters['q'],
          'Beatles',
        );
      });

      test('navigation stops accumulate', () async {
        final launched = <Uri>[];
        final ctx = ToolContext(
          storage: storage,
          chatSettings: ChatSettings(),
          launch: (u) async {
            launched.add(u);
            return true;
          },
        );
        await toolByName('start_navigation')!.run({'destination': 'Home'}, ctx);
        await toolByName('add_navigation_stop')!.run({'stop': 'Shop'}, ctx);
        expect(launched.last.queryParameters['waypoints'], 'Shop');
        expect(launched.last.queryParameters['destination'], 'Home');
      });

      test('open_webpage rejects other schemes', () async {
        final ctx = ToolContext(
          storage: storage,
          chatSettings: ChatSettings(),
          launch: (u) async => true,
        );
        final r = await toolByName(
          'open_webpage',
        )!.run({'url': 'file:///etc/passwd'}, ctx);
        expect(r.text, contains('not valid'));
      });

      test('tool mode defaults and overrides', () async {
        final tool = toolByName('open_app')!;
        expect(tool.mode(storage), ToolMode.confirm);
        await storage.setToolMode('open_app', 'disabled');
        expect(tool.mode(storage), ToolMode.disabled);
      });
    });

    group('SearxngClient.format', () {
      test('formats answers and results', () {
        final text = SearxngClient.format({
          'answers': ['42'],
          'results': [
            {'title': 'A', 'url': 'https://a', 'content': 'about a'},
            {'title': 'B', 'url': 'https://b'},
          ],
        }, 1);
        expect(text, contains('Answers:\n- 42'));
        expect(text, contains('1. A'));
        expect(text, isNot(contains('https://b')));
      });

      test('empty result', () {
        expect(SearxngClient.format({}, 5), 'No results found.');
      });
    });

    group('util', () {
      test('plainTextForSpeech strips markdown', () {
        final t = plainTextForSpeech(
          '# Title\n\n**bold** and `code` [link](http://x)\n\n```\nx=1\n```\n- item',
        );
        expect(t, isNot(contains('*')));
        expect(t, isNot(contains('http')));
        expect(t, contains('link'));
        expect(t, contains('code block'));
        expect(t, contains('item'));
      });
    });
  });

  group('ChatSession generation', () {
    http.StreamedResponse sse(List<String> events) {
      final body =
          '${events.map((e) => 'data: $e\n\n').join()}data: [DONE]\n\n';
      return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
    }

    late Storage storage;
    late ChatInfo chat;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      storage = Storage(await SharedPreferences.getInstance());
      await storage.saveEndpoint(
        ApiEndpoint(
          label: 'Default',
          host: 'https://example.test/v1/',
          apiKey: 'sk-test',
        ),
      );
      chat = await storage.addChat('t');
    });

    test('streams an answer with reasoning', () async {
      final bodies = <Map<String, dynamic>>[];
      final session = ChatSession(
        storage,
        chat.id,
        clientFactory: () => MockClient.streaming((request, bodyStream) async {
          bodies.add(
            jsonDecode(await bodyStream.bytesToString())
                as Map<String, dynamic>,
          );
          expect(request.headers['Authorization'], 'Bearer sk-test');
          expect(
            request.url.toString(),
            'https://example.test/v1/chat/completions',
          );
          return sse([
            '{"choices":[{"delta":{"reasoning_content":"think"}}]}',
            '{"choices":[{"delta":{"content":"Hel"}}]}',
            '{"choices":[{"delta":{"content":"lo"}}]}',
          ]);
        }),
      );

      final output = FakeOutput();
      session.speechFactory = () => SpeechStream(output);
      // A dictated message, so the answer is read aloud
      await session.send('hi', fromVoice: true);

      expect(session.error, isNull);
      expect(session.messages.last.text, 'Hello');
      expect(session.messages.last.reasoning, 'think');
      expect(output.added, ['Hello']);
      expect(bodies.single['stream'], true);
      expect(storage.messages(chat.id).length, 2);
      session.dispose();
    });

    test('runs a tool call and sends the result back', () async {
      await storage.saveChatSettings(
        chat.id,
        storage.chatSettings(chat.id)..functionCalling = true,
      );
      final bodies = <Map<String, dynamic>>[];
      var call = 0;
      final session = ChatSession(
        storage,
        chat.id,
        clientFactory: () => MockClient.streaming((request, bodyStream) async {
          bodies.add(
            jsonDecode(await bodyStream.bytesToString())
                as Map<String, dynamic>,
          );
          call++;
          if (call == 1) {
            return sse([
              '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"get_datetime","arguments":""}}]}}]}',
              '{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}]}',
            ]);
          }
          return sse(['{"choices":[{"delta":{"content":"It is late."}}]}']);
        }),
      );

      await session.send('what time is it');

      expect(session.error, isNull);
      expect(call, 2);
      expect(bodies[0]['tools'], isNotEmpty);
      final second = bodies[1]['messages'] as List;
      expect((second[second.length - 2] as Map)['tool_calls'], isNotNull);
      expect((second.last as Map)['role'], 'tool');
      expect((second.last as Map)['tool_call_id'], 'c1');
      expect(session.messages.last.text, 'It is late.');
      expect(session.messages.last.toolLog, contains('date and time'));
      session.dispose();
    });

    test('declined confirmation is reported to the model', () async {
      await storage.saveChatSettings(
        chat.id,
        storage.chatSettings(chat.id)..functionCalling = true,
      );
      final bodies = <Map<String, dynamic>>[];
      var call = 0;
      final session = ChatSession(
        storage,
        chat.id,
        clientFactory: () => MockClient.streaming((request, bodyStream) async {
          bodies.add(
            jsonDecode(await bodyStream.bytesToString())
                as Map<String, dynamic>,
          );
          call++;
          if (call == 1) {
            return sse([
              '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"open_app","arguments":"{\\"name\\":\\"Maps\\"}"}}]}}]}',
            ]);
          }
          return sse(['{"choices":[{"delta":{"content":"ok"}}]}']);
        }),
      );
      session.confirmTool = (tool, args) async => false;

      await session.send('open maps');

      final second = bodies[1]['messages'] as List;
      expect((second.last as Map)['content'], contains('declined'));
      session.dispose();
    });

    test('http errors surface as error text', () async {
      final session = ChatSession(
        storage,
        chat.id,
        clientFactory: () => MockClient.streaming((r, b) async {
          return http.StreamedResponse(
            Stream.value(utf8.encode('{"error":"bad key"}')),
            401,
          );
        }),
      );
      await session.send('hi');
      // By default the error is kept inside the chat
      expect(session.error, isNull);
      expect(session.messages.last.errorText, contains('401'));
      expect(session.generating, isFalse);
      session.dispose();
    });

    test('missing key is reported without a request', () async {
      await storage.saveEndpoint(
        ApiEndpoint(
          label: 'Default',
          host: 'https://example.test/v1/',
          apiKey: '',
        ),
      );
      var requested = false;
      final session = ChatSession(
        storage,
        chat.id,
        clientFactory: () => MockClient.streaming((r, b) async {
          requested = true;
          return sse([]);
        }),
      );
      await session.send('hi');
      expect(requested, isFalse);
      expect(session.error, contains('API key'));
      session.dispose();
    });
  });
}
