import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:assistant/models/models.dart';
import 'package:assistant/services/mic_hub.dart';
import 'package:assistant/services/native_bridge.dart';
import 'package:assistant/services/speech_service.dart';
import 'package:assistant/services/storage.dart';
import 'package:assistant/services/vad_params.dart';
import 'package:assistant/services/voice_activity.dart';
import 'package:assistant/services/wake_word_service.dart';
import 'package:assistant/services/wav.dart';
import 'package:assistant/ui/assist_overlay.dart';
import 'package:assistant/ui/chat_screen.dart';
import 'package:assistant/ui/home_screen.dart';
import 'package:assistant/ui/voice_target.dart';
import 'package:assistant/ui/settings_screen.dart';
import 'package:assistant/ui/vad_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vad/vad.dart';

/// A microphone that plays recorded bytes instead of recording.
class FakeMic extends MicHub {
  final controller = StreamController<Uint8List>.broadcast();
  final owners = <Object>{};
  bool allowed = true;

  @override
  Stream<Uint8List> get stream => controller.stream;

  @override
  bool get active => owners.isNotEmpty;

  @override
  bool usedByOthers(Object owner) => owners.any((o) => !identical(o, owner));

  @override
  Future<bool> acquire(Object owner) async {
    if (!allowed) return false;
    owners.add(owner);
    return true;
  }

  @override
  Future<void> release(Object owner) async => owners.remove(owner);
}

/// Stands in for the vad package, which needs the ONNX runtime.
class FakeVad implements VadHandler {
  final end = StreamController<List<double>>.broadcast();
  final realStart = StreamController<void>.broadcast();
  final errors = StreamController<String>.broadcast();

  Map<String, Object?>? started;
  Object? startError;
  List<double>? speechOnPause;
  bool disposed = false;

  @override
  Stream<List<double>> get onSpeechEnd => end.stream;
  @override
  Stream<void> get onRealSpeechStart => realStart.stream;
  @override
  Stream<String> get onError => errors.stream;

  @override
  Future<void> startListening({
    double positiveSpeechThreshold = 0.5,
    double negativeSpeechThreshold = 0.35,
    int preSpeechPadFrames = 1,
    int redemptionFrames = 8,
    int frameSamples = 1536,
    int minSpeechFrames = 3,
    bool submitUserSpeechOnPause = false,
    String model = 'v4',
    String baseAssetPath = '',
    String onnxWASMBasePath = '',
    RecordConfig? recordConfig,
    int endSpeechPadFrames = 1,
    int numFramesToEmit = 0,
    Stream<Uint8List>? audioStream,
  }) async {
    if (startError != null) throw startError!;
    started = {
      'positive': positiveSpeechThreshold,
      'negative': negativeSpeechThreshold,
      'preSpeechPad': preSpeechPadFrames,
      'redemption': redemptionFrames,
      'frameSamples': frameSamples,
      'minSpeech': minSpeechFrames,
      'submitOnPause': submitUserSpeechOnPause,
      'model': model,
      'basePath': baseAssetPath,
      'audio': audioStream,
    };
  }

  @override
  Future<void> pauseListening() async {
    final samples = speechOnPause;
    if (samples != null) end.add(samples);
  }

  @override
  Future<void> dispose() async => disposed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeEngine implements WakeWordEngine {
  bool initResult = true;
  bool initialized = false;
  bool destroyed = false;
  bool activated = false;
  final chunks = <Int16List>[];

  @override
  Future<bool> init() async => initialized = initResult;
  @override
  void process(Int16List samples) => chunks.add(samples);
  @override
  bool takeActivation() {
    final value = activated;
    activated = false;
    return value;
  }

  @override
  void destroy() => destroyed = true;
}

/// Stands in for the recorder of the record package.
class FakeRecorder implements AudioRecorder {
  FakeRecorder(this.log, {this.permitted = true});

  final List<String> log;
  final bool permitted;
  final audio = StreamController<Uint8List>();

  @override
  Future<bool> hasPermission({bool request = true}) async => permitted;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    log.add('start ${config.sampleRate} ${config.encoder.name}');
    return audio.stream;
  }

  @override
  Future<String?> stop() async {
    log.add('stop');
    return null;
  }

  @override
  Future<void> dispose() async => log.add('dispose');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Uint8List pcm(int samples, [int value = 1]) {
  final data = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    data.setInt16(i * 2, value, Endian.little);
  }
  return data.buffer.asUint8List();
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late Storage storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    storage = Storage(await SharedPreferences.getInstance());
  });

  group('WAV encoding', () {
    test('writes a 16 bit mono header and clamps the samples', () {
      final wav = encodeWav([0, 0.5, -0.5, 2, -2], sampleRate: 16000);
      final data = ByteData.sublistView(wav);

      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(data.getUint16(22, Endian.little), 1, reason: 'mono');
      expect(data.getUint32(24, Endian.little), 16000);
      expect(data.getUint16(34, Endian.little), 16, reason: 'bits');
      expect(data.getUint32(40, Endian.little), 10, reason: 'data bytes');
      expect(data.getUint32(4, Endian.little), wav.length - 8);
      expect(wav.length, 44 + 10);

      expect(data.getInt16(44, Endian.little), 0);
      expect(data.getInt16(46, Endian.little), 16384);
      expect(data.getInt16(48, Endian.little), -16384);
      expect(data.getInt16(50, Endian.little), 32767);
      expect(data.getInt16(52, Endian.little), -32768);
    });
  });

  group('settings', () {
    test(
      'everything is off and the VAD parameters are the package defaults',
      () {
        expect(storage.vadOnDictate, false);
        expect(storage.vadHeadset, false);
        expect(storage.vadGesture, false);
        expect(storage.vadWakeWord, false);
        expect(storage.wakeWordEnabled, false);
        expect(storage.vadParams, VadParams.defaults);
        expect(VadParams.defaults.minSpeechFrames, 9);
        expect(VadParams.defaults.preSpeechPadFrames, 3);
        expect(VadParams.defaults.redemptionFrames, 24);
        expect(VadParams.defaults.positiveSpeechThreshold, 0.5);
        expect(VadParams.defaults.negativeSpeechThreshold, 0.35);
      },
    );

    test('each trigger has its own VAD switch', () async {
      await storage.setVadHeadset(true);
      expect(storage.vadForTrigger('headset'), true);
      expect(storage.vadForTrigger('gesture'), false);
      expect(storage.vadForTrigger('wakeword'), false);
      expect(storage.vadForTrigger(''), false);

      await storage.setVadGesture(true);
      await storage.setVadWakeWord(true);
      await storage.setVadOnDictate(true);
      expect(storage.vadForTrigger('gesture'), true);
      expect(storage.vadForTrigger('wakeword'), true);
      expect(storage.vadForTrigger(''), true);
      expect(storage.vadForTrigger('something else'), true);
    });

    test('the advanced parameters are stored', () async {
      const custom = VadParams(
        minSpeechFrames: 5,
        preSpeechPadFrames: 6,
        redemptionFrames: 40,
        positiveSpeechThreshold: 0.6,
        negativeSpeechThreshold: 0.4,
      );
      await storage.setVadParams(custom);
      expect(storage.vadParams, custom);
      expect(storage.vadMinSpeechFrames, 5);
      expect(storage.vadPreSpeechPadFrames, 6);
      expect(storage.vadRedemptionFrames, 40);
      expect(storage.vadPositiveThreshold, 0.6);
      expect(storage.vadNegativeThreshold, 0.4);
    });

    test('the assist context knows what started it', () {
      expect(AssistContext.fromMap({'trigger': 'headset'}).trigger, 'headset');
      expect(AssistContext.fromMap({'text': 'a'}).trigger, '');
      expect(AssistContext.fromMap(null).trigger, '');
    });
  });

  group('VoiceActivityDetector', () {
    late FakeVad vad;
    late VoiceActivityDetector detector;
    final audio = const Stream<Uint8List>.empty();

    setUp(() {
      vad = FakeVad();
      detector = VoiceActivityDetector(createHandler: () => vad);
    });

    test(
      'hands the parameters to the package and returns the message',
      () async {
        var started = 0;
        final future = detector.listen(
          const VadParams(
            minSpeechFrames: 4,
            preSpeechPadFrames: 2,
            redemptionFrames: 30,
            positiveSpeechThreshold: 0.7,
            negativeSpeechThreshold: 0.45,
          ),
          audio: audio,
          onSpeechStart: () => started++,
        );
        await settle();

        expect(detector.listening, true);
        expect(vad.started, {
          'positive': 0.7,
          'negative': 0.45,
          'preSpeechPad': 2,
          'redemption': 30,
          'frameSamples': 512,
          'minSpeech': 4,
          'submitOnPause': true,
          'model': 'v5',
          'basePath': 'assets/vad/',
          'audio': audio,
        });

        vad.realStart.add(null);
        await settle();
        expect(started, 1);

        vad.end.add([0.1, 0.2]);
        expect(await future, [0.1, 0.2]);
        expect(detector.listening, false);
        expect(vad.disposed, true);
      },
    );

    test('gives up when nobody speaks', () async {
      final result = await detector.listen(
        VadParams.defaults,
        audio: audio,
        timeout: const Duration(milliseconds: 30),
      );
      expect(result, isNull);
      expect(detector.listening, false);
      expect(vad.disposed, true);
    });

    test('the silence timeout stops once speech was detected', () async {
      final future = detector.listen(
        VadParams.defaults,
        audio: audio,
        timeout: const Duration(milliseconds: 60),
      );
      await settle();
      vad.realStart.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(detector.listening, true);

      vad.end.add([0.5]);
      expect(await future, [0.5]);
    });

    test('finish hands over what was said so far', () async {
      final future = detector.listen(VadParams.defaults, audio: audio);
      await settle();
      vad.speechOnPause = [0.3, 0.4, 0.5];

      await detector.finish();
      expect(await future, [0.3, 0.4, 0.5]);
    });

    test('finish without speech returns nothing', () async {
      final future = detector.listen(VadParams.defaults, audio: audio);
      await settle();

      await detector.finish();
      expect(await future, isNull);
      expect(detector.listening, false);
    });

    test('cancel returns nothing and releases the package', () async {
      final future = detector.listen(VadParams.defaults, audio: audio);
      await settle();

      detector.cancel();
      expect(await future, isNull);
      expect(vad.disposed, true);
    });

    test('errors of the package reach the caller', () async {
      final future = detector.listen(VadParams.defaults, audio: audio);
      await settle();
      vad.errors.add('no model');

      await expectLater(future, throwsA(isA<Exception>()));
      expect(detector.listening, false);
    });

    test('a package that cannot start reaches the caller', () async {
      vad.startError = StateError('no onnx runtime');
      await expectLater(
        detector.listen(VadParams.defaults, audio: audio),
        throwsA(isA<StateError>()),
      );
      expect(detector.listening, false);
    });

    test('one session after the other works', () async {
      final first = detector.listen(VadParams.defaults, audio: audio);
      await settle();
      vad.end.add([0.1]);
      expect(await first, [0.1]);

      final second = detector.listen(VadParams.defaults, audio: audio);
      await settle();
      vad.end.add([0.2]);
      expect(await second, [0.2]);
    });
  });

  group('WakeWordService', () {
    late FakeMic mic;
    late FakeEngine engine;
    late int detections;
    late WakeWordService service;

    setUp(() {
      mic = FakeMic();
      engine = FakeEngine();
      detections = 0;
      service = WakeWordService(
        mic: mic,
        engine: engine,
        onDetected: () => detections++,
      );
    });

    test('cuts the audio into blocks of 80 ms', () async {
      expect(await service.start(), true);
      expect(mic.active, true);

      // 3000 samples in uneven pieces: two blocks are complete, 440 samples wait
      mic.controller.add(pcm(1000));
      mic.controller.add(pcm(1000));
      mic.controller.add(pcm(1000));
      await settle();

      expect(engine.chunks.length, 2);
      expect(engine.chunks.every((c) => c.length == 1280), true);
      expect(engine.chunks.first.first, 1);

      mic.controller.add(pcm(840));
      await settle();
      expect(engine.chunks.length, 3);
    });

    test('reports the wake word once per utterance', () async {
      await service.start();

      engine.activated = true;
      mic.controller.add(pcm(1280));
      await settle();
      expect(detections, 1);

      // The same utterance activates the engine again right away
      engine.activated = true;
      mic.controller.add(pcm(1280));
      await settle();
      expect(detections, 1);
    });

    test('ignores the wake word while a message is being recorded', () async {
      await service.start();
      final other = Object();
      mic.owners.add(other);

      engine.activated = true;
      mic.controller.add(pcm(1280));
      await settle();
      expect(detections, 0);

      mic.owners.remove(other);
      engine.activated = true;
      mic.controller.add(pcm(1280));
      await settle();
      expect(detections, 1);
    });

    test('stopping releases the microphone and the engine', () async {
      await service.start();
      await service.stop();

      expect(service.running, false);
      expect(mic.active, false);
      expect(engine.destroyed, true);

      engine.activated = true;
      mic.controller.add(pcm(1280));
      await settle();
      expect(detections, 0);
      expect(engine.chunks, isEmpty);
    });

    test('fails when the models do not load', () async {
      engine.initResult = false;
      expect(await service.start(), false);
      expect(service.running, false);
      expect(mic.active, false);
    });

    test('fails without the microphone permission', () async {
      mic.allowed = false;
      expect(await service.start(), false);
      expect(service.running, false);
      expect(engine.destroyed, true);
    });

    test('can start again after it was stopped', () async {
      await service.start();
      await service.stop();
      expect(await service.start(), true);
      expect(engine.initialized, true);
    });

    test('the bundled models are the ones the service names', () {
      for (final asset in [
        WakeWordService.melAsset,
        WakeWordService.embeddingAsset,
        WakeWordService.modelAsset,
      ]) {
        expect(File(asset).existsSync(), true, reason: asset);
      }
      expect(File('assets/vad/silero_vad_v5.onnx').existsSync(), true);
    });
  });

  group('MicHub', () {
    late List<String> log;
    late List<FakeRecorder> recorders;
    late bool permitted;
    late MicHub hub;

    setUp(() {
      log = [];
      recorders = [];
      permitted = true;
      hub = MicHub(
        recorderFactory: () {
          final recorder = FakeRecorder(log, permitted: permitted);
          recorders.add(recorder);
          return recorder;
        },
      );
    });

    test(
      'one recording serves every user and stops with the last one',
      () async {
        final a = Object(), b = Object();
        final heardA = <int>[], heardB = <int>[];

        expect(await hub.acquire(a), true);
        expect(await hub.acquire(b), true);
        expect(recorders.length, 1);
        expect(log, ['start 16000 pcm16bits']);

        hub.stream.listen((d) => heardA.add(d.length));
        hub.stream.listen((d) => heardB.add(d.length));
        recorders.single.audio.add(pcm(100));
        await settle();
        expect(heardA, [200]);
        expect(heardB, [200]);

        expect(hub.usedByOthers(a), true);
        await hub.release(a);
        expect(hub.active, true);
        expect(log.contains('stop'), false);
        expect(hub.usedByOthers(b), false);

        await hub.release(b);
        expect(hub.active, false);
        expect(log, ['start 16000 pcm16bits', 'stop', 'dispose']);
      },
    );

    test('a refused permission leaves nothing behind', () async {
      permitted = false;
      final a = Object();
      expect(await hub.acquire(a), false);
      expect(hub.active, false);
      expect(log, ['dispose']);
    });

    test('pausing stops the recording but keeps the users', () async {
      final a = Object();
      await hub.acquire(a);

      await hub.pause();
      expect(log, ['start 16000 pcm16bits', 'stop', 'dispose']);
      expect(hub.active, true);

      // A user that arrives meanwhile waits for the resume
      final b = Object();
      expect(await hub.acquire(b), true);
      expect(recorders.length, 1);

      await hub.resume();
      expect(recorders.length, 2);
      expect(log.last, 'start 16000 pcm16bits');
    });

    test('resuming without users does not record', () async {
      await hub.pause();
      await hub.resume();
      expect(recorders, isEmpty);
    });
  });

  group('dictation with VAD', () {
    late FakeMic mic;
    late FakeVad fake;
    late Directory temp;

    setUp(() async {
      mic = FakeMic();
      fake = FakeVad();
      temp = await Directory.systemTemp.createTemp('vad_test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => temp.path,
          );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      await temp.delete(recursive: true);
    });

    SpeechService service(List<File> sent) => SpeechService(
      storage,
      mic: mic,
      vad: VoiceActivityDetector(createHandler: () => fake),
      transcribe: (config, file) async {
        sent.add(file);
        return 'turn on the lights';
      },
    );

    Future<void> useServer() => storage.saveSpeechServer(
      Storage.speechStt,
      SpeechServerConfig(enabled: true, host: 'http://stt.test/v1/'),
    );

    test('is only available with a speech to text server', () async {
      expect(service([]).vadAvailable, false);
      await useServer();
      expect(service([]).vadAvailable, true);
    });

    test('transcribes the message that the detector cut out', () async {
      await useServer();
      await storage.setVadParams(
        VadParams.defaults.copyWith(redemptionFrames: 50),
      );
      final sent = <File>[];
      final results = <(String, bool)>[];
      var done = 0;

      final ok = await service(sent).listen(
        useVad: true,
        onResult: (text, isFinal) => results.add((text, isFinal)),
        onDone: () => done++,
      );
      expect(ok, true);
      expect(mic.active, true);
      await settle();
      expect(
        fake.started!['redemption'],
        50,
        reason: 'uses the saved settings',
      );

      fake.end.add([0.25, -0.25]);
      await settle();
      await settle();

      expect(results, [('turn on the lights', true)]);
      expect(done, 1);
      expect(mic.active, false, reason: 'the microphone is given back');
      expect(sent.single.path.endsWith('.wav'), true);
      expect(
        String.fromCharCodes(sent.single.readAsBytesSync().sublist(0, 4)),
        'RIFF',
      );
    });

    test('pressing the button again ends the message early', () async {
      await useServer();
      final sent = <File>[];
      final results = <String>[];
      final speech = service(sent);

      await speech.listen(useVad: true, onResult: (t, f) => results.add(t));
      await settle();
      expect(speech.isListening, true);
      fake.speechOnPause = [0.1, 0.2];

      await speech.stopListening();
      await settle();
      await settle();

      expect(results, ['turn on the lights']);
      expect(speech.isListening, false);
    });

    test('silence ends the dictation without a result', () async {
      await useServer();
      final results = <String>[];
      var done = 0;
      final speech = service([]);

      await speech.listen(
        useVad: true,
        onResult: (t, f) => results.add(t),
        onDone: () => done++,
      );
      await settle();
      await speech.stopListening();
      await settle();

      expect(results, isEmpty);
      expect(done, 1);
      expect(mic.active, false);
    });

    test('a refused microphone permission is reported', () async {
      await useServer();
      mic.allowed = false;
      final ok = await service([]).listen(useVad: true, onResult: (t, f) {});
      expect(ok, false);
    });

    test('a failed transcription is reported', () async {
      await useServer();
      final errors = <String>[];
      var done = 0;
      final speech = SpeechService(
        storage,
        mic: mic,
        vad: VoiceActivityDetector(createHandler: () => fake),
        transcribe: (config, file) async => throw Exception('HTTP 500'),
      );

      await speech.listen(
        useVad: true,
        onResult: (t, f) {},
        onError: errors.add,
        onDone: () => done++,
      );
      await settle();
      fake.end.add([0.3]);
      await settle();
      await settle();

      expect(errors.single, contains('HTTP 500'));
      expect(done, 1);
      expect(mic.active, false);
    });
  });

  group('screens', () {
    Future<void> open(
      WidgetTester tester,
      Widget screen, {
      Map<String, Object? Function(MethodCall call)> native = const {},
    }) async {
      tester.view.physicalSize = const Size(900, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.grace.assistant/native'),
            (call) async => native[call.method]?.call(call),
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.grace.assistant/native'),
              null,
            ),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<Storage>.value(
          value: storage,
          child: MaterialApp(home: screen),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('settings has the four VAD switches and the wake word', (
      tester,
    ) async {
      await open(tester, const SettingsScreen());

      for (final label in [
        'Wake word',
        'Use VAD after pressing Dictate',
        'Use VAD with the headset trigger',
        'Use VAD with the gesture trigger',
        'Use VAD with the wake word trigger',
        'Advanced VAD settings',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }

      await tester.tap(find.text('Use VAD with the gesture trigger'));
      await tester.pumpAndSettle();
      expect(storage.vadGesture, true);
      expect(storage.vadHeadset, false);

      await tester.tap(find.text('Wake word'));
      await tester.pumpAndSettle();
      expect(storage.wakeWordEnabled, true);
    });

    testWidgets(
      'the assistant gesture listens at once when its VAD switch is on',
      (tester) async {
        await storage.setVadGesture(true);
        await open(
          tester,
          const AssistOverlayScreen(),
          native: {
            'takePendingAssist': (_) => {'trigger': 'gesture'},
          },
        );

        // No speech to text server: the user is told why the standard dictation is used
        expect(
          find.textContaining(
            'Voice activity detection needs a speech to text server',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('the headset button follows its own switch', (tester) async {
      await storage.setVadGesture(true);
      await open(
        tester,
        const AssistOverlayScreen(),
        native: {
          'takePendingAssist': (_) => {'trigger': 'headset'},
        },
      );
      expect(
        find.textContaining('Voice activity detection needs'),
        findsNothing,
      );
    });

    testWidgets('a trigger with VAD off does not start listening', (
      tester,
    ) async {
      await open(
        tester,
        const AssistOverlayScreen(),
        native: {
          'takePendingAssist': (_) => {'trigger': 'gesture'},
        },
      );
      expect(
        find.textContaining('Voice activity detection needs'),
        findsNothing,
      );
      expect(find.byTooltip('Dictate'), findsOneWidget);
    });

    testWidgets('the dictate button honors its VAD switch', (tester) async {
      await storage.setVadOnDictate(true);
      await open(tester, const AssistOverlayScreen());

      await tester.tap(find.byTooltip('Dictate'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Voice activity detection needs'),
        findsOneWidget,
      );
    });

    testWidgets(
      'a chat opened by the wake word has no missing screen warning',
      (tester) async {
        final chat = await storage.addChat('Assistant');
        await open(
          tester,
          ChatScreen(
            chat: chat,
            assist: const AssistContext(trigger: 'wakeword'),
          ),
        );
        expect(find.textContaining('did not receive the screen'), findsNothing);

        final gesture = await storage.addChat('Other');
        await open(
          tester,
          ChatScreen(
            chat: gesture,
            assist: const AssistContext(trigger: 'gesture'),
          ),
        );
        expect(
          find.textContaining('did not receive the screen'),
          findsOneWidget,
        );
      },
    );

    testWidgets('an open chat takes the voice requests until it closes', (
      tester,
    ) async {
      final chat = await storage.addChat('c');
      await open(tester, ChatScreen(chat: chat));

      final target = VoiceTargets.current;
      expect(target, isNotNull);
      expect(target!.canStartVoice, true);

      await tester.pumpWidget(const SizedBox());
      expect(VoiceTargets.current, isNull);
    });

    testWidgets('the wake word switches itself off when it cannot start', (
      tester,
    ) async {
      // No ONNX runtime in the test environment, as on a device without the libraries
      await storage.setWakeWordEnabled(true);
      await open(tester, const HomeScreen());
      // Loading the library and the models is real file work, outside the fake clock
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();

      expect(storage.wakeWordEnabled, false);
      expect(
        find.textContaining('The wake word could not start'),
        findsOneWidget,
      );
    });

    testWidgets('the advanced screen shows and saves every value', (
      tester,
    ) async {
      await open(tester, const VadSettingsScreen());

      expect(find.textContaining('Minimum speech frames: 9'), findsOneWidget);
      expect(find.textContaining('Pre-speech pad frames: 3'), findsOneWidget);
      expect(find.textContaining('Redemption frames: 24'), findsOneWidget);
      expect(
        find.textContaining('Positive speech threshold: 0.50'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Negative speech threshold: 0.35'),
        findsOneWidget,
      );
      expect(find.byType(Slider), findsNWidgets(5));

      // Drag the redemption slider (third) to its right end
      await tester.drag(find.byType(Slider).at(2), const Offset(2000, 0));
      await tester.pumpAndSettle();
      expect(storage.vadRedemptionFrames, 100);

      // The negative threshold cannot pass the positive one: pushing it up drags it along
      await tester.drag(find.byType(Slider).at(4), const Offset(2000, 0));
      await tester.pumpAndSettle();
      expect(storage.vadNegativeThreshold, 0.9);
      expect(
        storage.vadPositiveThreshold,
        greaterThan(storage.vadNegativeThreshold),
      );

      await tester.tap(find.text('Defaults'));
      await tester.pumpAndSettle();
      expect(storage.vadParams, VadParams.defaults);
    });
  });
}
