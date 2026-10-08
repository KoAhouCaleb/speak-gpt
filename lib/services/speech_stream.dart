import 'dart:async';
import 'dart:collection';

import 'speech_text.dart';

/// Where finished sentences go: the device's text to speech, or synthesized audio files.
abstract class SpeechOutput {
  /// Hands one sentence over. Completes once the sentence is queued for playback (for the
  /// device engine that is immediately, for a server it is after the audio was synthesized
  /// and given to the player). Sentences are always added one at a time and in order.
  Future<void> add(String sentence);

  /// Stops playback at once and drops everything that is queued.
  Future<void> stop();
}

/// Speaks a streamed answer sentence by sentence.
///
/// Completed sentences go to a FIFO queue and are handed to the [SpeechOutput] one at a time.
/// Because the output queues what it gets, the next sentence is synthesized while the current
/// one is still playing, and speech starts after the first sentence instead of after the whole
/// answer.
///
/// Call [update] with the whole answer on every streamed token, then [finish] once it is
/// complete.
class SpeechStream {
  SpeechStream(this._output, {this.onError});

  final SpeechOutput _output;

  /// Called once with the first error of the output. Sentences already handed over still play.
  final void Function(Object error)? onError;

  final SentenceSplitter _splitter = SentenceSplitter();
  final Queue<String> _sentences = Queue<String>();
  final Completer<void> _finished = Completer<void>();

  bool _inputClosed = false;
  bool _cancelled = false;
  bool _running = false;
  Completer<void>? _wake;

  /// Completes when every queued sentence was handed to the output (or the stream was cancelled).
  Future<void> get finished => _finished.future;

  bool get isCancelled => _cancelled;

  /// Queues the sentences completed so far. [fullText] is the whole answer received so far.
  void update(String fullText) {
    if (_inputClosed) return;
    _enqueue(_splitter.update(fullText));
  }

  /// Queues the rest of the answer and closes the input. Queued sentences keep playing.
  void finish(String fullText) {
    if (_inputClosed) return;
    _enqueue(_splitter.finish(fullText));
    close();
  }

  /// Stops accepting text without queueing the unterminated tail.
  void close() {
    _inputClosed = true;
    _signal();
    if (!_running && !_finished.isCompleted) _finished.complete();
  }

  /// Stops playback at once and drops everything queued.
  Future<void> cancel() async {
    _cancelled = true;
    _inputClosed = true;
    _sentences.clear();
    _signal();
    await _output.stop();
    if (!_finished.isCompleted) _finished.complete();
  }

  void _enqueue(List<String> sentences) {
    if (sentences.isEmpty) return;
    _sentences.addAll(sentences);
    if (!_running) {
      _running = true;
      unawaited(_run());
    }
    _signal();
  }

  void _signal() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  Future<void> _run() async {
    try {
      while (!_cancelled) {
        if (_sentences.isEmpty) {
          if (_inputClosed) break;
          _wake = Completer<void>();
          await _wake!.future;
          continue;
        }

        final sentence = _sentences.removeFirst();
        try {
          await _output.add(sentence);
        } catch (e) {
          // Stop synthesizing, but let what was already handed over play out
          _sentences.clear();
          _inputClosed = true;
          onError?.call(e);
          break;
        }
      }
    } finally {
      _running = false;
      if (!_finished.isCompleted) _finished.complete();
    }
  }
}
