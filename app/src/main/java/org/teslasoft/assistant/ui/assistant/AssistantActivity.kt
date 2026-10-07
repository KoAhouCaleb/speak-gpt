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

package org.teslasoft.assistant.ui.assistant

import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.StrictMode
import androidx.activity.enableEdgeToEdge
import androidx.fragment.app.FragmentActivity
import com.google.android.material.elevation.SurfaceColors
import org.teslasoft.assistant.assist.ScreenCaptureAccessibilityService
import org.teslasoft.assistant.preferences.Preferences
import org.teslasoft.assistant.ui.fragments.AssistantFragment
import org.teslasoft.assistant.util.ScreenContextStore

class AssistantActivity : FragmentActivity() {

    private var restoreFromState = false
    private var assistantShown = false

    // Launches that open the assistant on top of another app (not share / text selection)
    private val assistActions = setOf(
        Intent.ACTION_ASSIST,
        Intent.ACTION_VOICE_COMMAND,
        "android.speech.action.VOICE_SEARCH_HANDS_FREE"
    )

    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            overrideActivityTransition(OVERRIDE_TRANSITION_OPEN, 0, 0, Color.TRANSPARENT)
            overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0, Color.TRANSPARENT)
        } else {
            overridePendingTransition(0, 0)
        }

        enableEdgeToEdge()
        super.onCreate(savedInstanceState)

        val policy = StrictMode.ThreadPolicy.Builder().permitAll().build()
        StrictMode.setThreadPolicy(policy)

        window.navigationBarColor = SurfaceColors.SURFACE_1.getColor(this)

        if (savedInstanceState == null) {
            // This activity is transparent, so a capture taken before the overlay is shown contains
            // the app the user was looking at. Skip if the system already provided the screen.
            val isAssistLaunch = intent?.action?.let { it in assistActions } == true
            val shouldCapture = isAssistLaunch && !ScreenContextStore.hasContext(this)

            val handler = Handler(mainLooper)

            val captureStarted = shouldCapture && ScreenCaptureAccessibilityService.capture(this) {
                handler.postDelayed({ showAssistantOnce() }, 150)
            }

            // Fallback if the capture does not finish (and normal path without capture)
            handler.postDelayed({ showAssistantOnce() }, if (captureStarted) 1500 else 150)
        }
    }

    private fun showAssistantOnce() {
        if (assistantShown || restoreFromState || isFinishing || isDestroyed) return
        assistantShown = true
        showAssistant()
    }

    private fun showAssistant() {
        val assistantFragment = AssistantFragment()
        assistantFragment.isCancelable = !Preferences.getPreferences(this, "").getLockAssistantWindow()
        assistantFragment.show(supportFragmentManager, "AssistantFragment")
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        restoreFromState = true
    }

    override fun onRestoreInstanceState(savedInstanceState: Bundle) {
        super.onRestoreInstanceState(savedInstanceState)

        restoreFromState = false
    }
}
