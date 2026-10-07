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
import org.teslasoft.assistant.ui.assistant.AssistantActivity
import org.teslasoft.assistant.ui.fragments.AssistantFragment
import org.teslasoft.assistant.util.ScreenContextStore

/**
 * Invisible session: collects screenshot and on-screen text, then opens the regular assistant overlay.
 * */
class AssistSession(context: Context) : VoiceInteractionSession(context) {

    companion object {
        // Maximum time to wait for the system to deliver the screenshot / assist data
        private const val ASSIST_DATA_TIMEOUT_MS = 2000L
    }

    private val handler = Handler(Looper.getMainLooper())
    private var waitingForScreenshot = false
    private var waitingForAssistData = false
    private var launched = false
    private val fallback = Runnable { launchAssistant() }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)

        launched = false
        ScreenContextStore.clear(context)

        waitingForScreenshot = showFlags and SHOW_WITH_SCREENSHOT != 0
        waitingForAssistData = showFlags and SHOW_WITH_ASSIST != 0

        if (!waitingForScreenshot && !waitingForAssistData) {
            launchAssistant()
        } else {
            handler.postDelayed(fallback, ASSIST_DATA_TIMEOUT_MS)
        }
    }

    override fun onHide() {
        super.onHide()
        handler.removeCallbacks(fallback)
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun onHandleAssist(state: VoiceInteractionSession.AssistState) {
        // Index 0 is the focused activity. Other indexes are secondary (multi-window) activities.
        if (state.index == 0) {
            saveStructure(state.assistStructure)
            waitingForAssistData = false
            maybeLaunch()
        }
    }

    @Deprecated("Deprecated in Java")
    @Suppress("DEPRECATION")
    override fun onHandleAssist(data: Bundle?, structure: AssistStructure?, content: AssistContent?) {
        // Called only on Android 9 (the AssistState overload above is used on Android 10+)
        saveStructure(structure)
        waitingForAssistData = false
        maybeLaunch()
    }

    override fun onHandleScreenshot(screenshot: Bitmap?) {
        if (screenshot != null) {
            try {
                ScreenContextStore.saveScreenshot(context, screenshot)
            } catch (e: Exception) {
                Log.e("AssistSession", "Failed to save screenshot", e)
            }
        }

        waitingForScreenshot = false
        maybeLaunch()
    }

    private fun saveStructure(structure: AssistStructure?) {
        if (structure == null) return

        try {
            val builder = StringBuilder()
            val seen = HashSet<String>()

            for (i in 0 until structure.windowNodeCount) {
                collectText(structure.getWindowNodeAt(i).rootViewNode, builder, seen)
            }

            ScreenContextStore.saveText(context, builder.toString().trim())
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

    private fun maybeLaunch() {
        if (!waitingForScreenshot && !waitingForAssistData) launchAssistant()
    }

    private fun launchAssistant() {
        if (launched) return
        launched = true
        handler.removeCallbacks(fallback)

        val intent = Intent(context, AssistantActivity::class.java)
            .setAction(Intent.ACTION_ASSIST)
            .putExtra(AssistantFragment.EXTRA_SCREEN_CONTEXT, ScreenContextStore.hasContext(context))
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
