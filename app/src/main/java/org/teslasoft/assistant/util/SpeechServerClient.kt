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

package org.teslasoft.assistant.util

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import org.teslasoft.assistant.preferences.SpeechServerPreferences
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Client for self-hosted OpenAI-compatible speech servers.
 *
 * Tested API shapes:
 * - hangrylabs/qwen3-asr-stt: POST /v1/audio/transcriptions (multipart: file, model, response_format)
 * - remsky/Kokoro-FastAPI: POST /v1/audio/speech (json: model, input, voice, response_format),
 *   GET /v1/audio/voices
 *
 * All functions are blocking. Call them from Dispatchers.IO.
 * */
object SpeechServerClient {

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(120, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .build()
    }

    private fun url(host: String, path: String): String = host.trim().trimEnd('/') + "/" + path

    private fun Request.Builder.auth(apiKey: String): Request.Builder {
        if (apiKey.isNotBlank()) header("Authorization", "Bearer $apiKey")
        return this
    }

    /**
     * Transcribe audio file.
     *
     * @param config STT server config.
     * @param audio Audio file (m4a, mp3, wav, ...).
     * @return Transcribed text.
     * */
    fun transcribe(config: SpeechServerPreferences.Config, audio: File): String {
        val builder = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("file", audio.name, audio.asRequestBody("audio/mp4".toMediaType()))
            .addFormDataPart("response_format", "json")

        if (config.model.isNotBlank()) builder.addFormDataPart("model", config.model)
        if (config.language.isNotBlank()) builder.addFormDataPart("language", config.language)

        val request = Request.Builder()
            .url(url(config.host, "audio/transcriptions"))
            .auth(config.apiKey)
            .post(builder.build())
            .build()

        client.newCall(request).execute().use { response ->
            val body = response.body.string()
            if (!response.isSuccessful) throw IOException("HTTP ${response.code}: $body")

            return try {
                JSONObject(body).optString("text", "")
            } catch (_: Exception) {
                // response_format=text servers return plain text
                body
            }
        }
    }

    /**
     * Synthesize speech.
     *
     * @param config TTS server config.
     * @param text Text to speak.
     * @return MP3 audio bytes.
     * */
    fun speech(config: SpeechServerPreferences.Config, text: String): ByteArray {
        val json = JSONObject()
            .put("input", text)
            .put("voice", config.voice)
            .put("response_format", "mp3")

        if (config.model.isNotBlank()) json.put("model", config.model)

        val request = Request.Builder()
            .url(url(config.host, "audio/speech"))
            .auth(config.apiKey)
            .post(json.toString().toRequestBody("application/json".toMediaType()))
            .build()

        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("HTTP ${response.code}: ${response.body.string()}")
            return response.body.bytes()
        }
    }

    /**
     * List voices available on the TTS server (Kokoro-FastAPI: GET /v1/audio/voices).
     *
     * @param config TTS server config.
     * @return Voice IDs.
     * */
    fun listVoices(config: SpeechServerPreferences.Config): List<String> {
        val request = Request.Builder()
            .url(url(config.host, "audio/voices"))
            .auth(config.apiKey)
            .get()
            .build()

        client.newCall(request).execute().use { response ->
            val body = response.body.string()
            if (!response.isSuccessful) throw IOException("HTTP ${response.code}: $body")

            val array: JSONArray = if (body.trimStart().startsWith("[")) JSONArray(body) else JSONObject(body).optJSONArray("voices") ?: JSONArray()
            val voices = arrayListOf<String>()

            for (i in 0 until array.length()) {
                // Older versions return plain strings, newer return objects with an "id"
                val item = array.opt(i)
                val id = when (item) {
                    is JSONObject -> item.optString("id", item.optString("name", ""))
                    else -> item?.toString() ?: ""
                }
                if (id.isNotBlank()) voices.add(id)
            }

            return voices
        }
    }
}
