package me.him188.ani.app.domain.media.player.data

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import me.him188.ani.utils.coroutines.IO_
import me.him188.ani.utils.logging.info
import me.him188.ani.utils.logging.logger
import org.openani.mediamp.PlaybackErrorCode
import org.openani.mediamp.PlaybackException
import org.openani.mediamp.ffmpeg.FFmpegKit
import org.openani.mediamp.source.MediaData
import org.openani.mediamp.source.UriMediaData
import platform.Foundation.NSFileManager
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSURL
import platform.Foundation.NSUUID

/** AVKit receives MP4; video/audio packets and text subtitle tracks retain their timing. */
@OptIn(ExperimentalForeignApi::class)
internal actual suspend fun prepareLocalPlayback(data: MediaData): LocalPlaybackPreparation {
    if (data !is UriMediaData) return LocalPlaybackPreparation(data)
    val input = NSURL.URLWithString(data.uri)
    if (!data.uri.startsWith("file://") || input?.pathExtension?.lowercase() != "mkv") {
        return LocalPlaybackPreparation(data)
    }
    val sourcePath = input.path ?: return LocalPlaybackPreparation(data)
    val output = NSTemporaryDirectory() + "animeko-playback-${NSUUID().UUIDString}.mp4"
    val cleanup = { NSFileManager.defaultManager.removeItemAtPath(output, null); Unit }
    val log = logger<LocalPlaybackPreparation>()
    try {
        // The in-process FFmpeg call cannot be interrupted safely. Retain ownership until
        // it finishes, then honour cancellation and remove any partially written output.
        val result = withContext(NonCancellable + Dispatchers.IO_) {
            FFmpegKit().execute(listOf(
                "-nostdin", "-y", "-v", "error", "-i", sourcePath,
                "-map", "0:v:0", "-map", "0:a?", "-map", "0:s?",
                "-c:v", "copy", "-c:a", "copy", "-c:s", "mov_text",
                "-movflags", "+faststart", output,
            ))
        }
        currentCoroutineContext().ensureActive()
        if (!result.isSuccess) {
            throw PlaybackException(PlaybackErrorCode.UNSUPPORTED_FORMAT, "MKV playback preparation failed: FFmpeg exit ${result.exitCode}")
        }
        log.info { "Prepared local MKV for AVKit: $sourcePath" }
        return LocalPlaybackPreparation(
            UriMediaData(NSURL.fileURLWithPath(output).absoluteString!!, emptyMap(), data.extraFiles, data.options),
            cleanup,
        )
    } catch (error: Throwable) {
        cleanup()
        throw error
    }
}
