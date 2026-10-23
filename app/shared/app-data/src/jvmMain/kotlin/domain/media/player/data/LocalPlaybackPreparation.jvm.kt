package me.him188.ani.app.domain.media.player.data

import org.openani.mediamp.source.MediaData

internal actual suspend fun prepareLocalPlayback(data: MediaData): LocalPlaybackPreparation = LocalPlaybackPreparation(data)
