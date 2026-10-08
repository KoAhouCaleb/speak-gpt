package com.grace.assistant.assist

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

/**
 * A voice interaction service has to name a recognition service, and Android may make that
 * service the default speech recognizer when Grace becomes the digital assistant. To avoid
 * breaking speech recognition for Grace and other apps, this service does no recognition of
 * its own: it forwards each request to another installed recognizer (Google by default).
 */
class AssistRecognitionService : RecognitionService() {

    companion object {
        private val preferredPackages = listOf(
            "com.google.android.googlequicksearchbox",
            "com.google.android.as",
            "com.google.android.tts",
        )

        /** A recognition service that does not belong to this app, or null if there is none. */
        fun findDelegate(context: Context): ComponentName? {
            // Reading the default may be restricted on newer Android versions
            val default = try {
                Settings.Secure.getString(context.contentResolver, "voice_recognition_service")
                    ?.let { ComponentName.unflattenFromString(it) }
            } catch (_: Exception) {
                null
            }

            if (default != null && default.packageName != context.packageName) return default

            val services = context.packageManager
                .queryIntentServices(Intent(RecognitionService.SERVICE_INTERFACE), 0)
                .mapNotNull { it.serviceInfo }
                .filter { it.packageName != context.packageName }

            val service = preferredPackages.firstNotNullOfOrNull { pkg -> services.firstOrNull { it.packageName == pkg } }
                ?: services.firstOrNull { it.packageName.startsWith("com.google.") }
                ?: services.firstOrNull()

            return service?.let { ComponentName(it.packageName, it.name) }
        }
    }

    private var recognizer: SpeechRecognizer? = null

    private fun safe(block: () -> Unit) {
        try {
            block()
        } catch (_: Exception) {
            // The client is gone
        }
    }

    override fun onStartListening(recognizerIntent: Intent?, listener: Callback?) {
        if (listener == null) return

        val delegate = findDelegate(this)
        if (delegate == null) {
            safe { listener.error(SpeechRecognizer.ERROR_CLIENT) }
            return
        }

        recognizer?.destroy()
        recognizer = SpeechRecognizer.createSpeechRecognizer(this, delegate).apply {
            setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) = safe { listener.readyForSpeech(params ?: Bundle()) }
                override fun onBeginningOfSpeech() = safe { listener.beginningOfSpeech() }
                override fun onRmsChanged(rmsdB: Float) = safe { listener.rmsChanged(rmsdB) }
                override fun onBufferReceived(buffer: ByteArray?) = safe { listener.bufferReceived(buffer ?: ByteArray(0)) }
                override fun onEndOfSpeech() = safe { listener.endOfSpeech() }
                override fun onError(error: Int) = safe { listener.error(error) }
                override fun onResults(results: Bundle?) = safe { listener.results(results ?: Bundle()) }
                override fun onPartialResults(partialResults: Bundle?) = safe { listener.partialResults(partialResults ?: Bundle()) }
                override fun onEvent(eventType: Int, params: Bundle?) {
                    // Not forwarded
                }
            })

            startListening(recognizerIntent ?: Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH))
        }
    }

    override fun onStopListening(listener: Callback?) {
        recognizer?.stopListening()
    }

    override fun onCancel(listener: Callback?) {
        recognizer?.cancel()
    }

    override fun onDestroy() {
        recognizer?.destroy()
        recognizer = null
        super.onDestroy()
    }
}
