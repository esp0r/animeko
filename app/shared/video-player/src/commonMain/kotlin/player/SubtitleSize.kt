package me.him188.ani.app.videoplayer.player

import kotlinx.coroutines.flow.StateFlow
import org.openani.mediamp.features.Feature
import org.openani.mediamp.features.FeatureKey

/** User scale for text captions; styled or bitmap subtitles may use their own layout. */
interface SubtitleSize : Feature {
    val scale: StateFlow<Float>
    fun setScale(scale: Float)
    companion object : FeatureKey<SubtitleSize>
}
