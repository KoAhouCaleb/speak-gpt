/// Tuning of the voice activity detector (the `vad` package, Silero v5 model).
///
/// The model looks at 512 samples of 16 kHz audio at a time, a frame of 32 ms, and gives each
/// frame a probability of being speech. The frame counts below are in those frames.
class VadParams {
  const VadParams({
    required this.minSpeechFrames,
    required this.preSpeechPadFrames,
    required this.redemptionFrames,
    required this.positiveSpeechThreshold,
    required this.negativeSpeechThreshold,
  });

  /// Duration of one frame in milliseconds.
  static const frameMs = 32;

  /// The defaults of the vad package for the v5 model.
  static const defaults = VadParams(
    minSpeechFrames: 9,
    preSpeechPadFrames: 3,
    redemptionFrames: 24,
    positiveSpeechThreshold: 0.5,
    negativeSpeechThreshold: 0.35,
  );

  /// Speech shorter than this is a misfire (a click or a cough) and is thrown away.
  final int minSpeechFrames;

  /// Audio kept from before the detector noticed the speech, so that the first word is not cut.
  final int preSpeechPadFrames;

  /// Silence that is tolerated inside a message. The message ends after this many quiet frames.
  final int redemptionFrames;

  /// A frame at or above this probability counts as speech.
  final double positiveSpeechThreshold;

  /// A frame below this probability counts as silence while speech is going on.
  final double negativeSpeechThreshold;

  VadParams copyWith({
    int? minSpeechFrames,
    int? preSpeechPadFrames,
    int? redemptionFrames,
    double? positiveSpeechThreshold,
    double? negativeSpeechThreshold,
  }) => VadParams(
    minSpeechFrames: minSpeechFrames ?? this.minSpeechFrames,
    preSpeechPadFrames: preSpeechPadFrames ?? this.preSpeechPadFrames,
    redemptionFrames: redemptionFrames ?? this.redemptionFrames,
    positiveSpeechThreshold:
        positiveSpeechThreshold ?? this.positiveSpeechThreshold,
    negativeSpeechThreshold:
        negativeSpeechThreshold ?? this.negativeSpeechThreshold,
  );

  @override
  bool operator ==(Object other) =>
      other is VadParams &&
      other.minSpeechFrames == minSpeechFrames &&
      other.preSpeechPadFrames == preSpeechPadFrames &&
      other.redemptionFrames == redemptionFrames &&
      other.positiveSpeechThreshold == positiveSpeechThreshold &&
      other.negativeSpeechThreshold == negativeSpeechThreshold;

  @override
  int get hashCode => Object.hash(
    minSpeechFrames,
    preSpeechPadFrames,
    redemptionFrames,
    positiveSpeechThreshold,
    negativeSpeechThreshold,
  );
}
