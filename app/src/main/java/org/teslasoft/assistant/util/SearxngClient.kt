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

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Web search through a user-provided SearXNG instance.
 *
 * Uses the JSON format of the search API (https://docs.searxng.org/dev/search_api.html),
 * which must be enabled in the instance's settings.yml (search.formats).
 * */
object SearxngClient {
    private const val MAX_SNIPPET_LENGTH = 400

    private val json = Json { isLenient = true; ignoreUnknownKeys = true }

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    /**
     * Search and format the results as plain text for the model. Blocking, run it on Dispatchers.IO.
     *
     * @param instanceUrl Base URL of the instance, e.g. https://search.example.com
     * @param query Search query.
     * @param maxResults Maximum number of web results.
     * */
    fun search(instanceUrl: String, query: String, maxResults: Int = 8): String {
        val base = instanceUrl.trim().trimEnd('/').removeSuffix("/search")
        val url = base.toHttpUrlOrNull()?.newBuilder()
            ?.addPathSegment("search")
            ?.addQueryParameter("q", query)
            ?.addQueryParameter("format", "json")
            ?.build()
            ?: throw IOException("The SearXNG URL \"$instanceUrl\" is not valid")

        val request = Request.Builder()
            .url(url)
            .header("Accept", "application/json")
            .header("User-Agent", "SpeakGPT")
            .build()

        val body = client.newCall(request).execute().use { response ->
            if (response.code == 403) {
                throw IOException("The SearXNG instance refused JSON results (HTTP 403). Enable the json format under search.formats in its settings.yml")
            }
            if (!response.isSuccessful) throw IOException("SearXNG returned HTTP ${response.code}")
            response.body.string()
        }

        val root = try {
            json.parseToJsonElement(body).jsonObject
        } catch (_: Exception) {
            throw IOException("SearXNG did not return JSON. Check the instance URL")
        }

        return format(root, maxResults)
    }

    private fun format(root: JsonObject, maxResults: Int): String {
        val builder = StringBuilder()

        // Direct answers (older versions return strings, newer ones objects with an "answer" field)
        val answers = (root["answers"] as? JsonArray).orEmpty().mapNotNull {
            it.text() ?: (it as? JsonObject)?.get("answer").text()
        }
        if (answers.isNotEmpty()) {
            builder.append("Answers:\n")
            answers.forEach { builder.append("- ").append(it).append('\n') }
            builder.append('\n')
        }

        (root["infoboxes"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }.forEach { infobox ->
            val title = infobox["infobox"].text()
            val content = infobox["content"].text()
            if (title != null || content != null) {
                builder.append("Infobox: ").append(listOfNotNull(title, content?.take(MAX_SNIPPET_LENGTH)).joinToString(" - ")).append("\n\n")
            }
        }

        val results = (root["results"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }.take(maxResults)

        if (results.isEmpty() && builder.isEmpty()) return "No results found."

        results.forEachIndexed { index, result ->
            builder.append(index + 1).append(". ").append(result["title"].text() ?: "(no title)").append('\n')
            result["url"].text()?.let { builder.append("   ").append(it).append('\n') }
            result["publishedDate"].text()?.let { builder.append("   Published: ").append(it).append('\n') }
            result["content"].text()?.takeIf { it.isNotBlank() }?.let { builder.append("   ").append(it.trim().take(MAX_SNIPPET_LENGTH)).append('\n') }
        }

        return builder.toString().trim()
    }

    private fun JsonElement?.text(): String? = (this as? JsonPrimitive)?.contentOrNull?.ifBlank { null }
}
