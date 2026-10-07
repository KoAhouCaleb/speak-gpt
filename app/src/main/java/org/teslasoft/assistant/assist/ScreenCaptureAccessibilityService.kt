/**************************************************************************
 * Copyright (c) 2026 Caleb Hall. All rights reserved.
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

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Build
import android.util.Log
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import org.teslasoft.assistant.util.ScreenContextStore

/**
 * Captures the current screen (screenshot and on-screen text) when the assistant opens.
 *
 * Used on devices where the system does not provide the screen to third-party assistants
 * through the assist API. The service ignores all accessibility events and only acts when
 * [capture] is called by the assistant.
 * */
class ScreenCaptureAccessibilityService : AccessibilityService() {

    companion object {
        private const val MAX_DEPTH = 60

        @Volatile
        private var instance: ScreenCaptureAccessibilityService? = null

        /** @return true if the user enabled the service and it is connected. */
        fun isEnabled(): Boolean = instance != null

        /**
         * Capture the screen into [ScreenContextStore].
         *
         * @param onDone Called on the main thread when the capture finished (successfully or not).
         * @return false if the service is not enabled (onDone is not called).
         * */
        fun capture(context: Context, onDone: () -> Unit): Boolean {
            val service = instance ?: return false
            service.captureScreen(context.applicationContext, onDone)
            return true
        }

        /**
         * Take a screenshot of the whole display for tool calls.
         *
         * @param onResult Called on the main thread with the screenshot, or null and the reason it failed.
         * @return false if the service is not enabled or the device runs Android 10 or lower (onResult is not called).
         * */
        fun captureBitmap(onResult: (Bitmap?, String?) -> Unit): Boolean {
            val service = instance ?: return false
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
            service.takeBitmap(onResult, retried = false)
            return true
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) { /* unused */ }

    override fun onInterrupt() { /* unused */ }

    private fun captureScreen(context: Context, onDone: () -> Unit) {
        ScreenContextStore.clear(context)

        try {
            val text = collectScreenText()
            ScreenContextStore.saveText(context, text)
            log(context, "Screen text captured (${text.length} characters)")
        } catch (e: Exception) {
            log(context, "Failed to read screen text: ${e.message}")
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            // Screenshots from accessibility services require Android 11
            onDone()
            return
        }

        try {
            takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, object : TakeScreenshotCallback {
                override fun onSuccess(screenshot: ScreenshotResult) {
                    try {
                        val hardwareBitmap = Bitmap.wrapHardwareBuffer(screenshot.hardwareBuffer, screenshot.colorSpace)
                        val bitmap = hardwareBitmap?.copy(Bitmap.Config.ARGB_8888, false)
                        screenshot.hardwareBuffer.close()

                        if (bitmap != null) {
                            ScreenContextStore.saveScreenshot(context, bitmap)
                            log(context, "Screenshot captured (${bitmap.width}x${bitmap.height})")
                        }
                    } catch (e: Exception) {
                        log(context, "Failed to save screenshot: ${e.message}")
                    }

                    onDone()
                }

                override fun onFailure(errorCode: Int) {
                    // e.g. secure windows (banking apps) or captures less than a second apart
                    log(context, "Screenshot failed (error code: $errorCode)")
                    onDone()
                }
            })
        } catch (e: Exception) {
            log(context, "Screenshot failed: ${e.message}")
            onDone()
        }
    }

    @androidx.annotation.RequiresApi(Build.VERSION_CODES.R)
    private fun takeBitmap(onResult: (Bitmap?, String?) -> Unit, retried: Boolean) {
        try {
            takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, object : TakeScreenshotCallback {
                override fun onSuccess(screenshot: ScreenshotResult) {
                    try {
                        val hardwareBitmap = Bitmap.wrapHardwareBuffer(screenshot.hardwareBuffer, screenshot.colorSpace)
                        val bitmap = hardwareBitmap?.copy(Bitmap.Config.ARGB_8888, false)
                        screenshot.hardwareBuffer.close()
                        onResult(bitmap, if (bitmap == null) "The screenshot could not be decoded" else null)
                    } catch (e: Exception) {
                        onResult(null, e.message)
                    }
                }

                override fun onFailure(errorCode: Int) {
                    // The system allows one screenshot per second; the assistant may have just captured the screen
                    if (errorCode == ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT && !retried) {
                        android.os.Handler(mainLooper).postDelayed({ takeBitmap(onResult, retried = true) }, 1100)
                    } else {
                        onResult(null, "Screenshot failed (error code: $errorCode)")
                    }
                }
            })
        } catch (e: Exception) {
            onResult(null, e.message)
        }
    }

    private fun collectScreenText(): String {
        val builder = StringBuilder()
        val seen = HashSet<String>()

        val roots = windows
            .filter { it.type == AccessibilityWindowInfo.TYPE_APPLICATION }
            .mapNotNull { it.root }
            .ifEmpty { listOfNotNull(rootInActiveWindow) }

        for (root in roots) {
            // Skip SpeakGPT's own (transparent) assistant window
            if (root.packageName?.toString() == packageName) continue
            collectText(root, builder, seen, 0)
        }

        return builder.toString().trim()
    }

    private fun collectText(node: AccessibilityNodeInfo?, builder: StringBuilder, seen: HashSet<String>, depth: Int) {
        if (node == null || depth > MAX_DEPTH) return

        val text = (node.text ?: node.contentDescription)?.toString()?.trim()

        if (!text.isNullOrEmpty() && seen.add(text)) {
            builder.append(text).append('\n')
        }

        for (i in 0 until node.childCount) {
            collectText(node.getChild(i), builder, seen, depth + 1)
        }
    }

    private fun log(context: Context, message: String) {
        Log.i("ScreenCapture", message)
    }
}
