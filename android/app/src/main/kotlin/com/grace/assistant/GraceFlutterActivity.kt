package com.grace.assistant

import android.Manifest
import android.app.role.RoleManager
import android.content.ComponentName
import android.content.Intent
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.Settings
import android.util.Base64
import android.webkit.MimeTypeMap
import java.io.File
import java.security.KeyStore
import com.grace.assistant.assist.AssistStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Shared by the main window and the assistant overlay: both run Flutter and answer the same
 * native channel (assist capture, apps, contacts).
 */
open class GraceFlutterActivity : FlutterActivity() {

    companion object {
        const val ACTION_ASSIST = "com.grace.assistant.action.ASSIST"
        const val ACTION_OPEN_CHAT = "com.grace.assistant.action.OPEN_CHAT"
        const val EXTRA_CHAT_ID = "chatId"
        const val ACTION_VOICE_SEARCH_HANDS_FREE = "android.speech.action.VOICE_SEARCH_HANDS_FREE"

        // What started the assistant, as the Dart side names it (Storage.vadForTrigger)
        const val TRIGGER_GESTURE = "gesture"
        const val TRIGGER_HEADSET = "headset"
        private const val CHANNEL = "com.grace.assistant/native"
        private const val CONTACTS_REQUEST = 4201
    }

    private var channel: MethodChannel? = null

    private val calendarPermissions = arrayOf(
        Manifest.permission.READ_CALENDAR,
        Manifest.permission.WRITE_CALENDAR,
    )

    private val permissionCallbacks = mutableMapOf<Int, (Boolean) -> Unit>()
    private var nextPermissionCode = 4300

    /**
     * Runs [action] once every permission is granted, asking for the missing ones first, and
     * answers [result] with its value. A refusal answers "permission_denied".
     */
    private fun withPermissions(
        permissions: Array<String>,
        what: String,
        result: MethodChannel.Result,
        action: () -> Any?,
    ) {
        fun run() {
            try {
                result.success(action())
            } catch (e: Exception) {
                result.error("failed", e.message ?: e.javaClass.simpleName, null)
            }
        }

        val missing = permissions.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) {
            run()
            return
        }

        val code = nextPermissionCode++
        permissionCallbacks[code] = { granted ->
            if (granted) run() else result.error("permission_denied", "$what permission denied", null)
        }
        requestPermissions(missing.toTypedArray(), code)
    }

    // Launches that started the activity before Flutter could receive them
    private var pendingAssist = false
    private var pendingTrigger = TRIGGER_GESTURE
    private var pendingChatId: String? = null
    private var pendingShare: Map<String, String>? = null

    private var pendingContactName: String? = null
    private var pendingContactResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        when {
            intent?.action == ACTION_ASSIST || isSystemAssistAction(intent?.action) -> {
                // Launched by the system without a session: nothing fresh was captured
                if (isSystemAssistAction(intent?.action)) AssistStore.clear(this)
                pendingAssist = true
                pendingTrigger = triggerOf(intent?.action)
            }
            intent?.action == ACTION_OPEN_CHAT -> pendingChatId = intent?.getStringExtra(EXTRA_CHAT_ID)
            else -> pendingShare = intent?.let { extractShare(it) }
        }
    }

    private fun isSystemAssistAction(action: String?): Boolean =
        action == Intent.ACTION_ASSIST || action == Intent.ACTION_VOICE_COMMAND || action == ACTION_VOICE_SEARCH_HANDS_FREE

    /**
     * The headset button long press arrives as a voice command, the assistant gesture as an
     * assist (through GraceSession, which uses our own action, or directly).
     */
    private fun triggerOf(action: String?): String =
        if (action == Intent.ACTION_VOICE_COMMAND || action == ACTION_VOICE_SEARCH_HANDS_FREE) TRIGGER_HEADSET
        else TRIGGER_GESTURE

    private fun captureMap(trigger: String): Map<String, Any> {
        val map = HashMap<String, Any>(AssistStore.read(this)?.toMap() ?: emptyMap<String, Any>())
        map["trigger"] = trigger
        return map
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::onMethodCall)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        when {
            intent.action == ACTION_ASSIST || isSystemAssistAction(intent.action) -> {
                if (isSystemAssistAction(intent.action)) AssistStore.clear(this)
                channel?.invokeMethod("onAssist", captureMap(triggerOf(intent.action)))
            }
            intent.action == ACTION_OPEN_CHAT -> intent.getStringExtra(EXTRA_CHAT_ID)?.let { channel?.invokeMethod("onOpenChat", it) }
            else -> extractShare(intent)?.let { channel?.invokeMethod("onShare", it) }
        }
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "takePendingAssist" -> {
                if (pendingAssist) {
                    pendingAssist = false
                    result.success(captureMap(pendingTrigger))
                } else {
                    result.success(null)
                }
            }
            "takePendingChatId" -> {
                result.success(pendingChatId)
                pendingChatId = null
            }
            "openInMainWindow" -> {
                openInMainWindow(call.argument<String>("chatId"))
                result.success(null)
            }
            "lastAssist" -> result.success(AssistStore.read(this)?.toMap())
            "isDefaultAssistant" -> result.success(isDefaultAssistant())
            "openAssistantSettings" -> {
                openAssistantSettings()
                result.success(null)
            }
            "audioEnqueue" -> {
                AudioQueue.enqueue(call.argument<String>("path") ?: "")
                result.success(null)
            }
            "audioStop" -> {
                AudioQueue.stop()
                result.success(null)
            }
            "takePendingShare" -> {
                result.success(pendingShare)
                pendingShare = null
            }
            "clipboardHasImage" -> result.success(clipboardImageUri() != null)
            "clipboardImage" -> result.success(copyClipboardImage())
            "userCertificates" -> result.success(userCertificates())
            "listApps" -> result.success(listApps())
            "openApp" -> result.success(openApp(call.argument<String>("name") ?: ""))
            "findContact" -> findContact(call.argument<String>("name") ?: "", result)
            "sendSms" -> withPermissions(arrayOf(Manifest.permission.SEND_SMS), "Send SMS", result) {
                DeviceActions.sendSms(this, call.argument<String>("number") ?: "", call.argument<String>("message") ?: "")
                null
            }
            "calendarEvents" -> withPermissions(arrayOf(Manifest.permission.READ_CALENDAR), "Calendar", result) {
                DeviceActions.calendarEvents(
                    this,
                    call.argument<Number>("from")!!.toLong(),
                    call.argument<Number>("to")!!.toLong(),
                )
            }
            "calendarAdd" -> withPermissions(calendarPermissions, "Calendar", result) {
                @Suppress("UNCHECKED_CAST")
                DeviceActions.calendarAdd(this, call.arguments as Map<String, Any?>)
            }
            "calendarUpdate" -> withPermissions(calendarPermissions, "Calendar", result) {
                @Suppress("UNCHECKED_CAST")
                DeviceActions.calendarUpdate(this, call.argument<Number>("id")!!.toLong(), call.arguments as Map<String, Any?>)
            }
            "calendarDelete" -> withPermissions(calendarPermissions, "Calendar", result) {
                DeviceActions.calendarDelete(this, call.argument<Number>("id")!!.toLong())
            }
            "setAlarm" -> result.success(
                DeviceActions.setAlarm(
                    this,
                    call.argument<Int>("hour") ?: 0,
                    call.argument<Int>("minute") ?: 0,
                    call.argument<String>("label"),
                    call.argument<List<Int>>("days") ?: emptyList(),
                ),
            )
            "setTimer" -> result.success(
                DeviceActions.setTimer(this, call.argument<Int>("seconds") ?: 0, call.argument<String>("label")),
            )
            "showAlarms" -> result.success(DeviceActions.showAlarms(this))
            "dismissAlarm" -> result.success(
                DeviceActions.dismissAlarm(
                    this,
                    call.argument<Int>("hour"),
                    call.argument<Int>("minute"),
                    call.argument<String>("label"),
                ),
            )
            else -> result.notImplemented()
        }
    }

    /** Brings the main window to the front, on a chat if one is given. The overlay closes itself. */
    private fun openInMainWindow(chatId: String?) {
        val intent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)

        if (chatId != null) {
            intent.action = ACTION_OPEN_CHAT
            intent.putExtra(EXTRA_CHAT_ID, chatId)
        } else {
            intent.action = Intent.ACTION_MAIN
            intent.addCategory(Intent.CATEGORY_LAUNCHER)
        }

        startActivity(intent)
        if (this !is MainActivity) finish()
    }

    private fun isDefaultAssistant(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val roles = getSystemService(RoleManager::class.java)
                if (roles != null && roles.isRoleAvailable(RoleManager.ROLE_ASSISTANT)) {
                    return roles.isRoleHeld(RoleManager.ROLE_ASSISTANT)
                }
            } catch (_: Exception) {
                // Fall through to the settings value
            }
        }

        return try {
            val value = Settings.Secure.getString(contentResolver, "assistant")
            value != null && ComponentName.unflattenFromString(value)?.packageName == packageName
        } catch (_: Exception) {
            false
        }
    }

    private fun openAssistantSettings() {
        val candidates = listOf(
            Intent(Settings.ACTION_VOICE_INPUT_SETTINGS),
            Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS),
            Intent(Settings.ACTION_SETTINGS),
        )
        for (candidate in candidates) {
            try {
                startActivity(candidate)
                return
            } catch (_: Exception) {
                // Try the next screen
            }
        }
    }

    /**
     * Text and a picture handed over through the share sheet or the "process text" menu.
     * The picture is copied into the cache folder because the sender's permission to read it
     * ends with the intent. Only the first picture of a multi share is used.
     */
    private fun extractShare(intent: Intent): Map<String, String>? {
        val text = when (intent.action) {
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            Intent.ACTION_PROCESS_TEXT -> intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
            else -> return null
        }

        var imagePath = ""
        if (intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE) {
            val uri = sharedStreams(intent).firstOrNull()
            if (uri != null) imagePath = copyImage(uri, intent.type)
        }

        if (text.isNullOrBlank() && imagePath.isEmpty()) return null
        return mapOf("text" to (text ?: ""), "imagePath" to imagePath)
    }

    @Suppress("DEPRECATION")
    private fun sharedStreams(intent: Intent): List<Uri> {
        return if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            val list = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }
            list?.filterNotNull() ?: emptyList()
        } else {
            val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            }
            listOfNotNull(uri)
        }
    }

    /** Copies an image the user shared or pasted into the cache folder. Returns "" if it is not an image. */
    private fun copyImage(uri: Uri, declaredType: String?): String {
        return try {
            val type = contentResolver.getType(uri) ?: declaredType ?: return ""
            if (!type.startsWith("image/")) return ""

            val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(type) ?: "jpg"
            val dir = File(cacheDir, "share").apply { mkdirs() }
            val target = File(dir, "img_${System.currentTimeMillis()}.$extension")

            contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: return ""

            target.absolutePath
        } catch (_: Exception) {
            ""
        }
    }

    /** The first image on the clipboard, or null if the clipboard holds anything else. */
    private fun clipboardImageUri(): Uri? {
        return try {
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = clipboard.primaryClip ?: return null
            val description = clip.description
            if (clip.itemCount == 0 || !description.hasMimeType("image/*")) return null
            clip.getItemAt(0).uri
        } catch (_: Exception) {
            null
        }
    }

    private fun copyClipboardImage(): String? {
        val uri = clipboardImageUri() ?: return null
        return copyImage(uri, null).ifEmpty { null }
    }

    /**
     * Certificate authorities the user installed in the device settings, as PEM text.
     * Android's own network stack trusts them through the network security config, but the
     * Dart HTTP client does not read the system store, so they are handed over explicitly.
     */
    private fun userCertificates(): List<String> {
        return try {
            val store = KeyStore.getInstance("AndroidCAStore")
            store.load(null)
            store.aliases().toList()
                // User installed certificates are stored under "user:<hash>" aliases
                .filter { it.startsWith("user:") }
                .mapNotNull { store.getCertificate(it) }
                .map { cert ->
                    val body = Base64.encodeToString(cert.encoded, Base64.NO_WRAP).chunked(64).joinToString("\n")
                    "-----BEGIN CERTIFICATE-----\n$body\n-----END CERTIFICATE-----\n"
                }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun launcherIntent() = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)

    private fun listApps(): List<Map<String, String>> {
        val pm = packageManager
        return pm.queryIntentActivities(launcherIntent(), 0)
            .map { mapOf("label" to it.loadLabel(pm).toString(), "package" to it.activityInfo.packageName) }
            .filter { it["package"] != packageName }
            .distinctBy { it["package"] }
            .sortedBy { it["label"]?.lowercase() }
    }

    private fun openApp(name: String): String? {
        val query = name.trim().lowercase()
        if (query.isEmpty()) return null

        val apps = listApps()
        val match = apps.firstOrNull { it["package"]?.lowercase() == query }
            ?: apps.firstOrNull { it["label"]?.lowercase() == query }
            ?: apps.firstOrNull { it["label"]?.lowercase()?.contains(query) == true }
            ?: return null

        val launch = packageManager.getLaunchIntentForPackage(match["package"]!!) ?: return null
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(launch)
        return match["label"]
    }

    private fun findContact(name: String, result: MethodChannel.Result) {
        if (name.isBlank()) {
            result.success(null)
            return
        }

        if (checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED) {
            result.success(queryContact(name))
            return
        }

        // One request at a time
        if (pendingContactResult != null) {
            result.error("busy", "A contacts permission request is already open", null)
            return
        }
        pendingContactName = name
        pendingContactResult = result
        requestPermissions(arrayOf(Manifest.permission.READ_CONTACTS), CONTACTS_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        permissionCallbacks.remove(requestCode)?.let { callback ->
            callback(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
            return
        }
        if (requestCode != CONTACTS_REQUEST) return

        val result = pendingContactResult
        val name = pendingContactName
        pendingContactResult = null
        pendingContactName = null

        if (result == null || name == null) return
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            result.success(queryContact(name))
        } else {
            result.error("permission_denied", "Contacts permission denied", null)
        }
    }

    private fun queryContact(name: String): Map<String, String>? {
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            ContactsContract.CommonDataKinds.Phone.NUMBER,
        )

        contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            projection,
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?",
            arrayOf("%$name%"),
            null,
        )?.use { cursor ->
            var best: Map<String, String>? = null
            while (cursor.moveToNext()) {
                val displayName = cursor.getString(0) ?: continue
                val number = cursor.getString(1) ?: continue
                val candidate = mapOf("name" to displayName, "number" to number)
                if (displayName.equals(name, ignoreCase = true)) return candidate
                if (best == null) best = candidate
            }
            return best
        }
        return null
    }
}
