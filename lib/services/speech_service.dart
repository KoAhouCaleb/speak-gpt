import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../util.dart';

/// Speech input (speech_to_text) and output (flutter_tts).
class SpeechService {
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _sttReady = false;

  bool get isListening => _stt.isListening;

  /// Starts dictation. Returns false if speech recognition is unavailable or not allowed.
  Future<bool> listen({
    required void Function(String text, bool isFinal) onResult,
    void Function(String error)? onError,
    void Function()? onDone,
    String locale = '',
  }) async {
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
      ),
    );
    return true;
  }

  Future<void> stopListening() => _stt.stop();

  Future<void> speak(String markdown, {String locale = ''}) async {
    final text = plainTextForSpeech(markdown);
    if (text.isEmpty) return;
    if (locale.isNotEmpty) await _tts.setLanguage(locale);
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> stopSpeaking() => _tts.stop();

  void dispose() {
    _stt.cancel();
    _tts.stop();
  }
}
