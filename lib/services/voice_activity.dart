import 'dart:async';
import 'dart:typed_data';

import 'package:vad/vad.dart';

import 'vad_params.dart';

/// Listens to a microphone stream and returns one spoken message, cut out of the audio by the
/// `vad` package (Silero v5). The message starts when speech is detected and ends when the
/// speaker has been quiet for [VadParams.redemptionFrames] frames.
class VoiceActivityDetector {
  VoiceActivityDetector({VadHandler Function()? createHandler})
    : _createHandler = createHandler ?? (() => VadHandler.create());

  /// Without any speech for this long, [listen] gives up and returns null.
  static const noSpeechTimeout = Duration(seconds: 15);

  /// Bundled model. The package would download it from a CDN otherwise.
  static const modelAssetFolder = 'assets/vad/';

  final VadHandler Function() _createHandler;

  VadHandler? _handler;
  Completer<List<double>?>? _result;
  List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _timeout;

  bool get listening => _result != null;

  /// Waits for one message in [audio] (16 kHz, mono, 16 bit PCM) and returns its samples
  /// between -1 and 1. Returns null when nobody spoke before [timeout], when [finish] found
  /// no speech and when [cancel] was called. Throws when the detector cannot run.
  Future<List<double>?> listen(
    VadParams params, {
    required Stream<Uint8List> audio,
    void Function()? onSpeechStart,
    Duration timeout = noSpeechTimeout,
  }) async {
    if (listening) throw StateError('Already listening');

    final handler = _handler = _createHandler();
    final result = _result = Completer<List<double>?>();

    _subscriptions = [
      handler.onRealSpeechStart.listen((_) {
        // The speaker is talking, the timeout is only about silence at the start
        _timeout?.cancel();
        onSpeechStart?.call();
      }),
      handler.onSpeechEnd.listen((samples) => _complete(result, samples)),
      handler.onError.listen(
        (message) => _complete(result, null, error: Exception(message)),
      ),
    ];
    _timeout = Timer(timeout, () => _complete(result, null));

    try {
      await handler.startListening(
        model: 'v5',
        // The v5 model takes 512 samples at a time
        frameSamples: 512,
        positiveSpeechThreshold: params.positiveSpeechThreshold,
        negativeSpeechThreshold: params.negativeSpeechThreshold,
        minSpeechFrames: params.minSpeechFrames,
        preSpeechPadFrames: params.preSpeechPadFrames,
        redemptionFrames: params.redemptionFrames,
        // Ending the session while somebody is talking hands over what was said so far
        submitUserSpeechOnPause: true,
        baseAssetPath: modelAssetFolder,
        audioStream: audio,
      );
    } catch (e) {
      _complete(result, null, error: e);
    }

    return result.future;
  }

  /// Ends the message now. What was said so far is returned by [listen], or null if nothing was.
  Future<void> finish() async {
    final result = _result;
    final handler = _handler;
    if (result == null || handler == null) return;

    // Pausing forces the end of the speech in progress, the event arrives asynchronously
    await handler.pauseListening();
    await Future<void>.delayed(Duration.zero);
    _complete(result, null);
  }

  /// Stops listening and drops whatever was heard.
  void cancel() {
    final result = _result;
    if (result != null) _complete(result, null);
  }

  void _complete(
    Completer<List<double>?> result,
    List<double>? samples, {
    Object? error,
  }) {
    if (result.isCompleted) return;
    // The completer is ignored once it is done, so a late event cannot end the next session
    if (!identical(_result, result)) return;

    _timeout?.cancel();
    _timeout = null;
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions = [];

    final handler = _handler;
    _handler = null;
    _result = null;
    if (handler != null) unawaited(_dispose(handler));

    if (error != null) {
      result.completeError(error);
    } else {
      result.complete(samples == null || samples.isEmpty ? null : samples);
    }
  }

  Future<void> _dispose(VadHandler handler) async {
    try {
      await handler.dispose();
    } catch (_) {
      // Nothing left to release
    }
  }
}
