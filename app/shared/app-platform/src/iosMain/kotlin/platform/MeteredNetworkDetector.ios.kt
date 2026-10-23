/*
 * Copyright (C) 2024 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.platform

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.coroutines.flow.MutableStateFlow
import platform.Network.nw_path_is_constrained
import platform.Network.nw_path_is_expensive
import platform.Network.nw_path_monitor_cancel
import platform.Network.nw_path_monitor_create
import platform.Network.nw_path_monitor_set_queue
import platform.Network.nw_path_monitor_set_update_handler
import platform.Network.nw_path_monitor_start
import platform.darwin.dispatch_queue_create

actual fun createMeteredNetworkDetector(context: Context): MeteredNetworkDetector {
    return IosMeteredNetworkDetector()
}

@OptIn(ExperimentalForeignApi::class)
private class IosMeteredNetworkDetector : MeteredNetworkDetector {
    override val isMeteredNetworkFlow = MutableStateFlow(true)
    private val monitor = nw_path_monitor_create()
    private val queue = dispatch_queue_create("animeko.network-cost", null)

    init {
        nw_path_monitor_set_update_handler(monitor) { path ->
            if (path != null) {
                isMeteredNetworkFlow.value = nw_path_is_expensive(path) || nw_path_is_constrained(path)
            }
        }
        nw_path_monitor_set_queue(monitor, queue)
        nw_path_monitor_start(monitor)
    }

    override fun dispose() {
        nw_path_monitor_cancel(monitor)
        nw_path_monitor_set_update_handler(monitor) { }
    }
}
