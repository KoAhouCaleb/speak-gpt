import 'dart:async';
import 'dart:convert';

import 'package:assistant/models/models.dart';
import 'package:assistant/services/chat_session.dart';
import 'package:assistant/services/speech_stream.dart';
import 'package:assistant/services/storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_speech_output.dart';

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('SpeechStream', () {
    test('sentences are handed over in order, one at a time', () async {
      final output = FakeOutput()..hold = Completer<void>();
      final stream = SpeechStream(output);

      stream.update('One. Two. Three. ');
      await pump();
      // The first one is being synthesized, the others wait in the FIFO queue
      expect(output.events, ['start One.']);

      output.hold!.complete();
      stream.finish('One. Two. Three. ');
      await stream.finished;

      expect(output.added, ['One.', 'Two.', 'Three.']);
      expect(output.maxRunning, 1);
    });

    test('speech starts before the answer is complete', () async {
      final output = FakeOutput();
      final stream = SpeechStream(output);

      stream.update('First sentence. Second sent');
      await pump();
      expect(output.added, ['First sentence.']);

      stream.update('First sentence. Second sentence. Third');
      await pump();
      expect(output.added, ['First sentence.', 'Second sentence.']);

      stream.finish('First sentence. Second sentence. Third');
      await stream.finished;
      expect(output.added, ['First sentence.', 'Second sentence.', 'Third']);
    });

    test('code and markdown are not spoken', () async {
      final output = FakeOutput();
      final stream = SpeechStream(output);
      stream.finish('# Title\n\nRun `ls`.\n```sh\nls -la\n```\nDone');
      await stream.finished;
      expect(output.added, ['Title', 'Run ls.', 'Done']);
    });

    test('cancel stops the output and drops queued sentences', () async {
      final output = FakeOutput()..hold = Completer<void>();
      final stream = SpeechStream(output);
      stream.update('One. Two. Three. ');
      await pump();

      await stream.cancel();
      output.hold!.complete();
      await stream.finished;
      await pump();

      expect(output.stopped, isTrue);
      expect(output.added, isNot(contains('Three.')));
      expect(output.events.where((e) => e.startsWith('start')), ['start One.']);
      expect(stream.isCancelled, isTrue);
    });

    test('an output error is reported once and the rest is dropped', () async {
      final output = FakeOutput(failOn: 'Two.');
      final errors = <Object>[];
      final stream = SpeechStream(output, onError: errors.add);

      stream.finish('One. Two. Three. Four.');
      await stream.finished;

      expect(errors.length, 1);
      expect(output.added, ['One.']);
    });

    test('text after finish is ignored', () async {
      final output = FakeOutput();
      final stream = SpeechStream(output);
      stream.finish('Only this.');
      stream.update('Only this. And more. ');
      stream.finish('Only this. And more.');
      await stream.finished;
      expect(output.added, ['Only this.']);
    });

    test('closing an empty stream completes it', () async {
      final stream = SpeechStream(FakeOutput());
      stream.close();
      await stream.finished.timeout(const Duration(seconds: 1));
    });
  });

  group('ChatSession speech', () {
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

    String chunk(String content) =>
        'data: {"choices":[{"delta":{"content":${jsonEncode(content)}}}]}\n\n';

    test(
      'the first sentence is spoken while the model is still answering',
      () async {
        final body = StreamController<List<int>>();
        final output = FakeOutput();
        final session = ChatSession(
          storage,
          chat.id,
          clientFactory: () => MockClient.streaming((r, b) async {
            await b.drain<void>();
            return http.StreamedResponse(body.stream, 200);
          }),
        )..speechFactory = (() => SpeechStream(output));

        final sending = session.send('hi', fromVoice: true);
        body.add(utf8.encode(chunk('Hello there. How ')));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Not finished, but the first sentence already reached the speaker
        expect(session.generating, isTrue);
        expect(output.added, ['Hello there.']);

        body.add(utf8.encode(chunk('are you today?')));
        body.add(utf8.encode('data: [DONE]\n\n'));
        await body.close();
        await sending;
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(output.added, ['Hello there.', 'How are you today?']);
        session.dispose();
      },
    );

    test('a typed message creates no speech stream', () async {
      var created = 0;
      final session =
          ChatSession(
              storage,
              chat.id,
              clientFactory: () => MockClient.streaming((r, b) async {
                await b.drain<void>();
                return http.StreamedResponse(
                  Stream.value(utf8.encode('${chunk('Hi.')}data: [DONE]\n\n')),
                  200,
                );
              }),
            )
            ..speechFactory = (() {
              created++;
              return SpeechStream(FakeOutput());
            });

      await session.send('typed');
      expect(created, 0);

      await storage.saveChatSettings(
        chat.id,
        storage.chatSettings(chat.id)..alwaysSpeak = true,
      );
      await session.send('typed again');
      expect(created, 1);
      session.dispose();
    });

    test('stopping the answer silences the speech', () async {
      final body = StreamController<List<int>>();
      final output = FakeOutput();
      final session = ChatSession(
        storage,
        chat.id,
        clientFactory: () => MockClient.streaming((r, b) async {
          await b.drain<void>();
          return http.StreamedResponse(body.stream, 200);
        }),
      )..speechFactory = (() => SpeechStream(output));

      final sending = session.send('hi', fromVoice: true);
      body.add(utf8.encode(chunk('One. Two. ')));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      session.stop();
      await body.close().catchError((_) {});
      await sending;

      expect(output.stopped, isTrue);
      session.dispose();
    });
  });
}
