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

import android.content.Context
import android.util.Log
import androidx.core.content.edit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
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

    private const val CACHE_PREFERENCES = "model_list_cache"

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .eventListenerFactory { TimingListener() }
            .build()
    }

    // Requests run here, not in the dialog's scope, so closing the dialog does not
    // throw away a slow response. The result is cached for the next time it opens.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val inFlight = HashMap<String, Deferred<List<String>>>()

    /**
     * Logs how long each phase of a request takes (DNS, connect, TLS, server response).
     * */
    private class TimingListener : EventListener() {
        private var startedAt = 0L

        private fun elapsed(): Long = (System.nanoTime() - startedAt) / 1_000_000

        override fun callStart(call: Call) {
            startedAt = System.nanoTime()
        }

        override fun dnsEnd(call: Call, domainName: String, inetAddressList: List<InetAddress>) {
            Log.i(TAG, "DNS resolved $domainName at ${elapsed()} ms")
        }

        override fun connectEnd(call: Call, inetSocketAddress: InetSocketAddress, proxy: Proxy, protocol: okhttp3.Protocol?) {
            Log.i(TAG, "Connected to $inetSocketAddress ($protocol) at ${elapsed()} ms")
        }

        override fun requestHeadersEnd(call: Call, request: Request) {
            Log.i(TAG, "Request sent at ${elapsed()} ms, waiting for the server")
        }

        override fun responseHeadersEnd(call: Call, response: Response) {
            Log.i(TAG, "Server responded (HTTP ${response.code}) at ${elapsed()} ms")
        }
    }

    private fun cacheKey(host: String, apiKey: String): String = Hash.hash(host + apiKey)

    /**
     * Model ids saved by the last successful fetch for this endpoint, or an empty list.
     * */
    fun getCachedTextModels(context: Context, host: String, apiKey: String): List<String> {
        val saved = context.getSharedPreferences(CACHE_PREFERENCES, Context.MODE_PRIVATE)
            .getString(cacheKey(host, apiKey), null) ?: return emptyList()

        return try {
            json.parseToJsonElement(saved).jsonArray.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
        } catch (e: Exception) {
            Log.w(TAG, "Ignoring unreadable model cache", e)
            emptyList()
        }
    }

    private fun saveCachedTextModels(context: Context, host: String, apiKey: String, models: List<String>) {
        context.getSharedPreferences(CACHE_PREFERENCES, Context.MODE_PRIVATE).edit {
            putString(cacheKey(host, apiKey), JsonArray(models.map { JsonPrimitive(it) }).toString())
        }
    }

    /**
     * Start fetching text model ids, or join a fetch for the same endpoint that is already running.
     * The request keeps running if the caller is cancelled, and a successful result is cached.
     * */
    fun loadTextModels(context: Context, host: String, apiKey: String): Deferred<List<String>> {
        val key = cacheKey(host, apiKey)
        val appContext = context.applicationContext

        synchronized(inFlight) {
            val running = inFlight[key]
            if (running != null && running.isActive) {
                Log.i(TAG, "Joining the request already running for ${modelsUrl(host)}")
                return running
            }

            val request = scope.async {
                val models = fetchTextModels(host, apiKey)
                saveCachedTextModels(appContext, host, apiKey, models)
                models
            }
            request.invokeOnCompletion {
                synchronized(inFlight) { if (inFlight[key] === request) inFlight.remove(key) }
            }
            inFlight[key] = request
            return request
        }
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
