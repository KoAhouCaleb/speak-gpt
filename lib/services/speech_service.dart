import 'dart:async';
import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../models/models.dart';
import 'audio_queue.dart';
import 'speech_server_client.dart';
import 'speech_stream.dart';
import 'storage.dart';

/// Speech input and output.
///
/// Input uses the self-hosted server when one is configured (the microphone is recorded and
/// the file is transcribed), otherwise the Android speech recognizer. Output works the same way
/// with flutter_tts as the fallback.
class SpeechService {
  SpeechService(this._storage);

  final Storage _storage;

  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  AudioRecorder? _recorder;
  final AudioQueuePlayer _queue = AudioQueuePlayer();
  final List<SpeechStream> _streams = [];
  bool _sttReady = false;

  bool _recording = false;
  void Function(String text, bool isFinal)? _onResult;
  void Function(String error)? _onError;
  void Function()? _onDone;

  /// Speech settings that read answers aloud through an OpenAI-compatible endpoint.
  SpeechServerConfig endpointSpeechConfig(ApiEndpoint endpoint) =>
      SpeechServerConfig(
        enabled: true,
        host: endpoint.host,
        apiKey: endpoint.apiKey,
        model: _storage.ttsEndpointModel,
        voice: _storage.ttsEndpointVoice,
      );

  bool get isListening => _recording || _stt.isListening;

  /// Starts dictation. Returns false if speech recognition is unavailable or not allowed.
  Future<bool> listen({
    required void Function(String text, bool isFinal) onResult,
    void Function(String error)? onError,
    void Function()? onDone,
    String locale = '',
  }) async {
    final server = _storage.speechServer(Storage.speechStt);
    if (server.active) return _listenToServer(onResult, onError, onDone);

    if (!_sttReady) {
      _sttReady = await _stt.initialize(
        onError: (e) => onError?.call(e.errorMsg),
        onStatus: (s) {
          if (s == 'done' || s == 'notListening') onDone?.call();
        },
      );
    }
    if (!_sttReady) return false;

    await _stt.listen(
      onResult: (r) => onResult(r.recognizedWords, r.finalResult),
      listenOptions: SpeechListenOptions(
        partialResults: true,
        listenMode: ListenMode.dictation,
        localeId: locale.isEmpty ? null : locale,
      ),
    );
    return true;
  }

  Future<bool> _listenToServer(
    void Function(String text, bool isFinal) onResult,
    void Function(String error)? onError,
    void Function()? onDone,
  ) async {
    final recorder = _recorder ??= AudioRecorder();
    if (!await recorder.hasPermission()) return false;

    final dir = await getTemporaryDirectory();
    await recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: '${dir.path}/dictation.m4a',
    );
    _recording = true;
    _onResult = onResult;
    _onError = onError;
    _onDone = onDone;
    return true;
  }

  /// Ends dictation. With a speech server the recording is sent for transcription now.
  Future<void> stopListening() async {
    if (!_recording) {
      await _stt.stop();
      return;
    }

    _recording = false;
    final onResult = _onResult;
    final onError = _onError;
    final onDone = _onDone;

    try {
      final path = await _recorder?.stop();
      if (path == null) return;
      final text = await SpeechServerClient.transcribe(
        _storage.speechServer(Storage.speechStt),
        File(path),
      );
      onResult?.call(text, true);
    } catch (e) {
      onError?.call(e.toString());
    } finally {
      onDone?.call();
    }
  }

  /// Opens a stream that reads an answer aloud sentence by sentence while it is being written.
  ///
  /// Order of engines: a configured speech server, then the chat's API endpoint when that is
  /// the chosen engine, then Android text to speech. [endpoint] is the chat's endpoint.
  /// Starting a stream stops the one that was speaking before.
  SpeechStream openStream({
    String locale = '',
    ApiEndpoint? endpoint,
    void Function(String error)? onError,
  }) {
    unawaited(stopSpeaking());

    final SpeechOutput output;
    final server = _storage.speechServer(Storage.speechTts);
    if (server.active) {
      output = _ServerOutput(_withFormat(server), _queue);
    } else if (_storage.ttsEngine == 'endpoint') {
      output = endpoint == null || endpoint.apiKey.isEmpty
          ? _FailingOutput(
              'The chat has no API key for speech. Add one under Settings > API endpoints, or switch the speech engine to the device.',
            )
          : _ServerOutput(_withFormat(endpointSpeechConfig(endpoint)), _queue);
    } else {
      output = _DeviceOutput(_tts, locale);
    }

    late final SpeechStream stream;
    stream = SpeechStream(output, onError: (e) => onError?.call(e.toString()));
    _streams.add(stream);
    unawaited(stream.finished.whenComplete(() => _streams.remove(stream)));
    return stream;
  }

  SpeechServerConfig _withFormat(SpeechServerConfig config) {
    config.format = _storage.ttsAudioFormat;
    return config;
  }

  /// Reads a finished text aloud. Returns an error message, or null if speech started.
  Future<String?> speak(
    String markdown, {
    String locale = '',
    ApiEndpoint? endpoint,
  }) async {
    String? error;
    final stream = openStream(
      locale: locale,
      endpoint: endpoint,
      onError: (e) => error = e,
    );
    stream.finish(markdown);
    await stream.finished;
    return error;
  }

  /// Stops everything that is being read aloud.
  Future<void> stopSpeaking() async {
    final streams = List<SpeechStream>.of(_streams);
    _streams.clear();
    // Each part may be missing (no speech engine installed, no plugin), none may block the others
    for (final stream in streams) {
      await _quietly(stream.cancel);
    }
    await _quietly(_tts.stop);
    await _quietly(_queue.stop);
  }

  static Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Nothing is playing that could be stopped
    }
  }

  void dispose() {
    _stt.cancel();
    unawaited(stopSpeaking());
    _recorder?.dispose();
    _queue.dispose();
  }
}

/// Reads sentences with Android's text to speech. The engine has its own queue, so a sentence
/// added while another is spoken is synthesized in the background and follows without a gap.
class _DeviceOutput implements SpeechOutput {
  _DeviceOutput(this._tts, this._locale);

  final FlutterTts _tts;
  final String _locale;
  bool _ready = false;

  @override
  Future<void> add(String sentence) async {
    if (!_ready) {
      // Add to the queue instead of replacing what is being spoken
      await _tts.setQueueMode(1);
      if (_locale.isNotEmpty) await _tts.setLanguage(_locale);
      _ready = true;
    }
    await _tts.speak(sentence);
  }

  @override
  Future<void> stop() => _tts.stop();
}

/// Synthesizes every sentence on a server and gives the audio to the gapless player.
class _ServerOutput implements SpeechOutput {
  _ServerOutput(this._config, this._queue);

  final SpeechServerConfig _config;
  final AudioQueuePlayer _queue;
  int _counter = 0;

  @override
  Future<void> add(String sentence) async {
    final bytes = await SpeechServerClient.speak(_config, sentence);
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/tts_${DateTime.now().microsecondsSinceEpoch}_${_counter++}.${_config.format}',
    );
    await file.writeAsBytes(bytes);
    await _queue.enqueue(file.path);
  }

  @override
  Future<void> stop() => _queue.stop();
}

/// Reports a configuration problem the first time a sentence is added.
class _FailingOutput implements SpeechOutput {
  _FailingOutput(this._message);

  final String _message;

  @override
  Future<void> add(String sentence) => Future.error(_message);

  @override
  Future<void> stop() async {}
}
