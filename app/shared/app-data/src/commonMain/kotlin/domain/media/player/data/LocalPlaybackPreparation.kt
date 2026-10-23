package me.him188.ani.app.domain.media.player.data

import org.openani.mediamp.source.MediaData

/** Owns a temporary playback copy without modifying the downloaded source. */
internal class LocalPlaybackPreparation(val data: MediaData, private val cleanup: () -> Unit = {}) : AutoCloseable {
    override fun close() = cleanup()
}

internal expect suspend fun prepareLocalPlayback(data: MediaData): LocalPlaybackPreparation
