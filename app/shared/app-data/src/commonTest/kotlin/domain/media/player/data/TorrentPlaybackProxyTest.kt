package me.him188.ani.app.domain.media.player.data

import kotlinx.coroutines.test.runTest
import me.him188.ani.app.domain.media.hls.HlsProxyRequest
import me.him188.ani.app.domain.media.hls.HlsProxyRequestHandler
import me.him188.ani.app.domain.media.hls.HlsProxyResponseSink
import me.him188.ani.app.domain.media.hls.HlsProxyServer
import me.him188.ani.app.domain.media.hls.HlsProxyServerFactory
import org.openani.mediamp.io.SeekableInput
import org.openani.mediamp.source.MediaExtraFiles
import org.openani.mediamp.source.SeekableInputMediaData
import kotlin.coroutines.CoroutineContext
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue

class TorrentPlaybackProxyTest {
    @Test
    fun `serves exact range with partial reads and preserves source identity`() = runTest {
        val source = MemoryMedia()
        val server = RecordingServer()
        val proxy = TorrentPlaybackProxy.create(source, HlsProxyServerFactory { server })
        try {
            assertSame(source, proxy.data.unwrapTorrentPlayback())
            val result = server.request(proxy.data.uri.substringAfter(":1234"), "GET", "bytes=2-7")
            assertTrue(result.startsWith("HTTP/1.1 206 Partial Content\r\n"))
            assertTrue(result.contains("Content-Range: bytes 2-7/10\r\n"))
            assertTrue(result.contains("Content-Length: 6\r\n"))
            assertEquals("234567", result.substringAfter("\r\n\r\n"))
            assertEquals(1, source.closedInputs)
        } finally { proxy.close() }
        proxy.close()
        assertSame(proxy.data, proxy.data.unwrapTorrentPlayback())
        assertEquals(1, source.closes)
        assertTrue(server.closed)
    }

    @Test
    fun `head invalid ranges and unknown paths never open a file`() = runTest {
        val source = MemoryMedia()
        val server = RecordingServer()
        val proxy = TorrentPlaybackProxy.create(source, HlsProxyServerFactory { server })
        try {
            val path = proxy.data.uri.substringAfter(":1234")
            val head = server.request(path, "HEAD", null)
            assertTrue(head.startsWith("HTTP/1.1 200 OK"))
            assertEquals("", head.substringAfter("\r\n\r\n"))
            assertTrue(server.request(path, "GET", "bytes=10-").startsWith("HTTP/1.1 416"))
            assertTrue(server.request("/other", "GET", null).startsWith("HTTP/1.1 404"))
            assertTrue(server.request(path, "POST", null).startsWith("HTTP/1.1 405"))
            assertEquals(0, source.openedInputs)
        } finally { proxy.close() }
    }

    @Test
    fun `failed server startup closes the source`() = runTest {
        val source = MemoryMedia()
        val result = runCatching {
            TorrentPlaybackProxy.create(source, HlsProxyServerFactory { error("bind failed") })
        }
        assertTrue(result.isFailure)
        assertEquals(1, source.closes)
    }

    private class RecordingServer : HlsProxyServer {
        override val port = 1234
        lateinit var handler: HlsProxyRequestHandler
        var closed = false
        override fun start(handler: HlsProxyRequestHandler) { this.handler = handler }
        override fun close() { closed = true }
        suspend fun request(path: String, method: String, range: String?): String {
            val output = mutableListOf<Byte>()
            handler.handle(HlsProxyRequest(path, range?.let { mapOf("range" to it) } ?: emptyMap(), method),
                object : HlsProxyResponseSink {
                    override suspend fun write(bytes: ByteArray, offset: Int, length: Int) {
                        repeat(length) { output.add(bytes[offset + it]) }
                    }
                })
            return output.toByteArray().decodeToString()
        }
    }

    private class MemoryMedia : SeekableInputMediaData {
        override val uri = "memory://episode.mp4"
        override val extraFiles = MediaExtraFiles.EMPTY
        override val options = emptyList<String>()
        var closes = 0
        var openedInputs = 0
        var closedInputs = 0
        override fun fileLength() = 10L
        override fun close() { closes++ }
        override suspend fun createInput(coroutineContext: CoroutineContext): SeekableInput {
            openedInputs++
            return object : SeekableInput {
                override var position = 0L
                override val size = 10L
                override val bytesRemaining get() = size - position
                override fun seekTo(position: Long) { this.position = position }
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                    val count = minOf(length.toLong(), bytesRemaining, 2L).toInt()
                    if (count == 0) return -1
                    repeat(count) { buffer[offset + it] = ('0'.code + position++).toByte() }
                    return count
                }
                override fun close() { closedInputs++ }
            }
        }
    }
}
