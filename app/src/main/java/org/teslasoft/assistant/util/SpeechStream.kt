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
import android.media.MediaPlayer
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.teslasoft.assistant.preferences.SpeechServerPreferences
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Speaks a streamed response through the self-hosted TTS server sentence by sentence.
 *
 * Completed sentences go to a FIFO queue and are synthesized one at a time. Synthesized
 * audio goes to a second FIFO queue and is played in order, so the next sentence is
 * synthesized while the current one is playing.
 *
 * Call [update] with the whole response on every streamed token, then [finish] once the
 * response is complete. All functions must be called from the main thread.
 * */
class SpeechStream(
    context: Context,
    private val config: SpeechServerPreferences.Config,
    private val onError: (Exception) -> Unit
) {
    private val cacheDir = context.applicationContext.cacheDir
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val splitter = SpeechText.SentenceSplitter()
    private val sentences = Channel<String>(Channel.UNLIMITED)
    private val audio = Channel<File>(Channel.UNLIMITED)
    private var player: MediaPlayer? = null
    private var inputClosed = false

    init {
        scope.launch { synthesize() }
        scope.launch { play() }
    }

    /**
     * Queue sentences completed so far.
     *
     * @param fullText The whole response received so far.
     * */
    fun update(fullText: String) {
        if (inputClosed) return
        splitter.update(fullText).forEach { sentences.trySend(it) }
    }

    /**
     * Queue the rest of the response. Queued audio keeps playing.
     *
     * @param fullText The complete response.
     * */
    fun finish(fullText: String) {
        if (inputClosed) return
        splitter.finish(fullText).forEach { sentences.trySend(it) }
        close()
    }

    /**
     * Stop accepting text without queueing the unterminated tail. Queued audio keeps playing.
     * */
    fun close() {
        inputClosed = true
        sentences.close()
    }

    /**
     * Stop playback immediately and drop everything queued.
     * */
    fun cancel() {
        close()
        scope.cancel()
        player?.release()
        player = null

        while (true) {
            val file = audio.tryReceive().getOrNull() ?: break
            file.delete()
        }
    }

    private suspend fun synthesize() {
        try {
            for (sentence in sentences) {
                val bytes = runInterruptible(Dispatchers.IO) { SpeechServerClient.speech(config, sentence) }
                val file = withContext(Dispatchers.IO) {
                    File.createTempFile("tts", ".mp3", cacheDir).apply { writeBytes(bytes) }
                }

                if (audio.trySend(file).isFailure) file.delete()
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Stop synthesizing but let already synthesized sentences play out
            close()
            onError(e)
        } finally {
            audio.close()
        }
    }

    private suspend fun play() {
        try {
            for (file in audio) {
                try {
                    playFile(file)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Log.e("SpeechStream", "Playback failed", e)
                } finally {
                    file.delete()
                }
            }
        } finally {
            player?.release()
            player = null
        }
    }

    private suspend fun playFile(file: File) = suspendCancellableCoroutine { continuation ->
        val mediaPlayer = player ?: MediaPlayer().also { player = it }
        mediaPlayer.reset()

        mediaPlayer.setOnPreparedListener { it.start() }
        mediaPlayer.setOnCompletionListener { if (continuation.isActive) continuation.resume(Unit) }
        mediaPlayer.setOnErrorListener { _, what, extra ->
            if (continuation.isActive) continuation.resumeWithException(IOException("MediaPlayer error $what ($extra)"))
            true
        }

        FileInputStream(file).use { mediaPlayer.setDataSource(it.fd) }
        mediaPlayer.prepareAsync()
    }
}
