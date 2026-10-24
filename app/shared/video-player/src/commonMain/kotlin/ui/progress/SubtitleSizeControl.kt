package me.him188.ani.app.videoplayer.ui.progress

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import me.him188.ani.app.ui.lang.Lang
import me.him188.ani.app.ui.lang.video_subtitle_size
import me.him188.ani.app.ui.lang.video_subtitle_size_hint
import me.him188.ani.app.ui.lang.video_subtitle_size_reset
import me.him188.ani.app.ui.lang.video_subtitle_size_done
import me.him188.ani.app.videoplayer.player.SubtitleSize
import org.jetbrains.compose.resources.stringResource
import kotlin.math.roundToInt

@Composable
fun SubtitleSizeControl(controller: SubtitleSize, onOpenChange: (Boolean) -> Unit = {}) {
    var open by rememberSaveable { mutableStateOf(false) }
    val scale by controller.scale.collectAsStateWithLifecycle()
    TextButton(onClick = { open = true }, modifier = Modifier.testTag("subtitle-size-open")) {
        Text(stringResource(Lang.video_subtitle_size))
    }
    if (open) {
        DisposableEffect(Unit) {
            onOpenChange(true)
            onDispose { onOpenChange(false) }
        }
        AlertDialog(
            onDismissRequest = { open = false },
            title = { Text(stringResource(Lang.video_subtitle_size)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("${(scale * 100).roundToInt()}%", Modifier.testTag("subtitle-size-value"))
                    Slider(
                        value = scale,
                        onValueChange = controller::setScale,
                        valueRange = 0.5f..2f,
                        steps = 14,
                        modifier = Modifier.testTag("subtitle-size-slider"),
                    )
                    Text(stringResource(Lang.video_subtitle_size_hint))
                }
            },
            dismissButton = {
                TextButton(onClick = { controller.setScale(1f) }, modifier = Modifier.testTag("subtitle-size-reset")) {
                    Text(stringResource(Lang.video_subtitle_size_reset))
                }
            },
            confirmButton = {
                TextButton(onClick = { open = false }) { Text(stringResource(Lang.video_subtitle_size_done)) }
            },
        )
    }
}
