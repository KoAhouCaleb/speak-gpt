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
- Vision: attach pictures from the gallery or camera.
- Image generation with `/imagine <description>`.
- Voice: dictation (speech_to_text) and reading answers aloud (flutter_tts).
- Tools (function calling), each off, ask-each-time or allowed: date and time, read screen, list and open apps, navigation with stops, music search, call and text (contact lookup), open web page, browser search, internet search through SearXNG, image generation.
- Digital assistant: see below.
- Light, dark and AMOLED themes.

Not ported: the old floating assistant overlay, QR code reading, ads and support flows, and the translated strings (the UI is English only for now).

### Assistant (screen context without accessibility)

The accessibility service from the native app is gone. Grace registers as a digital assistant (`VoiceInteractionService` in `android/app/src/main/kotlin/com/grace/assistant/assist/`). When the user invokes the assistant gesture, `GraceSession` receives the screen text (`AssistStructure`) and a screenshot from the system, saves them to the cache and opens Grace with a new chat that has them attached.

To use it: Android settings, Default apps, Digital assistant app, choose Grace, and turn on "Use text from screen" and "Use screenshot". Apps that block screen capture (`FLAG_SECURE`) and password fields are not readable. The session only waits for the data that the system announces in the invocation flags and does not try to force a second request.

## Build

```
flutter pub get
flutter test
flutter run
flutter build apk
```

Requires Flutter 3.35 or newer.

## License

See [LICENSE.md](LICENSE.md). Attribution to the original SpeakGPT author is required.
