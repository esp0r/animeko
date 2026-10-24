package me.him188.ani.app.videoplayer.player

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import me.him188.ani.app.platform.IosVlcPlayer
import me.him188.ani.app.platform.IosVlcTrack
import org.openani.mediamp.MediaStatus
import org.openani.mediamp.features.subtitleTracks
import org.openani.mediamp.source.UriMediaData
import platform.UIKit.UIView
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class IosVlcMediampPlayerTest {
    @Test
    fun subtitleScaleUsesSavedValueAndSurvivesMediaChanges() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val native = FakeVlc()
        native.setSubtitleScale(1.5f)
        val player = IosVlcMediampPlayer(coroutineContext, native)
        try {
            val size = player.features[SubtitleSize]!!
            assertEquals(1.5f, size.scale.value)
            player.setMediaData(UriMediaData("file:///first.mkv"))
            size.setScale(0.7f)
            assertEquals(0.7f, native.subtitleScale)
            player.setMediaData(UriMediaData("file:///second.mkv"))
            assertEquals(0.7f, size.scale.value)
            size.setScale(10f)
            assertEquals(2f, native.subtitleScale)
            size.setScale(Float.NaN)
            assertEquals(1f, native.subtitleScale)
        } finally {
            player.close(); runCurrent(); Dispatchers.resetMain()
        }
    }

    @Test
    fun pausedOpenAndSeekPreserveIntent() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val native = FakeVlc()
        val player = IosVlcMediampPlayer(coroutineContext, native)
        try {
            player.setMediaData(UriMediaData("file:///fixture.mkv"), startPositionMillis = 1200)
            assertFalse(player.state.value.playWhenReady)
            assertEquals(1200L, native.positionMillis)
            player.seekTo(3000)
            advanceTimeBy(200); runCurrent()
            assertFalse(player.state.value.playWhenReady)
            assertEquals(3000L, player.currentPositionMillis.value)
            player.play()
            advanceTimeBy(200); runCurrent()
            assertTrue(player.state.value.isPlaying)
            native.phase = 2
            advanceTimeBy(200); runCurrent()
            assertTrue(player.state.value.playWhenReady)
            player.pause()
            advanceTimeBy(200); runCurrent()
            assertFalse(player.state.value.playWhenReady)
        } finally {
            player.close(); runCurrent(); Dispatchers.resetMain()
        }
    }

    @Test
    fun trackRefreshPreservesSelectionAndStopClearsMetadata() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val native = FakeVlc()
        val player = IosVlcMediampPlayer(coroutineContext, native)
        try {
            player.setMediaData(UriMediaData("file:///fixture.mkv"), playWhenReady = true)
            val group = player.subtitleTracks!!
            assertEquals(2, group.candidates.first().size)
            val second = group.candidates.first()[1]
            assertTrue(group.select(second))
            advanceTimeBy(300); runCurrent()
            assertEquals(second, group.selected.value)
            assertTrue(group.select(null))
            advanceTimeBy(200); runCurrent()
            assertEquals(null, group.selected.value)
            player.stopPlayback(); runCurrent()
            assertTrue(group.candidates.first().isEmpty())
            assertEquals(MediaStatus.Idle, player.state.value.mediaStatus)
            player.setMediaData(UriMediaData("file:///second.mkv"), playWhenReady = true)
            native.phase = 5
            advanceTimeBy(200); runCurrent()
            assertEquals(MediaStatus.Ended, player.state.value.mediaStatus)
            player.play()
            advanceTimeBy(300); runCurrent()
            native.positionMillis = 500
            advanceTimeBy(200); runCurrent()
            assertTrue(player.state.value.isPlaying)
            assertEquals(500L, player.currentPositionMillis.value)
        } finally {
            player.close(); runCurrent(); Dispatchers.resetMain()
        }
    }
}

private class FakeVlc : IosVlcPlayer {
    override val view: UIView get() = error("No rendering in adapter tests")
    override var phase = 0
    override var positionMillis = 0L
    override val durationMillis = 8000L
    override val videoWidth = 64
    override val videoHeight = 64
    override val seekable = true
    override val audioTracks = listOf(IosVlcTrack(1, "Japanese"))
    override val subtitleTracks get() = listOf(IosVlcTrack(2, "Chinese"), IosVlcTrack(3, "English"))
    override var selectedAudio = 1
    override var selectedSubtitle = 2
    override fun open(uri: String, headers: Map<String, String>, startPositionMillis: Long) {
        positionMillis = startPositionMillis; phase = 3
    }
    override fun play() { phase = 3 }
    override fun pause() { phase = 4 }
    override fun stop() { phase = 0 }
    override fun close() = stop()
    override fun seek(positionMillis: Long) { this.positionMillis = positionMillis }
    private var savedSubtitleScale = 1f
    override val subtitleScale get() = savedSubtitleScale
    override fun setSubtitleScale(scale: Float) { savedSubtitleScale = scale }
    override fun setRate(rate: Float) {}
    override fun setVolume(volume: Float, muted: Boolean) {}
    override fun setAspect(mode: Int) {}
    override fun selectAudio(id: Int) { selectedAudio = id }
    override fun selectSubtitle(id: Int) { selectedSubtitle = id }
    override fun addSubtitle(uri: String) {}
}
