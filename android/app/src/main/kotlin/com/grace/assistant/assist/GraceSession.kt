package com.grace.assistant.assist

import android.app.assist.AssistContent
import android.app.assist.AssistStructure
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.voice.VoiceInteractionSession
import android.text.InputType
import android.util.Log
import android.view.View
import com.grace.assistant.MainActivity

/**
 * Runs when the user invokes the assistant (long press on home, power button, corner swipe).
 *
 * The system only delivers the screen when two things hold: the user allowed "Use text from
 * screen" and "Use screenshot" for the assistant in the system settings, and the invocation
 * asked for it (the show flags). This class never tries to work around either. It waits for
 * exactly the data the flags promise, then opens Grace with whatever arrived. If nothing was
 * promised it opens Grace right away without screen content.
 */
class GraceSession(context: Context) : VoiceInteractionSession(context) {

    companion object {
        private const val TAG = "GraceSession"

        // Longest wait for the data the system promised
        private const val DATA_TIMEOUT_MS = 2500L

        private const val MAX_TEXT_LENGTH = 12000

        fun isPasswordInput(inputType: Int): Boolean {
            val cls = inputType and InputType.TYPE_MASK_CLASS
            val variation = inputType and InputType.TYPE_MASK_VARIATION
            return when (cls) {
                InputType.TYPE_CLASS_TEXT ->
                    variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                        variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                        variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
                InputType.TYPE_CLASS_NUMBER -> variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
                else -> false
            }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable {
        Log.w(TAG, "Timed out waiting for screen data (text: $expectText/$gotText, screenshot: $expectShot/$gotShot)")
        launchGrace()
    }

    // What the current invocation promised
    private var shown = false
    private var expectText = false
    private var expectShot = false

    // What arrived. Data can arrive before onShow, so these are reset in onHide, not onShow.
    private var gotText = false
    private var gotShot = false
    private var textStatesReceived = 0
    private val textParts = ArrayList<String>()
    private var webUri: String? = null

    private var launched = false

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)

        shown = true
        launched = false
        expectText = showFlags and SHOW_WITH_ASSIST != 0
        expectShot = showFlags and SHOW_WITH_SCREENSHOT != 0

        Log.i(TAG, "Shown (flags=$showFlags, text expected=$expectText, screenshot expected=$expectShot)")

        if (!expectText && !expectShot) {
            // The system will not send the screen. Do not wait for it.
            AssistStore.clear(context)
            launchGrace()
            return
        }

        handler.removeCallbacks(timeout)
        handler.postDelayed(timeout, DATA_TIMEOUT_MS)
        maybeLaunch()
    }

    override fun onHide() {
        super.onHide()
        handler.removeCallbacks(timeout)
        shown = false
        expectText = false
        expectShot = false
        gotText = false
        gotShot = false
        textStatesReceived = 0
        textParts.clear()
        webUri = null
    }

    // Android 10 and newer: one call per visible app (split screen delivers several)
    override fun onHandleAssist(state: VoiceInteractionSession.AssistState) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        collectStructure(state.assistStructure, state.assistContent)
        textStatesReceived++
        if (textStatesReceived >= state.count) finishText()
    }

    // Android 9: a single call for the foreground app
    @Deprecated("Replaced by onHandleAssist(AssistState) on Android 10")
    @Suppress("DEPRECATION")
    override fun onHandleAssist(data: Bundle?, structure: AssistStructure?, content: AssistContent?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return
        collectStructure(structure, content)
        finishText()
    }

    override fun onHandleScreenshot(screenshot: Bitmap?) {
        if (screenshot != null) {
            try {
                AssistStore.saveScreenshot(context, screenshot)
            } catch (e: Exception) {
                Log.e(TAG, "Could not save the screenshot", e)
            }
        }
        gotShot = true
        maybeLaunch()
    }

    private fun finishText() {
        val text = textParts.joinToString("\n\n").trim()
        AssistStore.saveText(context, if (text.length > MAX_TEXT_LENGTH) text.take(MAX_TEXT_LENGTH) else text)
        gotText = true
        maybeLaunch()
    }

    private fun collectStructure(structure: AssistStructure?, content: AssistContent?) {
        val contentUri = content?.webUri
        if (contentUri != null && webUri == null) webUri = contentUri.toString()
        if (structure == null) return

        try {
            val packageName = structure.activityComponent?.packageName
            // The assistant's own windows are not what the user wants to ask about
            if (packageName == context.packageName) return

            val lines = LinkedHashSet<String>()
            for (i in 0 until structure.windowNodeCount) {
                collectText(structure.getWindowNodeAt(i).rootViewNode, lines)
            }

            val header = StringBuilder()
            if (packageName != null) header.append("App: ").append(packageName).append('\n')
            webUri?.let { header.append("Page: ").append(it).append('\n') }

            if (lines.isNotEmpty() || header.isNotEmpty()) {
                textParts.add(header.toString() + lines.joinToString("\n"))
            }
        } catch (e: Exception) {
            Log.e(TAG, "Could not read the screen text", e)
        }
    }

    private fun collectText(node: AssistStructure.ViewNode?, lines: MutableSet<String>) {
        if (node == null) return

        // Hidden views, password fields and views the app marked as private are skipped
        if (node.visibility != View.VISIBLE) return
        if (node.isAssistBlocked) return

        if (!isPasswordInput(node.inputType)) {
            val text = node.text?.toString()?.trim().takeUnless { it.isNullOrEmpty() }
                ?: node.contentDescription?.toString()?.trim()

            if (!text.isNullOrEmpty()) lines.add(text)
        }

        for (i in 0 until node.childCount) {
            collectText(node.getChildAt(i), lines)
        }
    }

    private fun maybeLaunch() {
        if (!shown) return
        if ((!expectText || gotText) && (!expectShot || gotShot)) launchGrace()
    }

    private fun launchGrace() {
        if (launched) return
        launched = true
        handler.removeCallbacks(timeout)

        val intent = Intent(context, MainActivity::class.java)
            .setAction(MainActivity.ACTION_ASSIST)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)

        try {
            startAssistantActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "startAssistantActivity failed, falling back to startActivity", e)
            try {
                context.startActivity(intent)
            } catch (e2: Exception) {
                Log.e(TAG, "Could not open Grace", e2)
            }
        }

        hide()
    }
}
