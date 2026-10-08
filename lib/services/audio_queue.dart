import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

/// Plays audio files back to back.
///
/// On Android the work is done by AudioQueue.kt, which prepares every file while the one before
/// it plays and chains them with MediaPlayer.setNextMediaPlayer, so the system starts the next
/// file the moment the current one ends. Elsewhere files are played one after another with
/// audioplayers, which leaves a short gap between them.
class AudioQueuePlayer {
  static const _channel = MethodChannel('com.grace.assistant/native');

  AudioPlayer? _fallbackPlayer;
  Future<void> _fallbackChain = Future.value();
  int _generation = 0;

  /// Queues a file. The file is deleted after it has been played.
  Future<void> enqueue(String path) async {
    try {
      await _channel.invokeMethod<void>('audioEnqueue', {'path': path});
    } on MissingPluginException {
      _enqueueFallback(path);
    }
  }

  /// Stops playback and drops everything that is queued.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('audioStop');
    } on MissingPluginException {
      _generation++;
      await _fallbackPlayer?.stop();
    }
  }

  void _enqueueFallback(String path) {
    final generation = _generation;
    _fallbackChain = _fallbackChain.then((_) async {
      if (generation != _generation) return;
      try {
        final player = _fallbackPlayer ??= AudioPlayer();
        final done = player.onPlayerComplete.first;
        await player.play(DeviceFileSource(path));
        await done;
      } catch (_) {
        // A file that cannot be played must not block the ones behind it
      }
    });
  }

  void dispose() {
    _generation++;
    _fallbackPlayer?.dispose();
  }
}
