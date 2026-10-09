import 'dart:async';
import 'dart:typed_data';

import 'package:open_wake_word/open_wake_word.dart';

import 'mic_hub.dart';

/// The wake word engine. A seam for tests, the real one is [OpenWakeWordEngine].
abstract class WakeWordEngine {
  Future<bool> init();

  /// Feeds [WakeWordService.chunkSamples] samples of 16 kHz audio.
  void process(Int16List samples);

  /// True once after the wake word was heard.
  bool takeActivation();

  void destroy();
}

/// openWakeWord through the `open_wake_word` package.
class OpenWakeWordEngine implements WakeWordEngine {
  const OpenWakeWordEngine();

  @override
  Future<bool> init() => OpenWakeWord.init(
    melModelAssetPath: WakeWordService.melAsset,
    embModelAssetPath: WakeWordService.embeddingAsset,
    wwModelAssetPaths: const [WakeWordService.modelAsset],
  );

  @override
  void process(Int16List samples) => OpenWakeWord.processAudio(samples);

  @override
  bool takeActivation() => OpenWakeWord.isActivated();

  @override
  void destroy() => OpenWakeWord.destroy();
}

/// Listens to the microphone for the wake word and calls [onDetected] when it is heard.
///
/// The phrase is "hey jarvis", the model that openWakeWord ships. A model for "hey grace" is to
/// be trained; it replaces [modelAsset] and [phrase] and nothing else changes.
class WakeWordService {
  WakeWordService({
    MicHub? mic,
    WakeWordEngine engine = const OpenWakeWordEngine(),
    required this.onDetected,
  }) : _mic = mic ?? MicHub.shared,
       _engine = engine;

  static const phrase = 'Hey Jarvis';

  static const melAsset = 'assets/wake/melspectrogram.onnx';
  static const embeddingAsset = 'assets/wake/embedding_model.onnx';
  static const modelAsset = 'assets/wake/hey_jarvis_v0.1.onnx';

  /// openWakeWord takes audio in blocks of 80 ms.
  static const chunkSamples = 1280;

  /// A second detection right after the first one is the same utterance.
  static const cooldown = Duration(seconds: 2);

  final MicHub _mic;
  final WakeWordEngine _engine;
  final void Function() onDetected;

  StreamSubscription<Uint8List>? _subscription;
  bool _engineReady = false;
  bool _running = false;
  DateTime _lastDetection = DateTime.fromMillisecondsSinceEpoch(0);

  // Samples that do not fill a block yet
  final List<int> _pending = [];

  bool get running => _running;

  /// Starts listening. Returns false when the engine, or the microphone, is not available.
  Future<bool> start() async {
    if (_running) return true;
    _running = true;

    try {
      if (!_engineReady) _engineReady = await _engine.init();
    } catch (_) {
      _engineReady = false;
    }
    if (!_engineReady || !_running) {
      _running = false;
      return false;
    }

    if (!await _mic.acquire(this)) {
      _running = false;
      _destroyEngine();
      return false;
    }
    if (!_running) {
      // stop() was called while the microphone was starting
      await _mic.release(this);
      _destroyEngine();
      return false;
    }

    _subscription = _mic.stream.listen(_onAudio);
    return true;
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _subscription?.cancel();
    _subscription = null;
    _pending.clear();
    await _mic.release(this);
    _destroyEngine();
  }

  void _destroyEngine() {
    if (!_engineReady) return;
    _engineReady = false;
    try {
      _engine.destroy();
    } catch (_) {
      // Already gone
    }
  }

  void _onAudio(Uint8List bytes) {
    if (!_running || !_engineReady) return;

    final data = ByteData.sublistView(bytes);
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      _pending.add(data.getInt16(i, Endian.little));
    }

    while (_pending.length >= chunkSamples) {
      final chunk = Int16List.fromList(_pending.sublist(0, chunkSamples));
      _pending.removeRange(0, chunkSamples);
      _engine.process(chunk);

      // Reading clears the activation, so it is always read, also when it is not used
      if (!_engine.takeActivation()) continue;

      final now = DateTime.now();
      if (now.difference(_lastDetection) < cooldown) continue;
      // Somebody else is recording a message: the words are not meant for the wake word
      if (_mic.usedByOthers(this)) continue;

      _lastDetection = now;
      onDetected();
    }
  }
}
