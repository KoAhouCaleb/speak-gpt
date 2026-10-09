import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

/// One microphone stream that the wake word detector and the voice activity detector share.
///
/// Two recorders on the same microphone fight over it on some devices, and the wake word has
/// to keep listening while the message is recorded. So there is a single 16 kHz mono 16 bit
/// recording that runs while anybody holds it, and every user listens to the same stream.
class MicHub {
  MicHub({AudioRecorder Function()? recorderFactory})
    : _recorderFactory = recorderFactory ?? AudioRecorder.new;

  /// The hub of this Flutter engine (the main window and the assistant sheet each have one).
  static final MicHub shared = MicHub();

  final AudioRecorder Function() _recorderFactory;
  final Set<Object> _owners = {};
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast();

  AudioRecorder? _recorder;
  bool _paused = false;
  StreamSubscription<Uint8List>? _subscription;

  // Starting and stopping the recorder are asynchronous, they must not overlap
  Future<void> _queue = Future<void>.value();

  /// PCM 16 bit little endian, 16 kHz, mono.
  Stream<Uint8List> get stream => _controller.stream;

  bool get active => _owners.isNotEmpty;

  /// Whether somebody other than [owner] holds the microphone.
  bool usedByOthers(Object owner) => _owners.any((o) => !identical(o, owner));

  /// Starts the recording for [owner] if it is not running yet. Returns false when the
  /// microphone permission was refused or the recording could not start.
  Future<bool> acquire(Object owner) {
    _owners.add(owner);
    return _enqueue(() async {
      if (!_owners.contains(owner)) return false;
      // Paused: the recording starts again with resume
      if (_paused || _recorder != null) return true;

      final started = await _start();
      if (!started) _owners.remove(owner);
      return started;
    });
  }

  Future<bool> _start() async {
    final recorder = _recorderFactory();
    try {
      if (!await recorder.hasPermission()) {
        await recorder.dispose();
        return false;
      }
      final audio = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
          autoGain: true,
        ),
      );
      _recorder = recorder;
      _subscription = audio.listen(
        _controller.add,
        onError: (Object e) => _controller.addError(e),
      );
      return true;
    } catch (_) {
      await recorder.dispose();
      return false;
    }
  }

  Future<void> _stop() async {
    final recorder = _recorder;
    if (recorder == null) return;
    _recorder = null;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await recorder.stop();
    } finally {
      await recorder.dispose();
    }
  }

  /// Stops the recording for a while, for something that needs the microphone for itself (the
  /// Android speech recognizer). The users stay registered and [resume] starts it again.
  Future<void> pause() {
    _paused = true;
    return _enqueue(_stop);
  }

  Future<void> resume() {
    _paused = false;
    return _enqueue(() async {
      if (_paused || _owners.isEmpty || _recorder != null) return;
      await _start();
    });
  }

  /// Gives the microphone back. The recording stops with its last user.
  Future<void> release(Object owner) {
    _owners.remove(owner);
    return _enqueue(() async {
      if (_owners.isEmpty) await _stop();
    });
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}
