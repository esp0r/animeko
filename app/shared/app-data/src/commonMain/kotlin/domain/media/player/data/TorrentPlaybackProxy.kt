package me.him188.ani.app.domain.media.player.data

import kotlinx.atomicfu.atomic
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import me.him188.ani.app.domain.media.hls.HlsProxyRequest
import me.him188.ani.app.domain.media.hls.HlsProxyResponseSink
import me.him188.ani.app.domain.media.hls.HlsProxyServer
import me.him188.ani.app.domain.media.hls.PlatformHlsProxyServerFactory
import me.him188.ani.utils.coroutines.IO_
import org.openani.mediamp.source.UriMediaData
import org.openani.mediamp.source.MediaData
import kotlin.uuid.ExperimentalUuidApi
import kotlin.uuid.Uuid

/** Serves verified torrent pieces to AVKit through a loopback-only HTTP endpoint.
 * Every request owns its input cursor; a seek cannot move another request's cursor. */
internal class TorrentPlaybackProxy private constructor(
    private val source: TorrentMediaData,
    private val server: HlsProxyServer,
    private val path: String,
) : AutoCloseable {
    private val closed = atomic(false)
    private val readers = Semaphore(4)
    val data = UriMediaData("http://127.0.0.1:${server.port}$path", emptyMap(), source.extraFiles, source.options)

    private suspend fun handle(request: HlsProxyRequest, sink: HlsProxyResponseSink) {
        if (request.path != path) {
            sink.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encodeToByteArray())
            return
        }
        if (request.method != "GET" && request.method != "HEAD") {
            sink.write("HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encodeToByteArray())
            return
        }
        val size = source.fileLength()
        val rangeHeader = request.headers["range"]
        val range = parseTorrentHttpRange(rangeHeader, size)
        if (range == null) {
            sink.write("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */$size\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encodeToByteArray())
            return
        }
        val length = if (range.isEmpty()) 0L else range.last - range.first + 1
        val mime = when (source.filename.substringAfterLast('.').lowercase()) {
            "mp4", "m4v" -> "video/mp4"
            "mov" -> "video/quicktime"
            "mkv" -> "video/x-matroska"
            "webm" -> "video/webm"
            else -> "application/octet-stream"
        }
        val header = buildString {
            append(if (rangeHeader == null) "HTTP/1.1 200 OK\r\n" else "HTTP/1.1 206 Partial Content\r\n")
            append("Accept-Ranges: bytes\r\nContent-Type: $mime\r\nContent-Length: $length\r\n")
            if (rangeHeader != null) append("Content-Range: bytes ${range.first}-${range.last}/$size\r\n")
            append("Connection: close\r\nCache-Control: no-store\r\n\r\n")
        }
        sink.write(header.encodeToByteArray())
        if (request.method == "HEAD" || length == 0L) return
        readers.withPermit {
            withContext(Dispatchers.IO_) {
                source.createInput(currentCoroutineContext()).use { input ->
                    input.seekTo(range.first)
                    val buffer = ByteArray(64 * 1024)
                    var remaining = length
                    while (remaining > 0) {
                        val count = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                        check(count > 0) { "Torrent input ended before the requested byte range" }
                        sink.write(buffer, 0, count)
                        remaining -= count
                    }
                }
            }
        }
    }

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            synchronized(sourcesLock) { sources.remove(data) }
            server.close()
            source.close()
        }
    }

    companion object {
        private val sourcesLock = SynchronizedObject()
        private val sources = mutableMapOf<MediaData, TorrentMediaData>()

        fun sourceFor(data: MediaData): TorrentMediaData? = synchronized(sourcesLock) { sources[data] }

        @OptIn(ExperimentalUuidApi::class)
        suspend fun create(source: TorrentMediaData): TorrentPlaybackProxy {
            val server = PlatformHlsProxyServerFactory.create()
            try {
                return TorrentPlaybackProxy(source, server, "/${Uuid.random()}/video").also { proxy ->
                    server.start(proxy::handle)
                    synchronized(sourcesLock) { sources[proxy.data] = source }
                }
            } catch (error: Throwable) {
                server.close()
                throw error
            }
        }
    }
}

/** Restores BT identity for progress, prefetch and sharing while AVKit consumes a loopback URI. */
fun MediaData.unwrapTorrentPlayback(): MediaData = TorrentPlaybackProxy.sourceFor(this) ?: this

/** A null result means malformed or unsatisfiable. A missing Range selects the whole file. */
internal fun parseTorrentHttpRange(header: String?, size: Long): LongRange? {
    require(size >= 0)
    if (header == null) return if (size == 0L) LongRange.EMPTY else 0L until size
    if (size == 0L || !header.startsWith("bytes=") || ',' in header) return null
    val spec = header.removePrefix("bytes=").trim()
    val dash = spec.indexOf('-')
    if (dash < 0 || spec.indexOf('-', dash + 1) >= 0) return null
    val first = spec.substring(0, dash)
    val last = spec.substring(dash + 1)
    if (first.isEmpty()) {
        val suffix = last.toLongOrNull()?.takeIf { it > 0 } ?: return null
        return (size - suffix.coerceAtMost(size)) until size
    }
    val start = first.toLongOrNull()?.takeIf { it >= 0 && it < size } ?: return null
    val end = if (last.isEmpty()) size - 1 else last.toLongOrNull() ?: return null
    if (end < start) return null
    return start..minOf(end, size - 1)
}
