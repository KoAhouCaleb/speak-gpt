package com.grace.assistant.assist

import android.content.Context
import android.graphics.Bitmap
import java.io.File
import java.io.FileOutputStream

/**
 * Short-lived storage for what the system hands to the assistant session: the text of
 * the screen and a screenshot. Everything lives in the app cache directory.
 */
object AssistStore {
    private const val DIR = "assist"
    private const val TEXT_FILE = "screen.txt"
    private const val IMAGE_FILE = "screen.jpg"
    private const val MAX_IMAGE_SIDE = 1600
    private const val MAX_TEXT_LENGTH = 12000

    // A capture older than this belongs to an earlier invocation
    private const val MAX_AGE_MS = 5 * 60 * 1000L

    data class Capture(val text: String, val screenshotPath: String, val timestamp: Long) {
        fun toMap(): Map<String, Any> = mapOf(
            "text" to text,
            "screenshotPath" to screenshotPath,
            "timestamp" to timestamp,
        )
    }

    private fun dir(context: Context): File = File(context.cacheDir, DIR).apply { mkdirs() }

    fun clear(context: Context) {
        File(dir(context), TEXT_FILE).delete()
        File(dir(context), IMAGE_FILE).delete()
    }

    fun saveText(context: Context, text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        File(dir(context), TEXT_FILE).writeText(trimmed.take(MAX_TEXT_LENGTH))
    }

    fun saveScreenshot(context: Context, bitmap: Bitmap) {
        val longSide = maxOf(bitmap.width, bitmap.height)
        val scaled = if (longSide > MAX_IMAGE_SIDE) {
            val ratio = MAX_IMAGE_SIDE.toFloat() / longSide
            Bitmap.createScaledBitmap(bitmap, (bitmap.width * ratio).toInt(), (bitmap.height * ratio).toInt(), true)
        } else {
            bitmap
        }

        FileOutputStream(File(dir(context), IMAGE_FILE)).use { scaled.compress(Bitmap.CompressFormat.JPEG, 85, it) }
    }

    /** The newest capture, or null if there is none or it is too old. */
    fun read(context: Context): Capture? {
        val textFile = File(dir(context), TEXT_FILE)
        val imageFile = File(dir(context), IMAGE_FILE)
        val now = System.currentTimeMillis()

        val textFresh = textFile.exists() && now - textFile.lastModified() < MAX_AGE_MS
        val imageFresh = imageFile.exists() && now - imageFile.lastModified() < MAX_AGE_MS
        if (!textFresh && !imageFresh) return null

        val timestamp = maxOf(
            if (textFresh) textFile.lastModified() else 0L,
            if (imageFresh) imageFile.lastModified() else 0L,
        )
        return Capture(
            text = if (textFresh) textFile.readText() else "",
            screenshotPath = if (imageFresh) imageFile.absolutePath else "",
            timestamp = timestamp,
        )
    }
}
