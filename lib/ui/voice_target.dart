/// A screen that can start listening when something other than its own button asks for it,
/// such as the wake word.
abstract interface class VoiceTarget {
  /// Whether the screen is in front of the user and idle, so that it can take the request.
  bool get canStartVoice;

  /// Starts listening. [trigger] is what asked, see Storage.vadForTrigger.
  Future<void> startVoice(String trigger);
}

/// The screen that takes voice requests. The newest chat screen registers itself.
class VoiceTargets {
  VoiceTargets._();

  static VoiceTarget? current;
}
