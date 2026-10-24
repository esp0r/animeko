package me.him188.ani.app.videoplayer.ui

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import kotlinx.coroutines.flow.MutableStateFlow
import me.him188.ani.app.ui.foundation.ProvideCompositionLocalsForPreview
import me.him188.ani.app.ui.framework.runAniComposeUiTest
import me.him188.ani.app.videoplayer.player.SubtitleSize
import me.him188.ani.app.videoplayer.ui.progress.SubtitleSizeControl
import kotlin.test.Test
import kotlin.test.assertEquals

class SubtitleSizeControlTest {
    @Test
    fun `slider applies scale immediately and reset restores default`() = runAniComposeUiTest {
        val controller = object : SubtitleSize {
            override val scale = MutableStateFlow(1f)
            override fun setScale(scale: Float) { this.scale.value = scale }
        }
        setContent {
            ProvideCompositionLocalsForPreview { SubtitleSizeControl(controller) }
        }
        onNodeWithTag("subtitle-size-open").performClick()
        onNodeWithTag("subtitle-size-slider").performSemanticsAction(SemanticsActions.SetProgress) { it(1.5f) }
        onNodeWithTag("subtitle-size-value").assertTextEquals("150%")
        runOnIdle { assertEquals(1.5f, controller.scale.value) }
        onNodeWithTag("subtitle-size-reset").performClick()
        onNodeWithTag("subtitle-size-value").assertTextEquals("100%")
        runOnIdle { assertEquals(1f, controller.scale.value) }
    }
}
