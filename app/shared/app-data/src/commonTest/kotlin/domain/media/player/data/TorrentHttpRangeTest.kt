package me.him188.ani.app.domain.media.player.data

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class TorrentHttpRangeTest {
    @Test
    fun `AVKit probe and seek ranges`() {
        assertEquals(0L..1L, parseTorrentHttpRange("bytes=0-1", 100))
        assertEquals(50L..99L, parseTorrentHttpRange("bytes=50-", 100))
        assertEquals(90L..99L, parseTorrentHttpRange("bytes=-10", 100))
        assertEquals(0L..99L, parseTorrentHttpRange("bytes=-200", 100))
        assertEquals(90L..99L, parseTorrentHttpRange("bytes=90-200", 100))
        assertEquals(0L..99L, parseTorrentHttpRange(null, 100))
    }

    @Test
    fun `invalid and unsatisfiable ranges`() {
        listOf("bytes=100-", "bytes=5-4", "bytes=-0", "bytes=", "bytes=1-2,4-5",
            "bytes=--1", "bytes=999999999999999999999-", "items=0-1").forEach {
            assertNull(parseTorrentHttpRange(it, 100), it)
        }
        assertNull(parseTorrentHttpRange("bytes=0-0", 0))
        assertEquals(LongRange.EMPTY, parseTorrentHttpRange(null, 0))
    }

    @Test
    fun `large torrent offsets do not overflow`() {
        val size = 10_000_000_000L
        assertEquals(9_000_000_000L..9_999_999_999L, parseTorrentHttpRange("bytes=9000000000-", size))
        assertEquals(0L until size, parseTorrentHttpRange("bytes=-9223372036854775807", size))
    }
}
