package me.him188.ani.app.videoplayer.player

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import me.him188.ani.app.platform.IosVlcPlayer
import me.him188.ani.app.platform.SwiftBridge
import org.openani.mediamp.AbstractMediampPlayer
import org.openani.mediamp.InternalForInheritanceMediampApi
import org.openani.mediamp.InternalMediampApi
import org.openani.mediamp.MediampPlayerFactory
import org.openani.mediamp.OpenResult
import org.openani.mediamp.PlaybackErrorCode
import org.openani.mediamp.PlaybackException
import org.openani.mediamp.PlaybackSessionHandle
import org.openani.mediamp.TransportSnapshot
import org.openani.mediamp.features.AspectRatioMode
import org.openani.mediamp.features.AudioLevelController
import org.openani.mediamp.features.Buffering
import org.openani.mediamp.features.MediaMetadata
import org.openani.mediamp.features.PlaybackSpeed
import org.openani.mediamp.features.VideoAspectRatio
import org.openani.mediamp.features.buildPlayerFeatures
import org.openani.mediamp.metadata.AudioTrack
import org.openani.mediamp.metadata.MediaProperties
import org.openani.mediamp.metadata.SubtitleTrack
import org.openani.mediamp.metadata.TrackGroup
import org.openani.mediamp.metadata.TrackLabel
import org.openani.mediamp.source.MediaData
import org.openani.mediamp.source.UriMediaData
import kotlin.coroutines.CoroutineContext
import kotlin.math.abs
import kotlin.time.TimeSource

class IosVlcMediampPlayerFactory : MediampPlayerFactory<IosVlcMediampPlayer> {
    override val forClass = IosVlcMediampPlayer::class
    override fun create(context: Any, parentCoroutineContext: CoroutineContext) =
        IosVlcMediampPlayer(parentCoroutineContext, SwiftBridge.createVlcPlayer())
}

/** Main-thread adapter; each poll belongs to a single MediaMP session. */
@OptIn(InternalMediampApi::class, InternalForInheritanceMediampApi::class)
class IosVlcMediampPlayer(
    parentCoroutineContext: CoroutineContext,
    override val impl: IosVlcPlayer,
) : AbstractMediampPlayer(parentCoroutineContext, Dispatchers.Main) {
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob(parentCoroutineContext[Job]))
    private var session: PlaybackSessionHandle? = null
    private var polling: Job? = null
    private var seeking: Job? = null
    private var playIntent = false
    private var commandPending: Boolean? = null

    private val audio = VlcTrackGroup<AudioTrack> { impl.selectAudio(it?.internalId?.toInt() ?: -1) }
    private val subtitles = VlcTrackGroup<SubtitleTrack> { impl.selectSubtitle(it?.internalId?.toInt() ?: -1) }
    private val volumeFeature = object : AudioLevelController {
        override val volume = MutableStateFlow(1f)
        override val maxVolume = 2f
        override val isMute = MutableStateFlow(false)
        override fun setMute(mute: Boolean) { isMute.value = mute; apply() }
        override fun setVolume(volume: Float) { this.volume.value = volume.coerceIn(0f, maxVolume); apply() }
        override fun volumeUp(value: Float) = setVolume(volume.value + value)
        override fun volumeDown(value: Float) = setVolume(volume.value - value)
        fun apply() = impl.setVolume(volume.value, isMute.value)
    }
    private val aspectFeature = object : VideoAspectRatio {
        override val mode = MutableStateFlow(AspectRatioMode.FIT)
        override fun setMode(mode: AspectRatioMode) {
            this.mode.value = mode
            impl.setAspect(mode.ordinal)
        }
    }
    override val features = buildPlayerFeatures {
        add(PlaybackSpeed, machinePlaybackSpeed())
        add(AudioLevelController, volumeFeature)
        add(VideoAspectRatio, aspectFeature)
        add(MediaMetadata, object : MediaMetadata {
            override val audioTracks = audio
            override val subtitleTracks = subtitles
            override val chapters = null
        })
        add(Buffering, object : Buffering {
            @Suppress("OVERRIDE_DEPRECATION")
            override val isBuffering = state.map { it.isBuffering }
            override val bufferedPercentage = MutableStateFlow(0)
            override val bufferedPositionMillis = MutableStateFlow(Buffering.UNKNOWN_POSITION)
        })
    }

    override suspend fun openImpl(
        data: MediaData,
        session: PlaybackSessionHandle,
        playWhenReady: Boolean,
        startPositionMillis: Long,
    ): OpenResult {
        val uri = data as? UriMediaData ?: throw PlaybackException(
            PlaybackErrorCode.UNSUPPORTED_FORMAT, "VLC requires a file or HTTP URI",
        )
        stopImpl()
        this.session = session
        playIntent = playWhenReady
        try {
            impl.open(uri.uri, uri.headers, startPositionMillis)
            withTimeout(90_000) {
                while (impl.phase !in listOf(3, 4, 5)) {
                    if (impl.phase == 6) throw playbackError()
                    delay(50)
                }
            }
            data.extraFiles.subtitles.forEach { impl.addSubtitle(it.uri) }
            volumeFeature.apply()
            impl.setAspect(aspectFeature.mode.value.ordinal)
            if (!playWhenReady) impl.pause()
            commandPending = playWhenReady
            refreshTracks()
            polling = scope.launch {
                var endedReported = false
                while (isActive && session.isValid) {
                    delay(100)
                    when (impl.phase) {
                        5 -> if (!endedReported) {
                            endedReported = true
                            session.notifyEnded()
                        }
                        6 -> { session.notifyError(playbackError()); break }
                        else -> {
                            endedReported = false
                            session.reportTransport(snapshot())
                            session.notifyPosition(impl.positionMillis)
                            session.notifyProperties(properties())
                            refreshTracks()
                        }
                    }
                }
            }
            return OpenResult(
                initialSnapshot = snapshot(),
                atEnd = impl.phase == 5,
                initialProperties = properties(),
            )
        } catch (error: Throwable) {
            if (this.session === session) stopImpl()
            if (error is TimeoutCancellationException) {
                throw PlaybackException(PlaybackErrorCode.IO, "VLC timed out opening media", error)
            }
            throw error
        }
    }

    private fun playbackError() = PlaybackException(PlaybackErrorCode.DECODING, "VLC failed to open or decode media")
    private fun properties() = MediaProperties(
        durationMillis = impl.durationMillis.takeIf { it > 0 },
        videoWidth = impl.videoWidth.takeIf { it > 0 },
        videoHeight = impl.videoHeight.takeIf { it > 0 },
    )

    private fun snapshot(): TransportSnapshot {
        val native = when (impl.phase) { 3 -> true; 4 -> false; else -> null }
        if (native == commandPending) commandPending = null
        if (commandPending == null && native != null) playIntent = native
        return TransportSnapshot(playIntent, impl.phase == 1 || impl.phase == 2)
    }
    override fun playImpl() {
        playIntent = true
        commandPending = true
        impl.play()
        session?.reportTransport(snapshot())
    }
    override fun pauseImpl() {
        playIntent = false
        commandPending = false
        impl.pause()
        session?.reportTransport(snapshot())
    }
    override fun setRateImpl(rate: Float) = impl.setRate(rate)
    override fun seekImpl(positionMillis: Long, seekGeneration: Int) {
        val active = session ?: return
        seeking?.cancel()
        if (!impl.seekable) {
            active.notifySeekCompleted(seekGeneration, impl.positionMillis, snapshot())
            return
        }
        impl.seek(positionMillis)
        seeking = scope.launch {
            val start = TimeSource.Monotonic.markNow()
            // VLC exposes no seek-complete callback. Observe the new playhead or bound refusal.
            do {
                delay(50)
            } while (abs(impl.positionMillis - positionMillis) > 750 && start.elapsedNow().inWholeMilliseconds < 5000)
            active.notifySeekCompleted(seekGeneration, impl.positionMillis, snapshot())
        }
    }
    override fun stopImpl() {
        polling?.cancel(); polling = null
        seeking?.cancel(); seeking = null
        session = null
        commandPending = null
        impl.stop()
        audio.update(emptyList(), null)
        subtitles.update(emptyList(), null)
    }
    override fun closeImpl() { stopImpl(); scope.cancel(); impl.close() }

    private fun refreshTracks() {
        val audioCandidates = impl.audioTracks.map {
            AudioTrack(it.id.toString(), it.id.toString(), it.name, listOf(TrackLabel(null, it.name)))
        }
        val subtitleCandidates = impl.subtitleTracks.map {
            SubtitleTrack(it.id.toString(), it.id.toString(), null, listOf(TrackLabel(null, it.name)))
        }
        audio.update(audioCandidates, audioCandidates.find { it.internalId == impl.selectedAudio.toString() })
        subtitles.update(subtitleCandidates, subtitleCandidates.find { it.internalId == impl.selectedSubtitle.toString() })
    }
}

@OptIn(InternalForInheritanceMediampApi::class)
private class VlcTrackGroup<T>(private val selectNative: (T?) -> Unit) : TrackGroup<T> {
    override val candidates = MutableStateFlow<List<T>>(emptyList())
    override val selected = MutableStateFlow<T?>(null)
    override fun select(track: T?): Boolean {
        if (track != null && track !in candidates.value) return false
        selectNative(track)
        selected.value = track
        return true
    }
    fun update(tracks: List<T>, selection: T?) {
        candidates.value = tracks
        selected.value = selection
    }
}
