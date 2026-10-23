package me.him188.ani.app.platform

import platform.UIKit.UIView

/** Main-thread bridge to MobileVLCKit. No media bytes cross the Swift/Kotlin boundary. */
interface IosVlcPlayer {
    val view: UIView
    /** 0 stopped, 1 opening, 2 buffering, 3 playing, 4 paused, 5 ended, 6 error. */
    val phase: Int
    val positionMillis: Long
    val durationMillis: Long
    val videoWidth: Int
    val videoHeight: Int
    val seekable: Boolean
    val audioTracks: List<IosVlcTrack>
    val subtitleTracks: List<IosVlcTrack>
    val selectedAudio: Int
    val selectedSubtitle: Int
    fun open(uri: String, headers: Map<String, String>, startPositionMillis: Long)
    fun play()
    fun pause()
    fun stop()
    fun close()
    fun seek(positionMillis: Long)
    fun setRate(rate: Float)
    fun setVolume(volume: Float, muted: Boolean)
    fun setAspect(mode: Int)
    fun selectAudio(id: Int)
    fun selectSubtitle(id: Int)
    fun addSubtitle(uri: String)
}

class IosVlcTrack(val id: Int, val name: String)
