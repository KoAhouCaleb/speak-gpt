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

package org.teslasoft.assistant.util

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Fetches the model list from the /models endpoint of an OpenAI-compatible API.
 * */
object ModelListClient {

    const val TAG = "ModelListClient"

    private val json = Json {
        isLenient = true
        ignoreUnknownKeys = true
    }

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    /**
     * Whether a model id looks like a text generation model.
     * Fine-tuned models are always kept.
     * */
    fun isTextModel(id: String): Boolean {
        if (id.contains("ft:") || id.contains(":ft")) return true
        return !id.contains("tts") && !id.contains("dall") && !id.contains("whisper") && !id.contains("embedding") && !id.contains("vision")
    }

    /**
     * Fetch text generation model ids.
     *
     * @param host API base URL (for example https://api.openai.com/v1/).
     * @param apiKey API key.
     * @return Sorted list of model ids.
     * @throws IOException on network or HTTP errors.
     * */
    suspend fun fetchTextModels(host: String, apiKey: String): List<String> = withContext(Dispatchers.IO) {
        val url = modelsUrl(host)
        Log.i(TAG, "GET $url (API key set: ${apiKey.isNotBlank()})")
        val startedAt = System.currentTimeMillis()

        val request = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $apiKey")
            .get()
            .build()

        client.newCall(request).execute().use { response ->
            val body = response.body.string()
            Log.i(TAG, "HTTP ${response.code} from $url in ${System.currentTimeMillis() - startedAt} ms, ${body.length} chars")
            if (!response.isSuccessful) {
                Log.w(TAG, "Error body: ${body.take(500)}")
                throw IOException("HTTP ${response.code}: ${body.take(500)}")
            }

            val data = json.parseToJsonElement(body).jsonObject["data"]?.jsonArray
            if (data == null) {
                Log.w(TAG, "Response has no \"data\" array: ${body.take(500)}")
                return@use emptyList()
            }

            val ids = data.mapNotNull { (it.jsonObject["id"] as? JsonPrimitive)?.contentOrNull }
            val textModels = ids.filter { isTextModel(it) }.distinct().sorted()
            Log.i(TAG, "${ids.size} models returned, ${textModels.size} kept as text models")
            textModels
        }
    }

    /**
     * Build the /models URL for an API base URL.
     * */
    fun modelsUrl(host: String): String {
        return if (host.endsWith("/")) host + "models" else "$host/models"
    }
}
