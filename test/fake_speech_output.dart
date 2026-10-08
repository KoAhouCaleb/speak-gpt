import 'dart:async';

import 'package:assistant/services/speech_stream.dart';

/// Records what it is given. Each add can be held back to imitate a slow synthesis.
class FakeOutput implements SpeechOutput {
  FakeOutput({this.failOn});

  final String? failOn;
  final List<String> added = [];
  final List<String> events = [];
  Completer<void>? hold;
  int running = 0;
  int maxRunning = 0;
  bool stopped = false;

  @override
  Future<void> add(String sentence) async {
    running++;
    if (running > maxRunning) maxRunning = running;
    events.add('start $sentence');
    if (hold != null) await hold!.future;
    if (sentence == failOn) {
      running--;
      throw Exception('synthesis failed');
    }
    added.add(sentence);
    events.add('done $sentence');
    running--;
  }

  @override
  Future<void> stop() async => stopped = true;
}
