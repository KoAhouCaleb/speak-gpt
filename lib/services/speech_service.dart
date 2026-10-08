import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../util.dart';
import 'speech_server_client.dart';
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
  AudioPlayer? _player;
  bool _sttReady = false;

  bool _recording = false;
  void Function(String text, bool isFinal)? _onResult;
  void Function(String error)? _onError;
  void Function()? _onDone;

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

  /// Reads text aloud. Returns an error message, or null if speech started.
  Future<String?> speak(String markdown, {String locale = ''}) async {
    final text = plainTextForSpeech(markdown);
    if (text.isEmpty) return null;

    try {
      final server = _storage.speechServer(Storage.speechTts);
      if (server.active) {
        await stopSpeaking();
        final bytes = await SpeechServerClient.speak(server, text);
        final player = _player ??= AudioPlayer();
        await player.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
        return null;
      }

      if (locale.isNotEmpty) await _tts.setLanguage(locale);
      await _tts.stop();
      await _tts.speak(text);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> stopSpeaking() async {
    await _tts.stop();
    await _player?.stop();
  }

  void dispose() {
    _stt.cancel();
    _tts.stop();
    _recorder?.dispose();
    _player?.dispose();
  }
}
