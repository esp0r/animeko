package me.him188.ani.app.domain.foundation

import me.him188.ani.app.platform.appUpdatesEnabled
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNull

class IosUpdatePolicyTest {
    @Test
    fun sideloadedBuildIgnoresVersionExpiry() {
        assertFalse(appUpdatesEnabled)
        val service = DefaultVersionExpiryService()
        service.onVersionExpired("99.0.0")
        assertNull(service.state.value)
    }
}
