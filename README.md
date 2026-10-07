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

Ported: chat list (create, rename, pin, delete), streaming chat with reasoning display (`reasoning_content`, `reasoning`, `reasoning_text`, `thinking` fields and inline `<think>` blocks), Markdown rendering, message edit/copy/delete/regenerate, per-chat model and sampling settings, API endpoint management with keys kept in secure storage, model list loading from `/models`, the preset list in `assets/ai_sets.json`, light/dark/AMOLED themes.

Not ported yet: voice input and text-to-speech, the system assistant overlay and screen capture, tool calling, image generation and editing, logit bias sets, the prompts library and the ad/support flows.

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
