package com.grace.assistant

import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode

/**
 * The compact assistant: a transparent window over the app the user was in. It runs the
 * assistOverlayMain entry point in its own Flutter engine and draws a bottom sheet.
 */
class AssistOverlayActivity : GraceFlutterActivity() {

    override fun getDartEntrypointFunctionName(): String = "assistOverlayMain"

    // A transparent background lets the app behind show through the Flutter view
    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent
}
