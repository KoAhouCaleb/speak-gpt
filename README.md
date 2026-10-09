# Grace

<img src="https://assistant.teslasoft.org/SPEAKGPT_BANNER_ANDROID.png" style="width: 100%;"/>

Grace (formerly SpeakGPT) is an advanced and highly intuitive open-source AI assistant that utilizes the powerful large language models (LLM) to provide you with unparalleled performance and functionality. Officially it supports GPT models, LLAMA, MIXTRAL, GEMMA, Gemini (regular and pro) Vision, DALL-E and other models.

> [!NOTE]
> 
> This project was a part of my Bachelor Thesis. Attribution is required to use this work. Copyright (c) 2023-2026 Dmytro Ostapenko. All rights reserved.
>
> Cite as: Dmytro Ostapenko (2024), "Review Program Automation Using Copilot Services" Bachelor Thesis, Technical University of Košice, 2024.


## Flutter port

This branch is a Flutter port of the original native Android app. The application id is `com.grace.assistant` and the app name is Grace.

Ported:

- Chats: create, rename, pin, delete, share as text; streaming answers with reasoning display (`reasoning_content`, `reasoning`, `reasoning_text`, `thinking` and inline `<think>` blocks); Markdown; edit, copy, read aloud, delete and regenerate.
- Per-chat and default settings: endpoint, model (loaded from `/models`), system message, temperature, top-p, penalties, seed, max tokens, logit bias sets.
- API endpoints with keys in secure storage, presets from `assets/ai_sets.json`, prompts library, image library.
- Vision: attach pictures from the gallery or camera, paste a picture from the clipboard (long press in the text box, "Paste image") or insert one from the keyboard.
- Share into Grace: text and pictures from the share sheet, and selected text through the "Grace" item of the text selection menu, open the compact assistant with the content ready to send. A share of several pictures uses the first one.
- Chat conveniences: message prefix and end separator (added to what the model receives, not shown), silent mode and always-speak mode per chat (answers are read aloud after dictated messages by default), `/imagine` on or off, automatic sending of dictated messages, errors kept in the chat (and not sent back to the model) or shown only in a banner.
- Image generation with `/imagine <description>`.
- Voice: dictation (speech_to_text) and reading answers aloud with Android text to speech (flutter_tts) or the `/audio/speech` route of the chat's API endpoint with a choice of voice and model, or your own OpenAI-compatible speech servers (`/audio/transcriptions` and `/audio/speech`, tested against the Qwen3-ASR and Kokoro-FastAPI shapes) under Settings > Speech servers.
- Hands-free voice (Settings > Hands-free):
  - Voice activity detection (VAD) with the [`vad`](https://pub.dev/packages/vad) package (Silero v5, the model is bundled in `assets/vad/`). It cuts your message out of the microphone audio, ends it when you stop talking, and sends that audio to the speech to text server (Settings > Speech servers) for transcription. It therefore needs a speech server; without one the standard dictation is used and a note says so. There is a switch for each way of starting: after pressing Dictate, the headset button (long press, `VOICE_COMMAND`), the assistant gesture, and the wake word. Triggers with the switch on start listening as soon as Grace opens. Under Advanced VAD settings: minimum speech frames, pre-speech pad frames, redemption frames, and the positive and negative speech thresholds (a frame is 32 ms). The package replaces the exact values 1, 8 and 3 of pre-speech pad, redemption and minimum speech frames with its own v5 defaults (3, 24, 9), so those three values cannot be chosen exactly. If nobody speaks for 15 seconds the listening stops.
  - Wake word with the [`open_wake_word`](https://pub.dev/packages/open_wake_word) package and the "hey jarvis" model (`assets/wake/`). While Grace is open it listens for the phrase, then opens a new chat (or uses the chat that is open) and starts listening, with VAD if its switch is on, otherwise with the standard dictation. It stops listening when Grace goes to the background; always-on listening would need a foreground service and is not part of this. The wake word and the VAD share one microphone recording (`MicHub`). To use a "hey grace" model later, put the trained `.onnx` into `assets/wake/`, list it in `pubspec.yaml`, and change `modelAsset` and `phrase` in `lib/services/wake_word_service.dart`.
- Streaming speech: answers are read aloud while they are written. A splitter cuts the growing answer into sentences (Markdown, code and links are not spoken) and a FIFO queue feeds them to the speech output one at a time. With Android text to speech the engine's own queue makes the next sentence follow without a gap. With a speech server or API endpoint each sentence is synthesized while the previous one plays, and `AudioQueue.kt` prepares the next `MediaPlayer` in advance and chains it with `setNextMediaPlayer`, so Android starts it the moment the current one ends. WAV avoids the encoder padding of MP3 at the joins.
- Self-hosted friendly networking: plain http addresses are allowed, and certificate authorities installed by the user in the Android settings are trusted by every request (Android's network security config plus the same certificates handed to the Dart HTTP client).
- Tools (function calling), each off, ask-each-time or allowed: date and time, read screen, QR code reading from the captured screenshot (pure Dart, several codes per screen), list and open apps, navigation with stops, music search, call (contact lookup), texts that are sent directly (SMS permission, with the messaging app as the fallback), calendar events (list, add, change, delete), alarms and timers through the clock app, and a to-do list kept on a Super Productivity SuperSync server (list, add, change, complete, delete; Settings > Tools > Task server). SuperSync only accepts end-to-end encrypted data, so Grace needs the access token and the encryption password of the Super Productivity app, and a self-signed server certificate can be pasted as PEM, open web page, browser search, internet search through SearXNG, image generation.
- Digital assistant: see below.
- Light, dark and AMOLED themes.

Not ported: the translated strings (the UI is English only for now).

### Assistant (screen context without accessibility)

The assistant opens as a compact sheet over the current app (`AssistOverlayActivity`, a transparent window running its own Flutter entry point, `assistOverlayMain`). A chat is only created once you send a message. The expand button continues the chat in the main window. The "Compact assistant" setting switches back to opening the full app.

The accessibility service from the native app is gone. Grace registers as a digital assistant (`VoiceInteractionService` in `android/app/src/main/kotlin/com/grace/assistant/assist/`). When the user invokes the assistant gesture, `GraceSession` receives the screen text (`AssistStructure`) and a screenshot from the system, saves them to the cache and opens Grace with a new chat that has them attached.

To use it: Android settings, Default apps, Digital assistant app, choose Grace, and turn on "Use text from screen" and "Use screenshot". Apps that block screen capture (`FLAG_SECURE`) and password fields are not readable. The session only waits for the data that the system announces in the invocation flags and does not try to force a second request.

## Build

```
flutter pub get
flutter test
flutter run
flutter build apk
```

Requires Flutter 3.35.2 or newer (Dart 3.9.2, needed by `open_wake_word`); CI uses 3.35.7.

## License

See [LICENSE.md](LICENSE.md). Attribution to the original SpeakGPT author is required.
