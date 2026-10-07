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

package org.teslasoft.assistant.tools

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.telephony.SmsManager
import android.util.Base64
import androidx.core.graphics.scale
import androidx.core.net.toUri
import com.aallam.openai.api.chat.ChatMessage
import com.aallam.openai.api.chat.ChatRole
import com.aallam.openai.api.chat.ImagePart
import com.aallam.openai.api.chat.TextPart
import com.aallam.openai.api.chat.Tool
import com.aallam.openai.api.chat.ToolCall
import com.aallam.openai.api.core.Parameters
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.NotFoundException
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.GlobalHistogramBinarizer
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeMultiReader
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.teslasoft.assistant.R
import org.teslasoft.assistant.assist.ScreenCaptureAccessibilityService
import org.teslasoft.assistant.preferences.Logger
import org.teslasoft.assistant.preferences.ToolPreferences
import org.teslasoft.assistant.util.ScreenContextStore
import java.io.ByteArrayOutputStream
import kotlin.coroutines.resume

/**
 * Tools the model can call and their execution.
 * */
object AssistantTools {

    /** Rounds of tool calls per user message before the model must answer in text. */
    const val MAX_ROUNDS = 6

    private const val MAX_IMAGE_SIDE = 1600
    private const val MAPS_PACKAGE = "com.google.android.apps.maps"

    /**
     * @param name Name sent to the model and settings key.
     * @param title Title on the settings page and in the chat.
     * @param description Description on the settings page.
     * @param needsScreen Only offered when the host can capture another app's screen.
     * */
    class Definition(
        val name: String,
        val title: Int,
        val description: Int,
        val defaultMode: ToolPreferences.Mode,
        val needsScreen: Boolean,
        val tool: Tool
    )

    /**
     * Result of one tool call.
     *
     * @param text Result sent to the model.
     * @param summary Short status shown in the chat.
     * @param image Image (data URL) the model should see.
     * @param afterTurn Action that runs after the model's turn has ended.
     * */
    private class Result(
        val text: String,
        val summary: String,
        val image: String? = null,
        val afterTurn: (() -> Unit)? = null
    )

    /**
     * Outcome of a round of tool calls.
     *
     * @param messages Tool results (and images) to append to the conversation.
     * @param log Lines describing the calls, shown in the chat.
     * @param ignored True if a call was ignored because SpeakGPT was in the background.
     * @param afterTurn Actions to run once the model's turn has ended. If not empty, the turn ends
     * without another request (e.g. image generation shows its own message).
     * */
    class Outcome(
        val messages: List<ChatMessage>,
        val log: List<String>,
        val ignored: Boolean,
        val afterTurn: List<() -> Unit>
    )

    val definitions: List<Definition> = listOf(
        Definition(
            "take_screenshot", R.string.tool_take_screenshot, R.string.tool_take_screenshot_desc,
            ToolPreferences.Mode.AUTO, needsScreen = true,
            tool = Tool.function(
                name = "take_screenshot",
                description = "Take a screenshot of the app the user is looking at (behind the assistant) and view it. Use this when the user refers to what is on their screen.",
                parameters = Parameters.Empty
            )
        ),
        Definition(
            "read_qr_code", R.string.tool_read_qr_code, R.string.tool_read_qr_code_desc,
            ToolPreferences.Mode.AUTO, needsScreen = true,
            tool = Tool.function(
                name = "read_qr_code",
                description = "Find QR codes on the user's screen and return the text they contain.",
                parameters = Parameters.Empty
            )
        ),
        Definition(
            "list_apps", R.string.tool_list_apps, R.string.tool_list_apps_desc,
            ToolPreferences.Mode.AUTO, needsScreen = false,
            tool = Tool.function(
                name = "list_apps",
                description = "List the apps installed on the device that can be opened (name and package name).",
                parameters = Parameters.Empty
            )
        ),
        Definition(
            "open_app", R.string.tool_open_app, R.string.tool_open_app_desc,
            ToolPreferences.Mode.AUTO, needsScreen = false,
            tool = Tool.function(
                name = "open_app",
                description = "Open an installed app. If you are not sure about the exact app name, call list_apps first.",
                parameters = stringParameters("name" to "App name as shown in the launcher, or its package name")
            )
        ),
        Definition(
            "start_navigation", R.string.tool_start_navigation, R.string.tool_start_navigation_desc,
            ToolPreferences.Mode.AUTO, needsScreen = false,
            tool = Tool.function(
                name = "start_navigation",
                description = "Start turn-by-turn navigation in Google Maps to a destination.",
                parameters = Parameters.buildJsonObject {
                    put("type", "object")
                    putJsonObject("properties") {
                        putJsonObject("destination") {
                            put("type", "string")
                            put("description", "Address, place name or \"latitude,longitude\"")
                        }
                        putJsonObject("mode") {
                            put("type", "string")
                            put("description", "Travel mode, driving if omitted")
                            putJsonArray("enum") {
                                add("driving")
                                add("walking")
                                add("bicycling")
                                add("two_wheeler")
                            }
                        }
                    }
                    putJsonArray("required") { add("destination") }
                }
            )
        ),
        Definition(
            "make_call", R.string.tool_make_call, R.string.tool_make_call_desc,
            ToolPreferences.Mode.CONFIRM, needsScreen = false,
            tool = Tool.function(
                name = "make_call",
                description = "Call a contact or a phone number.",
                parameters = stringParameters("contact" to "Contact name or phone number")
            )
        ),
        Definition(
            "send_text", R.string.tool_send_text, R.string.tool_send_text_desc,
            ToolPreferences.Mode.CONFIRM, needsScreen = false,
            tool = Tool.function(
                name = "send_text",
                description = "Send an SMS text message to a contact or a phone number.",
                parameters = stringParameters(
                    "contact" to "Contact name or phone number",
                    "message" to "Text of the message"
                )
            )
        ),
        Definition(
            "open_webpage", R.string.tool_open_webpage, R.string.tool_open_webpage_desc,
            ToolPreferences.Mode.AUTO, needsScreen = false,
            tool = Tool.function(
                name = "open_webpage",
                description = "Open a web page in the default browser.",
                parameters = stringParameters("url" to "URL of the page")
            )
        ),
        Definition(
            "search_internet", R.string.tool_search_internet, R.string.tool_search_internet_desc,
            ToolPreferences.Mode.AUTO, needsScreen = false,
            tool = Tool.function(
                name = "search_internet",
                description = "Open a Google search for a query in the default browser.",
                parameters = stringParameters("query" to "Search query")
            )
        ),
        Definition(
            "generate_image", R.string.tool_generate_image, R.string.tool_generate_image_desc,
            ToolPreferences.Mode.AUTO, needsScreen = false,
            tool = Tool.function(
                name = "generate_image",
                description = "Generate an image from a prompt. The image is shown to the user in the chat.",
                parameters = stringParameters("prompt" to "The prompt for image generation")
            )
        )
    )

    private fun stringParameters(vararg properties: Pair<String, String>): Parameters {
        return Parameters.buildJsonObject {
            put("type", "object")
            putJsonObject("properties") {
                for ((name, description) in properties) {
                    putJsonObject(name) {
                        put("type", "string")
                        put("description", description)
                    }
                }
            }
            putJsonArray("required") {
                for ((name, _) in properties) add(name)
            }
        }
    }

    /** Settings mode of a tool. */
    fun getMode(context: Context, definition: Definition): ToolPreferences.Mode {
        return ToolPreferences.getMode(context, definition.name, definition.defaultMode)
    }

    /** Tools offered to the model, or null if there are none. */
    fun enabledTools(context: Context, host: ToolHost): List<Tool>? {
        return definitions
            .filter { getMode(context, it) != ToolPreferences.Mode.DISABLED }
            .filter { !it.needsScreen || host.canCaptureScreen }
            .map { it.tool }
            .ifEmpty { null }
    }

    /**
     * Run a round of tool calls returned by the model.
     * Must be called on the main thread.
     * */
    suspend fun execute(context: Context, host: ToolHost, calls: List<ToolCall.Function>): Outcome {
        val messages = arrayListOf<ChatMessage>()
        val images = arrayListOf<String>()
        val log = arrayListOf<String>()
        val afterTurn = arrayListOf<() -> Unit>()
        var ignored = false

        for (call in calls) {
            val name = call.function.nameOrNull.orEmpty()
            val definition = definitions.firstOrNull { it.name == name }
            val title = definition?.let { context.getString(it.title) } ?: name

            val result = when {
                // Tool calls only run while the user is looking at SpeakGPT
                !host.isInForeground() -> {
                    ignored = true
                    Result(
                        "Ignored: SpeakGPT is not in the foreground, so the tool was not run. Do not call tools again; answer in text.",
                        context.getString(R.string.tool_status_ignored)
                    )
                }
                definition == null || getMode(context, definition) == ToolPreferences.Mode.DISABLED || (definition.needsScreen && !host.canCaptureScreen) -> {
                    Result("Error: the tool $name is not available.", context.getString(R.string.tool_status_unavailable))
                }
                else -> {
                    try {
                        val args = call.function.argumentsAsJsonOrNull() ?: JsonObject(emptyMap())
                        runTool(context, host, definition, args)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        log(context, "Tool $name failed: ${e.message}")
                        Result("Error: ${e.message}", context.getString(R.string.tool_status_failed))
                    }
                }
            }

            messages.add(ChatMessage.Tool(content = result.text, toolCallId = call.id))
            result.image?.let { images.add(it) }
            result.afterTurn?.let { afterTurn.add(it) }
            log.add(context.getString(R.string.tool_log_line, title, result.summary))
        }

        // Most servers do not accept images in tool results, so images follow as a user message
        if (images.isNotEmpty()) {
            val parts = arrayListOf<com.aallam.openai.api.chat.ContentPart>(TextPart("Screenshot requested with the take_screenshot tool:"))
            images.forEach { parts.add(ImagePart(it)) }
            messages.add(ChatMessage(role = ChatRole.User, content = parts))
        }

        return Outcome(messages, log, ignored, afterTurn)
    }

    private suspend fun runTool(context: Context, host: ToolHost, definition: Definition, args: JsonObject): Result {
        val confirm: suspend (String) -> Boolean = { message ->
            getMode(context, definition) == ToolPreferences.Mode.AUTO || askUser(host, context.getString(definition.title), message)
        }

        return when (definition.name) {
            "take_screenshot" -> takeScreenshot(context, host, confirm)
            "read_qr_code" -> readQrCode(context, host, confirm)
            "list_apps" -> listApps(context, confirm)
            "open_app" -> openApp(context, host, args.string("name"), confirm)
            "start_navigation" -> startNavigation(context, host, args.string("destination"), args.stringOrNull("mode"), confirm)
            "make_call" -> makeCall(context, host, args.string("contact"), confirm)
            "send_text" -> sendText(context, host, args.string("contact"), args.string("message"), confirm)
            "open_webpage" -> openWebpage(context, host, args.string("url"), confirm)
            "search_internet" -> {
                val query = args.string("query")
                openWebpage(context, host, "https://www.google.com/search?q=" + Uri.encode(query), confirm)
            }
            "generate_image" -> {
                val prompt = args.string("prompt")
                if (!confirm(context.getString(R.string.tool_confirm_generate_image, prompt))) return declined(context)
                Result("Image generation started. The image will be shown to the user.", context.getString(R.string.tool_status_started), afterTurn = { host.generateImage(prompt) })
            }
            else -> Result("Error: unknown tool.", context.getString(R.string.tool_status_unavailable))
        }
    }

    private fun declined(context: Context) = Result("The user declined this action.", context.getString(R.string.tool_status_declined))

    private suspend fun askUser(host: ToolHost, title: String, message: String): Boolean {
        val activity = host.hostActivity ?: return false

        return suspendCancellableCoroutine { continuation ->
            val dialog = MaterialAlertDialogBuilder(activity, R.style.App_MaterialAlertDialog)
                .setTitle(title)
                .setMessage(message)
                .setPositiveButton(R.string.tool_allow) { _, _ -> if (continuation.isActive) continuation.resume(true) }
                .setNegativeButton(R.string.tool_deny) { _, _ -> if (continuation.isActive) continuation.resume(false) }
                .setOnDismissListener { if (continuation.isActive) continuation.resume(false) }
                .show()

            continuation.invokeOnCancellation { dialog.dismiss() }
        }
    }

    /** Wait until the host is back in the foreground, e.g. after a permission dialog. */
    private suspend fun awaitForeground(host: ToolHost) {
        repeat(20) {
            if (host.isInForeground()) return
            delay(50)
        }
    }

    private suspend fun requestPermissions(host: ToolHost, vararg permissions: String): Boolean {
        val granted = host.requestPermissions(arrayOf(*permissions))
        awaitForeground(host)
        return granted
    }

    // Screen

    private suspend fun captureScreen(context: Context, host: ToolHost): Pair<Bitmap?, String> {
        if (ScreenCaptureAccessibilityService.isEnabled() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val (bitmap, error) = host.withUiHidden {
                suspendCancellableCoroutine<Pair<Bitmap?, String?>> { continuation ->
                    val started = ScreenCaptureAccessibilityService.captureBitmap { bitmap, error ->
                        if (continuation.isActive) continuation.resume(Pair(bitmap, error))
                    }
                    if (!started && continuation.isActive) continuation.resume(Pair(null, "The screen capture service is not available"))
                }
            }

            if (bitmap != null) return Pair(bitmap, "")
            log(context, "Tool screenshot failed: $error")
        }

        // Screen captured when the assistant was opened (assist API or accessibility service)
        val stored = ScreenContextStore.loadScreenshot(context)
        if (stored != null) return Pair(stored, " This is the screen captured when the assistant was opened.")

        return Pair(null, "The screen could not be captured. Tell the user to enable the \"SpeakGPT screen context\" accessibility service in the system accessibility settings (Android 11 or newer).")
    }

    private suspend fun takeScreenshot(context: Context, host: ToolHost, confirm: suspend (String) -> Boolean): Result {
        if (!confirm(context.getString(R.string.tool_confirm_screenshot))) return declined(context)

        val (bitmap, note) = captureScreen(context, host)
        if (bitmap == null) return Result("Error: $note", context.getString(R.string.tool_status_failed))

        val image = withContext(Dispatchers.Default) { toDataUrl(bitmap) }
        return Result("Screenshot taken; it is attached in the next message.$note", context.getString(R.string.tool_status_done), image = image)
    }

    private fun toDataUrl(bitmap: Bitmap): String {
        val longSide = maxOf(bitmap.width, bitmap.height)
        val scaled = if (longSide > MAX_IMAGE_SIDE) {
            val ratio = MAX_IMAGE_SIDE.toFloat() / longSide
            bitmap.scale((bitmap.width * ratio).toInt(), (bitmap.height * ratio).toInt())
        } else {
            bitmap
        }

        val stream = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.JPEG, 85, stream)
        return "data:image/jpeg;base64," + Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
    }

    private suspend fun readQrCode(context: Context, host: ToolHost, confirm: suspend (String) -> Boolean): Result {
        if (!confirm(context.getString(R.string.tool_confirm_qr_code))) return declined(context)

        val (bitmap, note) = captureScreen(context, host)
        if (bitmap == null) return Result("Error: $note", context.getString(R.string.tool_status_failed))

        val codes = withContext(Dispatchers.Default) { decodeQrCodes(bitmap) }

        return if (codes.isEmpty()) {
            Result("No QR code was found on the screen.$note", context.getString(R.string.tool_status_not_found))
        } else {
            val text = codes.mapIndexed { i, code -> "QR code ${i + 1}: $code" }.joinToString("\n")
            Result(text + note, context.getString(R.string.tool_status_found, codes.size))
        }
    }

    private fun decodeQrCodes(bitmap: Bitmap): List<String> {
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        val source = RGBLuminanceSource(bitmap.width, bitmap.height, pixels)

        val hints = mapOf(
            DecodeHintType.TRY_HARDER to true,
            DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE)
        )

        // The hybrid binarizer works best for most screens, the global one for low contrast codes
        for (binaryBitmap in listOf(BinaryBitmap(HybridBinarizer(source)), BinaryBitmap(GlobalHistogramBinarizer(source)))) {
            try {
                val results = QRCodeMultiReader().decodeMultiple(binaryBitmap, hints)
                val texts = results.mapNotNull { it.text }.distinct()
                if (texts.isNotEmpty()) return texts
            } catch (_: NotFoundException) { /* try the next binarizer */ }
        }

        return emptyList()
    }

    // Apps

    private data class App(val label: String, val packageName: String)

    private fun launchableApps(context: Context): List<App> {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val pm = context.packageManager

        return pm.queryIntentActivities(intent, 0)
            .map { App(it.loadLabel(pm).toString(), it.activityInfo.packageName) }
            .filter { it.packageName != context.packageName }
            .distinctBy { it.packageName }
            .sortedBy { it.label.lowercase() }
    }

    private suspend fun listApps(context: Context, confirm: suspend (String) -> Boolean): Result {
        if (!confirm(context.getString(R.string.tool_confirm_list_apps))) return declined(context)

        val apps = withContext(Dispatchers.IO) { launchableApps(context) }
        val text = apps.joinToString("\n") { "${it.label} (${it.packageName})" }
        return Result("Installed apps:\n$text", context.getString(R.string.tool_status_apps, apps.size))
    }

    private suspend fun openApp(context: Context, host: ToolHost, name: String, confirm: suspend (String) -> Boolean): Result {
        val query = name.trim().lowercase()
        val apps = withContext(Dispatchers.IO) { launchableApps(context) }

        val matches = apps.filter { it.label.lowercase() == query || it.packageName.lowercase() == query }
            .ifEmpty { apps.filter { it.label.lowercase().contains(query) } }

        if (matches.isEmpty()) {
            return Result("No installed app matches \"$name\". Call list_apps to see the installed apps.", context.getString(R.string.tool_status_not_found))
        }

        if (matches.size > 1) {
            val names = matches.joinToString(", ") { "${it.label} (${it.packageName})" }
            return Result("Several apps match \"$name\": $names. Ask the user which one to open, or call open_app with the package name.", context.getString(R.string.tool_status_ambiguous))
        }

        val app = matches[0]
        if (!confirm(context.getString(R.string.tool_confirm_open_app, app.label))) return declined(context)

        val activity = host.hostActivity ?: return Result("Error: SpeakGPT is not open.", context.getString(R.string.tool_status_failed))
        val intent = context.packageManager.getLaunchIntentForPackage(app.packageName)
            ?: return Result("Error: ${app.label} can not be opened.", context.getString(R.string.tool_status_failed))

        activity.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        return Result("Opened ${app.label}.", context.getString(R.string.tool_status_opened, app.label))
    }

    // Google Maps

    private suspend fun startNavigation(context: Context, host: ToolHost, destination: String, mode: String?, confirm: suspend (String) -> Boolean): Result {
        // https://developers.google.com/maps/documentation/urls/android-intents#launch_turn-by-turn_navigation
        val modeCode = when (mode) {
            "walking" -> "w"
            "bicycling" -> "b"
            "two_wheeler" -> "l"
            else -> "d"
        }

        if (!confirm(context.getString(R.string.tool_confirm_navigation, destination))) return declined(context)

        val activity = host.hostActivity ?: return Result("Error: SpeakGPT is not open.", context.getString(R.string.tool_status_failed))
        val intent = Intent(Intent.ACTION_VIEW, "google.navigation:q=${Uri.encode(destination)}&mode=$modeCode".toUri())
            .setPackage(MAPS_PACKAGE)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        return try {
            activity.startActivity(intent)
            Result("Navigation to $destination started in Google Maps.", context.getString(R.string.tool_status_started))
        } catch (_: ActivityNotFoundException) {
            Result("Error: Google Maps is not installed.", context.getString(R.string.tool_status_failed))
        }
    }

    // Phone and SMS

    private sealed class Recipient {
        class Found(val label: String, val number: String) : Recipient()
        class Problem(val text: String) : Recipient()
    }

    private fun looksLikeNumber(value: String): Boolean {
        return value.count { it.isDigit() } >= 3 && value.all { it.isDigit() || it in "+-() .*#" }
    }

    private suspend fun resolveRecipient(context: Context, host: ToolHost, contact: String): Recipient {
        val query = contact.trim()
        if (looksLikeNumber(query)) return Recipient.Found(query, query)

        if (!requestPermissions(host, Manifest.permission.READ_CONTACTS)) {
            return Recipient.Problem("Error: permission to read contacts was denied. Ask the user for the phone number instead.")
        }

        data class Entry(val contactId: Long, val name: String, val number: String, val type: String, val isDefault: Boolean)

        val entries = withContext(Dispatchers.IO) {
            val list = arrayListOf<Entry>()
            val uri = Uri.withAppendedPath(ContactsContract.CommonDataKinds.Phone.CONTENT_FILTER_URI, Uri.encode(query))
            val projection = arrayOf(
                ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
                ContactsContract.CommonDataKinds.Phone.TYPE,
                ContactsContract.CommonDataKinds.Phone.LABEL,
                ContactsContract.CommonDataKinds.Phone.IS_SUPER_PRIMARY
            )

            context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val type = ContactsContract.CommonDataKinds.Phone.getTypeLabel(context.resources, cursor.getInt(3), cursor.getString(4)).toString()
                    list.add(Entry(cursor.getLong(0), cursor.getString(1).orEmpty(), cursor.getString(2).orEmpty(), type, cursor.getInt(5) != 0))
                }
            }

            list
        }

        if (entries.isEmpty()) return Recipient.Problem("No contact matches \"$contact\".")

        // Prefer contacts whose name matches exactly
        val exact = entries.filter { it.name.equals(query, ignoreCase = true) }
        val candidates = exact.ifEmpty { entries }

        val contacts = candidates.groupBy { it.contactId }
        if (contacts.size > 1) {
            val names = contacts.values.joinToString(", ") { it[0].name }
            return Recipient.Problem("Several contacts match \"$contact\": $names. Ask the user which one they mean.")
        }

        val numbers = candidates.distinctBy { it.number.filter { c -> c.isDigit() || c == '+' } }
        val name = numbers[0].name

        if (numbers.size == 1) return Recipient.Found(name, numbers[0].number)

        // The number the user set as default for this contact
        numbers.firstOrNull { it.isDefault }?.let { return Recipient.Found(name, it.number) }

        val list = numbers.joinToString(", ") { "${it.type}: ${it.number}" }
        return Recipient.Problem("$name has several phone numbers ($list). Ask the user which one to use, then call the tool again with the number.")
    }

    private suspend fun makeCall(context: Context, host: ToolHost, contact: String, confirm: suspend (String) -> Boolean): Result {
        val recipient = resolveRecipient(context, host, contact)
        if (recipient is Recipient.Problem) return Result(recipient.text, context.getString(R.string.tool_status_needs_input))
        recipient as Recipient.Found

        val display = if (recipient.label == recipient.number) recipient.number else "${recipient.label} (${recipient.number})"
        if (!confirm(context.getString(R.string.tool_confirm_call, display))) return declined(context)

        if (!requestPermissions(host, Manifest.permission.CALL_PHONE)) {
            return Result("Error: permission to make phone calls was denied.", context.getString(R.string.tool_status_permission_denied))
        }

        val activity = host.hostActivity ?: return Result("Error: SpeakGPT is not open.", context.getString(R.string.tool_status_failed))
        activity.startActivity(Intent(Intent.ACTION_CALL, "tel:${Uri.encode(recipient.number)}".toUri()).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

        return Result("Calling $display.", context.getString(R.string.tool_status_calling, display))
    }

    private suspend fun sendText(context: Context, host: ToolHost, contact: String, message: String, confirm: suspend (String) -> Boolean): Result {
        if (message.isBlank()) return Result("Error: the message is empty.", context.getString(R.string.tool_status_failed))

        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)) {
            return Result("Error: this device can not send SMS messages.", context.getString(R.string.tool_status_failed))
        }

        val recipient = resolveRecipient(context, host, contact)
        if (recipient is Recipient.Problem) return Result(recipient.text, context.getString(R.string.tool_status_needs_input))
        recipient as Recipient.Found

        val display = if (recipient.label == recipient.number) recipient.number else "${recipient.label} (${recipient.number})"
        if (!confirm(context.getString(R.string.tool_confirm_text, display, message))) return declined(context)

        if (!requestPermissions(host, Manifest.permission.SEND_SMS)) {
            return Result("Error: permission to send SMS messages was denied.", context.getString(R.string.tool_status_permission_denied))
        }

        val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }

        val parts = smsManager.divideMessage(message)
        smsManager.sendMultipartTextMessage(recipient.number, null, parts, null, null)

        return Result("Text message submitted for sending to $display.", context.getString(R.string.tool_status_sent, display))
    }

    // Browser

    private suspend fun openWebpage(context: Context, host: ToolHost, url: String, confirm: suspend (String) -> Boolean): Result {
        val trimmed = url.trim()
        val uri = (if (trimmed.contains("://")) trimmed else "https://$trimmed").toUri()

        if (uri.scheme != "http" && uri.scheme != "https") {
            return Result("Error: only http and https pages can be opened.", context.getString(R.string.tool_status_failed))
        }

        if (!confirm(context.getString(R.string.tool_confirm_webpage, uri.toString()))) return declined(context)

        val activity = host.hostActivity ?: return Result("Error: SpeakGPT is not open.", context.getString(R.string.tool_status_failed))
        val intent = Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        // Open the default browser rather than an app that handles the link (e.g. YouTube)
        defaultBrowser(context)?.let { intent.setPackage(it) }

        return try {
            activity.startActivity(intent)
            Result("Opened $uri in the browser.", context.getString(R.string.tool_status_done))
        } catch (_: ActivityNotFoundException) {
            Result("Error: no browser is installed.", context.getString(R.string.tool_status_failed))
        }
    }

    private fun defaultBrowser(context: Context): String? {
        val intent = Intent(Intent.ACTION_VIEW, "https://".toUri()).addCategory(Intent.CATEGORY_BROWSABLE)
        val info = context.packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY) ?: return null
        val packageName = info.activityInfo?.packageName ?: return null

        // "android" is the app chooser, shown when no default browser is set
        return if (packageName == "android") null else packageName
    }

    // Helpers

    private fun JsonObject.stringOrNull(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull?.ifBlank { null }

    private fun JsonObject.string(key: String): String = stringOrNull(key) ?: throw IllegalArgumentException("missing argument \"$key\"")

    private fun log(context: Context, message: String) {
        try {
            Logger.log(context, "event", "Tools", "error", message)
        } catch (_: Exception) { /* logging must never break a tool call */ }
    }
}
