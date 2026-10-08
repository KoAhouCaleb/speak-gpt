import 'dart:convert';
import 'dart:io';

import 'package:assistant/models/models.dart';
import 'package:assistant/services/chat_session.dart';
import 'package:assistant/services/speech_service.dart';
import 'package:assistant/services/speech_stream.dart';
import 'fake_speech_output.dart';
import 'package:assistant/services/storage.dart';
import 'package:assistant/ui/assist_overlay.dart';
import 'package:assistant/ui/message_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.StreamedResponse sse(List<String> events) {
  final body = '${events.map((e) => 'data: $e\n\n').join()}data: [DONE]\n\n';
  return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
}

const _channel = MethodChannel('com.grace.assistant/native');

void mockNative(Map<String, Object? Function(MethodCall call)> handlers) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        final h = handlers[call.method];
        return h?.call(call);
      });
}

void main() {
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
        apiKey: 'sk',
      ),
    );
    chat = await storage.addChat('t');
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  group('when answers are read aloud', () {
    test('truth table', () {
      bool f(bool voice, bool silent, bool always) => ChatSession.shouldSpeak(
        fromVoice: voice,
        silent: silent,
        alwaysSpeak: always,
      );
      // dictated, normal: yes. typed, normal: no
      expect(f(true, false, false), isTrue);
      expect(f(false, false, false), isFalse);
      // silent mode mutes dictated answers
      expect(f(true, true, false), isFalse);
      // always speak covers typed messages and wins over silent
      expect(f(false, false, true), isTrue);
      expect(f(true, true, true), isTrue);
      expect(f(false, true, true), isTrue);
    });

    Future<List<String>> spokenFor({
      required bool fromVoice,
      bool silent = false,
      bool always = false,
    }) async {
      final s = storage.chatSettings(chat.id)
        ..silentMode = silent
        ..alwaysSpeak = always;
      await storage.saveChatSettings(chat.id, s);
      final output = FakeOutput();
      final session = ChatSession(
        storage,
        chat.id,
        clientFactory: () => MockClient.streaming(
          (r, b) async => sse(['{"choices":[{"delta":{"content":"Answer"}}]}']),
        ),
      )..speechFactory = (() => SpeechStream(output));
      await session.send('hello', fromVoice: fromVoice);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      session.dispose();
      return output.added;
    }

    test(
      'typed message is not read aloud by default',
      () async => expect(await spokenFor(fromVoice: false), isEmpty),
    );
    test(
      'dictated message is read aloud',
      () async => expect(await spokenFor(fromVoice: true), ['Answer']),
    );
    test(
      'silent mode stops dictated answers',
      () async =>
          expect(await spokenFor(fromVoice: true, silent: true), isEmpty),
    );
    test(
      'always speak reads typed answers',
      () async =>
          expect(await spokenFor(fromVoice: false, always: true), ['Answer']),
    );
  });

  group('chat conveniences', () {
    test(
      'prefix and end separator wrap the message sent to the model, not the stored one',
      () async {
        final s = ChatSettings(
          prefix: 'Reply in French. ',
          endSeparator: '\n###',
        );
        final session = ChatSession(storage, chat.id);
        final msgs = session.buildMessages(s, [
          ChatMessage(text: 'Hi', isBot: false),
        ]);
        expect(msgs.single['content'], 'Reply in French. Hi\n###');
        session.dispose();
      },
    );

    test('/imagine can be turned off', () async {
      final bodies = <String>[];
      await storage.saveChatSettings(
        chat.id,
        storage.chatSettings(chat.id)..imagineCommand = false,
      );
      final session = ChatSession(
        storage,
        chat.id,
        clientFactory: () => MockClient.streaming((r, b) async {
          bodies.add(r.url.path);
          await b.drain<void>();
          return sse(['{"choices":[{"delta":{"content":"ok"}}]}']);
        }),
      );
      await session.send('/imagine a cat');
      expect(bodies, ['/v1/chat/completions']);
      session.dispose();
    });

    test(
      'errors stay in the chat, are saved, and are not sent to the model',
      () async {
        var calls = 0;
        final requests = <Map<String, dynamic>>[];
        final session = ChatSession(
          storage,
          chat.id,
          clientFactory: () => MockClient.streaming((r, b) async {
            requests.add(
              jsonDecode(await b.bytesToString()) as Map<String, dynamic>,
            );
            calls++;
            if (calls == 1) {
              return http.StreamedResponse(
                Stream.value(utf8.encode('quota exceeded')),
                429,
              );
            }
            return sse(['{"choices":[{"delta":{"content":"fine"}}]}']);
          }),
        );

        await session.send('first');
        expect(session.error, isNull);
        expect(session.messages.last.errorText, contains('429'));
        expect(storage.messages(chat.id).last.errorText, contains('429'));

        await session.send('second');
        final history = requests.last['messages'] as List;
        // the failed answer has no text, so only the two user messages are sent
        expect(history.map((m) => (m as Map)['role']), ['user', 'user']);
        expect(jsonEncode(history), isNot(contains('quota')));
        session.dispose();
      },
    );

    test('with the setting off the error is only a banner', () async {
      await storage.setShowChatErrors(false);
      final session = ChatSession(
        storage,
        chat.id,
        clientFactory: () => MockClient.streaming(
          (r, b) async =>
              http.StreamedResponse(Stream.value(utf8.encode('nope')), 500),
        ),
      );
      await session.send('x');
      expect(session.error, contains('500'));
      expect(session.messages.where((m) => m.isBot), isEmpty);
      session.dispose();
    });
  });

  group('endpoint speech', () {
    test('settings map onto the chat endpoint', () async {
      await storage.setTtsEngine('endpoint');
      await storage.setTtsEndpointVoice('nova');
      await storage.setTtsEndpointModel('tts-1-hd');
      final config = SpeechService(
        storage,
      ).endpointSpeechConfig(storage.endpoints.first);
      expect(config.host, 'https://example.test/v1/');
      expect(config.apiKey, 'sk');
      expect(config.voice, 'nova');
      expect(config.model, 'tts-1-hd');
      expect(config.active, isTrue);
    });

    test('a missing key is reported instead of failing silently', () async {
      await storage.setTtsEngine('endpoint');
      final error = await SpeechService(storage).speak(
        'hello',
        endpoint: ApiEndpoint(label: 'x', host: 'h', apiKey: ''),
      );
      expect(error, contains('API key'));
    });
  });

  group('pictures from the clipboard and shares', () {
    testWidgets(
      'the menu offers Paste image when the clipboard has a picture',
      (tester) async {
        mockNative({
          'clipboardHasImage': (_) => true,
          'clipboardImage': (_) => '/tmp/pasted.png',
        });
        final controller = TextEditingController(text: 'some text');
        String? got;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MessageInput(
                controller: controller,
                onImage: (p) => got = p,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.longPress(find.byType(TextField));
        await tester.pumpAndSettle();
        expect(find.text('Paste image'), findsOneWidget);

        await tester.tap(find.text('Paste image'));
        await tester.pumpAndSettle();
        expect(got, '/tmp/pasted.png');
      },
    );

    testWidgets('no Paste image item when the clipboard has no picture', (
      tester,
    ) async {
      mockNative({'clipboardHasImage': (_) => false});
      final controller = TextEditingController(text: 'some text');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageInput(controller: controller, onImage: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(find.text('Paste image'), findsNothing);
    });

    testWidgets('a shared text and picture open the overlay ready to send', (
      tester,
    ) async {
      final file = File('${Directory.systemTemp.path}/grace_share_test.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 8)));
      mockNative({
        'takePendingShare': (_) => {
          'text': 'look at this',
          'imagePath': file.path,
        },
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<Storage>.value(
          value: storage,
          child: const AssistOverlayApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('look at this'), findsOneWidget);
      expect(find.text('Picture'), findsOneWidget);
      // not the gesture: no screen hint, different placeholder
      expect(find.textContaining('did not receive the screen'), findsNothing);
      expect(storage.chats.where((c) => c.name != 't'), isEmpty);
      file.deleteSync();
    });
  });
}
