/**************************************************************************
 * Copyright (c) 2026 Caleb Hall. All rights reserved.
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

package org.teslasoft.assistant.preferences

import android.content.Context
import androidx.core.content.edit

/**
 * Global settings for self-hosted OpenAI-compatible speech servers.
 *
 * STT: e.g. hangrylabs/qwen3-asr-stt (POST /v1/audio/transcriptions)
 * TTS: e.g. remsky/Kokoro-FastAPI (POST /v1/audio/speech)
 * */
class SpeechServerPreferences private constructor(private val context: Context) {

    companion object {
        const val TYPE_STT = "stt"
        const val TYPE_TTS = "tts"

        private const val FILE = "speech_servers"
        private const val ENCRYPTED_FILE = "speech_servers_keys"

        fun getSpeechServerPreferences(context: Context): SpeechServerPreferences {
            return SpeechServerPreferences(context.applicationContext)
        }

        fun defaultHost(type: String): String = if (type == TYPE_STT) "http://192.168.1.2:8000/v1/" else "http://192.168.1.2:8880/v1/"

        fun defaultModel(type: String): String = if (type == TYPE_STT) "qwen3-asr" else "kokoro"
    }

    /**
     * Speech server configuration.
     *
     * @param enabled Whether the server overrides the built-in engine.
     * @param host API base URL including /v1/.
     * @param apiKey Optional API key (sent as Bearer token).
     * @param model Model name.
     * @param voice Voice name (TTS only).
     * @param language Optional language hint (STT only).
     * */
    data class Config(
        val enabled: Boolean,
        val host: String,
        val apiKey: String,
        val model: String,
        val voice: String,
        val language: String
    )

    private val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun getConfig(type: String): Config {
        return Config(
            enabled = prefs.getBoolean("${type}_enabled", false),
            host = prefs.getString("${type}_host", "") ?: "",
            apiKey = EncryptedPreferences.getEncryptedPreference(context, ENCRYPTED_FILE, "${type}_api_key"),
            model = prefs.getString("${type}_model", defaultModel(type)) ?: defaultModel(type),
            voice = prefs.getString("${type}_voice", "af_heart") ?: "af_heart",
            language = prefs.getString("${type}_language", "") ?: ""
        )
    }

    fun setConfig(type: String, config: Config) {
        prefs.edit {
            putBoolean("${type}_enabled", config.enabled)
            putString("${type}_host", config.host.trim())
            putString("${type}_model", config.model.trim())
            putString("${type}_voice", config.voice.trim())
            putString("${type}_language", config.language.trim())
        }

        EncryptedPreferences.setEncryptedPreference(context, ENCRYPTED_FILE, "${type}_api_key", config.apiKey.trim())
    }

    /**
     * @return true if self-hosted STT should be used instead of Google/Whisper.
     * */
    fun isSttEnabled(): Boolean = prefs.getBoolean("${TYPE_STT}_enabled", false) && (prefs.getString("${TYPE_STT}_host", "") ?: "").isNotBlank()

    /**
     * @return true if self-hosted TTS should be used instead of Google/OpenAI.
     * */
    fun isTtsEnabled(): Boolean = prefs.getBoolean("${TYPE_TTS}_enabled", false) && (prefs.getString("${TYPE_TTS}_host", "") ?: "").isNotBlank()
}
