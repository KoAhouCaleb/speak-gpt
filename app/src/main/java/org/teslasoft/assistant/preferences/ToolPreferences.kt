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
}
