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
import android.util.Log
import androidx.annotation.RequiresApi
import org.teslasoft.assistant.preferences.Logger
import org.teslasoft.assistant.ui.assistant.AssistantActivity
import org.teslasoft.assistant.ui.fragments.AssistantFragment
import org.teslasoft.assistant.util.ScreenContextStore

/**
 * Invisible session: collects screenshot and on-screen text, then opens the regular assistant overlay.
 * */
class AssistSession(context: Context) : VoiceInteractionSession(context) {

    companion object {
        // Maximum time to wait for the system to deliver the screenshot / assist data
        private const val ASSIST_DATA_TIMEOUT_MS = 3000L
    }

    private val handler = Handler(Looper.getMainLooper())
    private var waitingForScreenshot = false
    private var waitingForAssistData = false
    private var launched = false
    private var shown = false

    // Set after asking the system again for screen data (see onShow)
    private var contextRequested = false

    // True between re-requesting screen data and the re-shown session's onShow(). Empty results
    // arriving in this window belong to the original launch and must not end the wait.
    private var awaitingReshow = false

    // Assist data can be delivered before onShow(), so remember what already arrived
    private var screenshotReceived = false
    private var assistDataReceived = false
    private val fallback = Runnable {
        log("Timed out waiting for screen data (waiting for re-show: $awaitingReshow, screenshot: $waitingForScreenshot, text: $waitingForAssistData)")
        launchAssistant()
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)

        launched = false
        shown = true

        val contextFlags = SHOW_WITH_ASSIST or SHOW_WITH_SCREENSHOT

        // Some launch paths (e.g. the assist gesture on recent Pixel builds) show the session
        // without SHOW_WITH_ASSIST / SHOW_WITH_SCREENSHOT, so the system does not fetch the screen.
        // Re-show the session with these flags; the system then requests the screenshot and
        // screen text, still honouring the user's "Use screen and app data" setting.
        if (showFlags and contextFlags == 0 && !contextRequested) {
            contextRequested = true
            awaitingReshow = true
            log("Session shown without screen request (flags: $showFlags), requesting screen data")

            handler.removeCallbacks(fallback)
            handler.postDelayed(fallback, ASSIST_DATA_TIMEOUT_MS)

            try {
                show(args ?: Bundle(), showFlags or contextFlags)
                return
            } catch (e: Exception) {
                awaitingReshow = false
                log("Failed to request screen data: ${e.message}")
            }
        }

        // The re-shown session came back without the screen flags: the system does not provide the
        // screen to this assistant (observed on recent Pixel builds). Open the overlay right away.
        if (awaitingReshow && showFlags and contextFlags == 0) {
            log("Session shown again without screen request (flags: $showFlags), the system did not grant screen data")
            awaitingReshow = false
            launchAssistant()
            return
        }

        awaitingReshow = false

        val screenshotRequested = showFlags and SHOW_WITH_SCREENSHOT != 0
        val assistDataRequested = showFlags and SHOW_WITH_ASSIST != 0

        waitingForScreenshot = screenshotRequested && !screenshotReceived
        waitingForAssistData = assistDataRequested && !assistDataReceived

        log("Session shown (flags: $showFlags, screenshot requested: $screenshotRequested, screen text requested: $assistDataRequested, already received: screenshot=$screenshotReceived text=$assistDataReceived)")

        if (!waitingForScreenshot && !waitingForAssistData) {
            launchAssistant()
        } else {
            handler.removeCallbacks(fallback)
            handler.postDelayed(fallback, ASSIST_DATA_TIMEOUT_MS)
        }
    }

    override fun onHide() {
        super.onHide()
        handler.removeCallbacks(fallback)
        shown = false
        contextRequested = false
        awaitingReshow = false
        screenshotReceived = false
        assistDataReceived = false
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun onHandleAssist(state: VoiceInteractionSession.AssistState) {
        // Index 0 is the focused activity. Other indexes are secondary (multi-window) activities.
        if (state.index == 0) handleAssistStructure(state.assistStructure)
    }

    @Deprecated("Deprecated in Java")
    @Suppress("DEPRECATION")
    override fun onHandleAssist(data: Bundle?, structure: AssistStructure?, content: AssistContent?) {
        // Called only on Android 9 (the AssistState overload above is used on Android 10+)
        handleAssistStructure(structure)
    }

    private fun handleAssistStructure(structure: AssistStructure?) {
        if (awaitingReshow && structure == null) {
            log("Ignoring empty screen text from the original launch, waiting for requested data")
            return
        }

        saveStructure(structure)
        if (shown) assistDataReceived = true
        waitingForAssistData = false
        maybeLaunch()
    }

    override fun onHandleScreenshot(screenshot: Bitmap?) {
        if (awaitingReshow && screenshot == null) {
            log("Ignoring empty screenshot from the original launch, waiting for requested data")
            return
        }

        log(if (screenshot == null) "No screenshot provided by the system" else "Screenshot received (${screenshot.width}x${screenshot.height})")

        if (screenshot != null) {
            try {
                ScreenContextStore.saveScreenshot(context, screenshot)
            } catch (e: Exception) {
                Log.e("AssistSession", "Failed to save screenshot", e)
            }
        }

        // Late callbacks after hide() must not count for the next invocation
        if (shown) screenshotReceived = true
        waitingForScreenshot = false
        maybeLaunch()
    }

    private fun saveStructure(structure: AssistStructure?) {
        if (structure == null) {
            log("No screen text provided by the system")
            return
        }

        try {
            val builder = StringBuilder()
            val seen = HashSet<String>()

            for (i in 0 until structure.windowNodeCount) {
                collectText(structure.getWindowNodeAt(i).rootViewNode, builder, seen)
            }

            ScreenContextStore.saveText(context, builder.toString().trim())
            log("Screen text received (${builder.length} characters)")
        } catch (e: Exception) {
            Log.e("AssistSession", "Failed to read screen text", e)
        }
    }

    private fun collectText(node: AssistStructure.ViewNode?, builder: StringBuilder, seen: HashSet<String>) {
        if (node == null) return

        val text = (node.text ?: node.contentDescription)?.toString()?.trim()

        if (!text.isNullOrEmpty() && seen.add(text)) {
            builder.append(text).append('\n')
        }

        for (i in 0 until node.childCount) {
            collectText(node.getChildAt(i), builder, seen)
        }
    }

    private fun log(message: String) {
        try {
            Logger.log(context, "event", "AssistSession", "info", message)
        } catch (_: Exception) { /* logging must never break the assistant */ }
    }

    private fun maybeLaunch() {
        if (shown && !awaitingReshow && !waitingForScreenshot && !waitingForAssistData) launchAssistant()
    }

    private fun launchAssistant() {
        if (launched) return
        launched = true
        handler.removeCallbacks(fallback)

        log("Opening assistant (screen context available: ${ScreenContextStore.hasContext(context)})")

        val intent = Intent(context, AssistantActivity::class.java)
            .setAction(Intent.ACTION_ASSIST)
            .putExtra(AssistantFragment.EXTRA_FROM_ASSIST_SESSION, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startAssistantActivity(intent)
            } else {
                context.startActivity(intent)
            }
        } catch (e: Exception) {
            Log.e("AssistSession", "Failed to start assistant activity", e)
            try {
                context.startActivity(intent)
            } catch (_: Exception) { /* ignored */ }
        }

        hide()
    }
}
