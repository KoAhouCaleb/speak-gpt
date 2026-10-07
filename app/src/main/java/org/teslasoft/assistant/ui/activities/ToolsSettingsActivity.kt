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

package org.teslasoft.assistant.ui.activities

import android.content.res.ColorStateList
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.WindowInsets
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.constraintlayout.widget.ConstraintLayout
import androidx.core.content.res.ResourcesCompat
import androidx.core.graphics.drawable.toDrawable
import androidx.fragment.app.FragmentActivity
import com.google.android.material.button.MaterialButtonToggleGroup
import com.google.android.material.elevation.SurfaceColors
import org.teslasoft.assistant.R
import org.teslasoft.assistant.preferences.Preferences
import org.teslasoft.assistant.preferences.ToolPreferences
import org.teslasoft.assistant.theme.ThemeManager
import org.teslasoft.assistant.tools.AssistantTools

/**
 * Lists the tools the model can call. Each tool can be disabled, require confirmation or run automatically.
 * */
class ToolsSettingsActivity : FragmentActivity() {

    private var btnBack: ImageButton? = null
    private var actionBar: ConstraintLayout? = null
    private var toolsList: LinearLayout? = null

    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setContentView(R.layout.activity_tools_settings)

        btnBack = findViewById(R.id.btn_back)
        actionBar = findViewById(R.id.action_bar)
        toolsList = findViewById(R.id.tools_list)

        val preferences = Preferences.getPreferences(this, "")

        ThemeManager.getThemeManager().applyTheme(this, isDarkThemeEnabled() && preferences.getAmoledPitchBlack())

        if (isDarkThemeEnabled() && preferences.getAmoledPitchBlack()) {
            window.setBackgroundDrawableResource(R.color.amoled_window_background)

            if (Build.VERSION.SDK_INT <= 34) {
                window.navigationBarColor = ResourcesCompat.getColor(resources, R.color.amoled_window_background, theme)
                window.statusBarColor = ResourcesCompat.getColor(resources, R.color.amoled_accent_50, theme)
            }

            actionBar?.setBackgroundColor(ResourcesCompat.getColor(resources, R.color.amoled_accent_50, theme))
            btnBack?.backgroundTintList = ColorStateList.valueOf(ResourcesCompat.getColor(resources, R.color.amoled_accent_50, theme))
        } else {
            window.setBackgroundDrawable(SurfaceColors.SURFACE_0.getColor(this).toDrawable())

            if (Build.VERSION.SDK_INT <= 34) {
                window.navigationBarColor = SurfaceColors.SURFACE_0.getColor(this)
                window.statusBarColor = SurfaceColors.SURFACE_4.getColor(this)
            }

            actionBar?.setBackgroundColor(SurfaceColors.SURFACE_4.getColor(this))
            btnBack?.backgroundTintList = ColorStateList.valueOf(SurfaceColors.SURFACE_4.getColor(this))
        }

        btnBack?.setOnClickListener { finish() }

        addTools()
    }

    private fun addTools() {
        val list = toolsList ?: return

        for (definition in AssistantTools.definitions) {
            val row = layoutInflater.inflate(R.layout.view_tool_setting, list, false)

            row.findViewById<TextView>(R.id.tool_title).setText(definition.title)
            row.findViewById<TextView>(R.id.tool_description).setText(definition.description)

            val toggle = row.findViewById<MaterialButtonToggleGroup>(R.id.tool_mode)

            toggle.check(
                when (AssistantTools.getMode(this, definition)) {
                    ToolPreferences.Mode.DISABLED -> R.id.btn_mode_disabled
                    ToolPreferences.Mode.CONFIRM -> R.id.btn_mode_confirm
                    ToolPreferences.Mode.AUTO -> R.id.btn_mode_auto
                }
            )

            toggle.addOnButtonCheckedListener { _, checkedId, isChecked ->
                if (!isChecked) return@addOnButtonCheckedListener

                val mode = when (checkedId) {
                    R.id.btn_mode_disabled -> ToolPreferences.Mode.DISABLED
                    R.id.btn_mode_confirm -> ToolPreferences.Mode.CONFIRM
                    else -> ToolPreferences.Mode.AUTO
                }

                ToolPreferences.setMode(this, definition.name, mode)
            }

            list.addView(row)
        }
    }

    private fun isDarkThemeEnabled(): Boolean {
        return when (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) {
            Configuration.UI_MODE_NIGHT_YES -> true
            else -> false
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        adjustPaddings()
    }

    private fun adjustPaddings() {
        if (Build.VERSION.SDK_INT < 35) return
        try {
            actionBar?.setPadding(0, window.decorView.rootWindowInsets.getInsets(WindowInsets.Type.statusBars()).top, 0, 0)

            findViewById<ScrollView>(R.id.scroll_view)?.setPadding(
                0,
                pxToDp(8),
                0,
                window.decorView.rootWindowInsets.getInsets(WindowInsets.Type.navigationBars()).bottom
            )
        } catch (_: Exception) { /* unused */ }
    }

    private fun pxToDp(px: Int): Int {
        return (px * resources.displayMetrics.density).toInt()
    }
}
