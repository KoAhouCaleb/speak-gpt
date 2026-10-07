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

package org.teslasoft.assistant.util

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.core.graphics.scale
import java.io.File
import java.io.FileOutputStream

/**
 * Temporary storage for the screen captured when the assistant is invoked.
 * Files live in the app cache directory and are removed when the assistant is closed.
 * */
object ScreenContextStore {
    private const val IMAGE_FILE = "screen_context.jpg"
    private const val TEXT_FILE = "screen_context.txt"
    private const val MAX_IMAGE_SIDE = 1600
    private const val MAX_TEXT_LENGTH = 8000

    // Captures older than this belong to a previous assistant invocation
    private const val MAX_AGE_MS = 2 * 60 * 1000L

    private fun imageFile(context: Context) = File(context.cacheDir, IMAGE_FILE)
    private fun textFile(context: Context) = File(context.cacheDir, TEXT_FILE)

    private fun File.isFresh(): Boolean = exists() && System.currentTimeMillis() - lastModified() < MAX_AGE_MS

    fun saveScreenshot(context: Context, bitmap: Bitmap) {
        val longSide = maxOf(bitmap.width, bitmap.height)

        val scaled = if (longSide > MAX_IMAGE_SIDE) {
            val ratio = MAX_IMAGE_SIDE.toFloat() / longSide
            bitmap.scale((bitmap.width * ratio).toInt(), (bitmap.height * ratio).toInt())
        } else {
            bitmap
        }

        FileOutputStream(imageFile(context)).use { scaled.compress(Bitmap.CompressFormat.JPEG, 85, it) }
    }

    fun saveText(context: Context, text: String) {
        if (text.isBlank()) return
        textFile(context).writeText(text.take(MAX_TEXT_LENGTH))
    }

    fun loadScreenshot(context: Context): Bitmap? {
        val file = imageFile(context)
        return if (file.isFresh()) BitmapFactory.decodeFile(file.absolutePath) else null
    }

    fun loadText(context: Context): String? {
        val file = textFile(context)
        return if (file.isFresh()) file.readText().ifBlank { null } else null
    }

    fun hasContext(context: Context): Boolean = imageFile(context).isFresh() || textFile(context).isFresh()

    fun clear(context: Context) {
        imageFile(context).delete()
        textFile(context).delete()
    }
}
