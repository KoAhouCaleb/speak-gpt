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

import androidx.fragment.app.FragmentActivity

/**
 * Screen that runs tool calls (the assistant overlay or a chat).
 * */
interface ToolHost {
    /** Activity used for dialogs, permission requests and launching other apps. */
    val hostActivity: FragmentActivity?

    /**
     * True if a screenshot shows something other than SpeakGPT itself, i.e. the host is
     * an overlay on top of another app. Screen tools are only offered when this is true.
     * */
    val canCaptureScreen: Boolean

    /** Tool calls are ignored unless this returns true. */
    fun isInForeground(): Boolean

    /** Hide SpeakGPT while [block] runs so a screenshot shows the app underneath. */
    suspend fun <T> withUiHidden(block: suspend () -> T): T

    /** Request runtime permissions. @return true if all of them are granted. */
    suspend fun requestPermissions(permissions: Array<String>): Boolean

    /** Start image generation. Called after the model's turn has ended. */
    fun generateImage(prompt: String)
}
