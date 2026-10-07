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

import com.aallam.openai.api.chat.ChatCompletionRequest
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.isActive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Streaming chat completion client that keeps reasoning output.
 *
 * The bundled OpenAI client drops unknown delta fields, so reasoning returned by
 * OpenAI-compatible servers (DeepSeek, vLLM, llama.cpp, Ollama, OpenRouter, LM Studio...)
 * is lost. This client sends the same request and reads both the regular content and
 * the reasoning fields from every chunk.
 * */
object ChatStreamClient {

    /**
     * A single streamed delta.
     *
     * @param content Regular answer text (may be null).
     * @param reasoning Reasoning text (may be null).
     * */
    data class Delta(val content: String?, val reasoning: String?)

    private val json = Json {
        isLenient = true
        ignoreUnknownKeys = true
    }

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(120, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .build()
    }

    // Field names used by different OpenAI-compatible servers for reasoning output.
    private val reasoningKeys = listOf("reasoning_content", "reasoning", "reasoning_text", "thinking")

    /**
     * Stream chat completion.
     *
     * @param host API base URL (for example https://api.openai.com/v1/).
     * @param apiKey API key.
     * @param request Chat completion request.
     * @return Flow of deltas. Run it on Dispatchers.IO.
     * */
    fun stream(host: String, apiKey: String, request: ChatCompletionRequest): Flow<Delta> = flow {
        val body = json.encodeToJsonElement(ChatCompletionRequest.serializer(), request).jsonObject.toMutableMap()
        body["stream"] = JsonPrimitive(true)

        val httpRequest = Request.Builder()
            .url(host.trimEnd('/') + "/chat/completions")
            .header("Authorization", "Bearer $apiKey")
            .header("Accept", "text/event-stream")
            .post(JsonObject(body).toString().toRequestBody("application/json".toMediaType()))
            .build()

        val call = client.newCall(httpRequest)

        // Abort blocking network read as soon as the collector is cancelled
        val handle = currentCoroutineContext()[Job]?.invokeOnCompletion { call.cancel() }

        try {
            call.execute().use { response ->
                if (!response.isSuccessful) {
                    throw IOException("HTTP ${response.code}: ${response.body.string()}")
                }

                val source = response.body.source()

                while (currentCoroutineContext().isActive) {
                    val line = source.readUtf8Line() ?: break
                    if (!line.startsWith("data:")) continue

                    val data = line.removePrefix("data:").trim()
                    if (data == "[DONE]") break
                    if (data.isEmpty()) continue

                    val delta = parseChunk(data)
                    if (delta != null) emit(delta)
                }
            }
        } finally {
            handle?.dispose()
            call.cancel()
        }
    }

    private fun parseChunk(data: String): Delta? {
        val chunk = try {
            json.parseToJsonElement(data).jsonObject
        } catch (_: Exception) {
            return null
        }

        chunk["error"]?.takeIf { it !is JsonNull }?.let { throw IOException(it.toString()) }

        val choices = chunk["choices"]?.let { runCatching { it.jsonArray }.getOrNull() } ?: return null
        if (choices.isEmpty()) return null

        val delta = runCatching { choices[0].jsonObject["delta"]?.jsonObject }.getOrNull() ?: return null

        val content = delta["content"].stringOrNull()
        var reasoning: String? = null

        for (key in reasoningKeys) {
            val value = delta[key].stringOrNull()
            if (!value.isNullOrEmpty()) {
                reasoning = value
                break
            }
        }

        if (content.isNullOrEmpty() && reasoning.isNullOrEmpty()) return null

        return Delta(content, reasoning)
    }

    private fun JsonElement?.stringOrNull(): String? {
        return (this as? JsonPrimitive)?.contentOrNull
    }

    /**
     * Some servers put reasoning inline in content wrapped in <think>...</think>.
     * Splits accumulated content into reasoning and visible answer.
     *
     * @param raw Accumulated content.
     * @return Pair of reasoning and visible content.
     * */
    fun splitThinkTags(raw: String): Pair<String, String> {
        val openTag = "<think>"
        val closeTag = "</think>"
        val trimmed = raw.trimStart()

        // Opening tag is still arriving
        if (trimmed.isNotEmpty() && openTag.startsWith(trimmed)) return Pair("", "")

        if (!trimmed.startsWith(openTag)) {
            // Some models (e.g. QwQ, DeepSeek R1 distills) omit the opening tag
            val closeIndex = raw.indexOf(closeTag)
            if (closeIndex != -1 && !raw.substring(0, closeIndex).contains(openTag)) {
                return Pair(raw.substring(0, closeIndex).trim(), raw.substring(closeIndex + closeTag.length).trimStart())
            }
            return Pair("", raw)
        }

        val inner = trimmed.substring(openTag.length)
        val closeIndex = inner.indexOf(closeTag)

        return if (closeIndex == -1) {
            // Hide a closing tag that is still arriving (e.g. "</th")
            var reasoning = inner
            for (length in minOf(closeTag.length - 1, reasoning.length) downTo 1) {
                if (reasoning.endsWith(closeTag.substring(0, length))) {
                    reasoning = reasoning.dropLast(length)
                    break
                }
            }
            Pair(reasoning.trim(), "")
        } else {
            Pair(inner.substring(0, closeIndex).trim(), inner.substring(closeIndex + closeTag.length).trimStart())
        }
    }
}
