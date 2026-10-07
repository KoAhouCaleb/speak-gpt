/**************************************************************************
 * Copyright (c) 2023-2026 Dmytro Ostapenko. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *  http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **************************************************************************/

package org.teslasoft.assistant.assist

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
 * A voice interaction service must declare a recognition service, and Android may make it the
 * default speech recognizer when SpeakGPT becomes the digital assistant. To avoid breaking speech
 * recognition for SpeakGPT and other apps, this service forwards requests to another installed
 * recognizer (Google by default).
 * */
class AssistRecognitionService : RecognitionService() {

    companion object {
        private val preferredPackages = listOf(
            "com.google.android.googlequicksearchbox",
            "com.google.android.as",
            "com.google.android.tts"
        )

        /**
         * Find a recognition service that does not belong to this app.
         * */
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
        } catch (_: Exception) { /* client is gone */ }
    }

    override fun onStartListening(recognizerIntent: Intent?, listener: RecognitionService.Callback?) {
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
                override fun onEvent(eventType: Int, params: Bundle?) { /* unused */ }
            })

            startListening(recognizerIntent ?: Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH))
        }
    }

    override fun onStopListening(listener: RecognitionService.Callback?) {
        recognizer?.stopListening()
    }

    override fun onCancel(listener: RecognitionService.Callback?) {
        recognizer?.cancel()
    }

    override fun onDestroy() {
        recognizer?.destroy()
        recognizer = null
        super.onDestroy()
    }
}
