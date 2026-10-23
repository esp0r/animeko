package me.him188.ani.app.platform

import me.him188.ani.utils.platform.Platform
import me.him188.ani.utils.platform.currentPlatform

/** The sideloaded iOS build is distributed as an IPA outside the upstream updater. */
val appUpdatesEnabled: Boolean get() = currentPlatform() != Platform.Ios
