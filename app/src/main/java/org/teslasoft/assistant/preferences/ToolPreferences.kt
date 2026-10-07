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

package org.teslasoft.assistant.preferences

import android.content.Context
import androidx.core.content.edit

/**
 * Global (not per chat) settings of the tools the model can call.
 * */
object ToolPreferences {
    private const val FILE = "tools"

    enum class Mode(val value: String) {
        /** The tool is not offered to the model. */
        DISABLED("disabled"),

        /** The user must allow every call. */
        CONFIRM("confirm"),

        /** Calls run without asking. */
        AUTO("auto");

        companion object {
            fun of(value: String?): Mode? = entries.firstOrNull { it.value == value }
        }
    }

    fun getMode(context: Context, toolName: String, default: Mode): Mode {
        val value = context.getSharedPreferences(FILE, Context.MODE_PRIVATE).getString(toolName, null)
        return Mode.of(value) ?: default
    }

    fun setMode(context: Context, toolName: String, mode: Mode) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit { putString(toolName, mode.value) }
    }

    /** Navigation started by SpeakGPT, used to restart it with an added stop. */
    data class Navigation(val destination: String, val mode: String)

    // A navigation started earlier than this belongs to a previous trip
    private const val NAVIGATION_MAX_AGE_MS = 12 * 60 * 60 * 1000L

    fun setNavigation(context: Context, destination: String, mode: String) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit {
            putString("navigation_destination", destination)
            putString("navigation_mode", mode)
            putLong("navigation_time", System.currentTimeMillis())
        }
    }

    fun getNavigation(context: Context): Navigation? {
        val preferences = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        val destination = preferences.getString("navigation_destination", null) ?: return null
        if (System.currentTimeMillis() - preferences.getLong("navigation_time", 0L) > NAVIGATION_MAX_AGE_MS) return null
        return Navigation(destination, preferences.getString("navigation_mode", null) ?: "driving")
    }
}
