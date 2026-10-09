import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/storage.dart';
import '../services/vad_params.dart';

/// The tuning of the voice activity detector (the `vad` package, Silero v5 model).
class VadSettingsScreen extends StatelessWidget {
  const VadSettingsScreen({super.key});

  // Smallest distance the two thresholds keep, so that speech can end again once it started
  static const _gap = 0.05;

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<Storage>();
    final p = storage.vadParams;

    String ms(int frames) => '${frames * VadParams.frameMs} ms';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Advanced VAD settings'),
        actions: [
          TextButton(
            onPressed: p == VadParams.defaults
                ? null
                : () => storage.setVadParams(VadParams.defaults),
            child: const Text('Defaults'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'The detector rates every frame of audio (${VadParams.frameMs} ms) as speech or not. '
              'The changes apply the next time you start listening.',
            ),
          ),
          _slider(
            label:
                'Minimum speech frames: ${p.minSpeechFrames} (${ms(p.minSpeechFrames)})',
            help:
                'Speech shorter than this is ignored as a click or a cough. Raise it if noises start messages.',
            value: p.minSpeechFrames.toDouble(),
            min: 1,
            max: 40,
            divisions: 39,
            onChanged: (v) =>
                storage.setVadParams(p.copyWith(minSpeechFrames: v.round())),
          ),
          _slider(
            label:
                'Pre-speech pad frames: ${p.preSpeechPadFrames} (${ms(p.preSpeechPadFrames)})',
            help:
                'Audio kept from before speech was detected, so the first word is not cut off.',
            value: p.preSpeechPadFrames.toDouble(),
            min: 0,
            max: 20,
            divisions: 20,
            onChanged: (v) =>
                storage.setVadParams(p.copyWith(preSpeechPadFrames: v.round())),
          ),
          _slider(
            label:
                'Redemption frames: ${p.redemptionFrames} (${ms(p.redemptionFrames)})',
            help:
                'How long you may be quiet before the message ends. Raise it if you are cut off while thinking.',
            value: p.redemptionFrames.toDouble(),
            min: 1,
            max: 100,
            divisions: 99,
            onChanged: (v) =>
                storage.setVadParams(p.copyWith(redemptionFrames: v.round())),
          ),
          _slider(
            label:
                'Positive speech threshold: ${p.positiveSpeechThreshold.toStringAsFixed(2)}',
            help:
                'A frame counts as speech from this probability. Raise it in noisy places, lower it if soft speech is missed.',
            value: p.positiveSpeechThreshold,
            min: 0.1,
            max: 0.95,
            divisions: 85,
            onChanged: (v) {
              final positive = _round(v);
              storage.setVadParams(
                p.copyWith(
                  positiveSpeechThreshold: positive,
                  negativeSpeechThreshold:
                      p.negativeSpeechThreshold > positive - _gap
                      ? _round(positive - _gap)
                      : null,
                ),
              );
            },
          ),
          _slider(
            label:
                'Negative speech threshold: ${p.negativeSpeechThreshold.toStringAsFixed(2)}',
            help:
                'A frame counts as silence below this probability. Keep it under the positive threshold.',
            value: p.negativeSpeechThreshold,
            min: 0.05,
            max: 0.9,
            divisions: 85,
            onChanged: (v) {
              final negative = _round(v);
              storage.setVadParams(
                p.copyWith(
                  negativeSpeechThreshold: negative,
                  positiveSpeechThreshold:
                      p.positiveSpeechThreshold < negative + _gap
                      ? _round(negative + _gap)
                      : null,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  static double _round(double v) => double.parse(v.toStringAsFixed(2));

  Widget _slider({
    required String label,
    required String help,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: label.split(': ').last,
            onChanged: onChanged,
          ),
          Builder(
            builder: (context) =>
                Text(help, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
