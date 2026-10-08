package com.grace.assistant

import android.media.AudioAttributes
import android.media.MediaPlayer
import android.util.Log
import java.io.File

/**
 * Plays audio files one after another without a gap, for speech that is synthesized
 * sentence by sentence.
 *
 * Every file gets its own MediaPlayer and is prepared as soon as it arrives, while the one
 * before it is still playing. The player that is currently playing is told which player comes
 * next with [MediaPlayer.setNextMediaPlayer]. The media framework then starts the next player
 * the moment the current one reaches its end, without a round trip through this code, so
 * there is no silence for a callback and a reset of one shared player.
 *
 * When the synthesis is slower than the playback the queue runs dry and the next file starts
 * normally as soon as it is prepared.
 *
 * It is a process wide singleton, so the main window and the compact assistant share one
 * speaker. Everything runs on the main thread: the channel calls and the MediaPlayer
 * callbacks (the players are created there) arrive on it.
 */
object AudioQueue {
    private const val TAG = "AudioQueue"

    private class Item(val player: MediaPlayer, val file: File)

    // Playing now
    private var current: Item? = null

    // Chained behind [current] with setNextMediaPlayer, prepared and waiting
    private var next: Item? = null

    // Prepared and not chained yet
    private val ready = ArrayDeque<Item>()

    // Bumped by stop() so players that finish preparing afterwards are thrown away
    private var generation = 0

    fun enqueue(path: String) {
        val file = File(path)
        val generationAtStart = generation
        val player = MediaPlayer()
        val item = Item(player, file)

        try {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            player.setDataSource(path)
            player.setOnCompletionListener { onCompleted(item) }
            player.setOnErrorListener { _, what, extra ->
                Log.e(TAG, "MediaPlayer error $what ($extra)")
                onFailed(item)
                true
            }
            player.setOnPreparedListener {
                if (generationAtStart != generation) {
                    discard(item)
                } else {
                    ready.addLast(item)
                    advance()
                }
            }
            player.prepareAsync()
        } catch (e: Exception) {
            Log.e(TAG, "Could not prepare $path", e)
            discard(item)
        }
    }

    /** Stops playback at once and drops everything that is queued. */
    fun stop() {
        generation++
        val items = listOfNotNull(current, next) + ready
        current = null
        next = null
        ready.clear()
        items.forEach { discard(it) }
    }

    /** Starts playing if nothing is playing, and chains the next prepared item behind the current one. */
    private fun advance() {
        if (current == null) {
            val first = ready.removeFirstOrNull() ?: return
            current = first
            first.player.start()
        }

        if (next == null) {
            val candidate = ready.removeFirstOrNull() ?: return
            try {
                current?.player?.setNextMediaPlayer(candidate.player)
                next = candidate
            } catch (e: Exception) {
                // The current player is already at its end. It plays this one when it completes.
                Log.w(TAG, "Could not chain the next player", e)
                ready.addFirst(candidate)
            }
        }
    }

    private fun onCompleted(item: Item) {
        if (item !== current) {
            discard(item)
            return
        }

        // The framework has already started the chained player, if there was one
        current = next
        next = null
        discard(item)
        advance()
    }

    private fun onFailed(item: Item) {
        when {
            item === current -> {
                // A failed player does not hand over to the chained one, so start it by hand
                val chained = next
                current = null
                next = null
                discard(item)
                if (chained != null) ready.addFirst(chained)
                advance()
            }
            item === next -> {
                try {
                    current?.player?.setNextMediaPlayer(null)
                } catch (_: Exception) {
                    // Already transitioning
                }
                next = null
                discard(item)
                advance()
            }
            else -> {
                ready.remove(item)
                discard(item)
            }
        }
    }

    private fun discard(item: Item) {
        try {
            item.player.release()
        } catch (_: Exception) {
            // Already released
        }
        item.file.delete()
    }
}
