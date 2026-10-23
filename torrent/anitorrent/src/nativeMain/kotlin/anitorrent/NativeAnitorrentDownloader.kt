@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlin.experimental.ExperimentalNativeApi::class)

package me.him188.ani.app.torrent.anitorrent

import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.cinterop.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.io.files.Path
import me.him188.ani.app.torrent.anitorrent.binding.*
import me.him188.ani.app.torrent.anitorrent.session.*
import me.him188.ani.app.torrent.api.HttpFileDownloader
import me.him188.ani.app.torrent.api.TorrentDownloaderConfig
import me.him188.ani.app.torrent.api.TorrentHandleState
import me.him188.ani.app.torrent.api.files.FilePriority
import me.him188.ani.app.torrent.api.peer.PeerInfo
import me.him188.ani.datasources.api.topic.FileSize.Companion.bytes
import me.him188.ani.utils.coroutines.IO_
import me.him188.ani.utils.io.SystemPath
import me.him188.ani.utils.logging.error
import me.him188.ani.app.torrent.anitorrent.AnitorrentTorrentDownloader.Companion.logger
import kotlin.coroutines.CoroutineContext
import kotlin.native.ref.createCleaner
import platform.Foundation.NSNotificationCenter
import platform.Foundation.NSOperationQueue
import platform.UIKit.UIApplicationWillResignActiveNotification

private fun nativeCheck(result: Int) {
    check(result >= 0) { ani_last_error()?.toKString() ?: "Native torrent operation failed" }
}

private fun <T : CPointed> nativePointer(pointer: CPointer<T>?): CPointer<T> =
    checkNotNull(pointer) { ani_last_error()?.toKString() ?: "Native torrent allocation failed" }

private inline fun <T> TorrentDownloaderConfig.withSettings(block: (CPointer<ani_settings>) -> T): T = memScoped {
    val settings = alloc<ani_settings>()
    settings.user_agent = userAgent.cstr.ptr
    settings.peer_fingerprint = peerFingerprint.cstr.ptr
    settings.handshake_client_version = handshakeClientVersion.orEmpty().cstr.ptr
    settings.download_rate_limit = downloadRateLimitBytes
    settings.upload_rate_limit = uploadRateLimitBytes
    settings.share_ratio_limit = shareRatioLimit
    block(settings.ptr)
}

internal class NativeAnitorrentDownloader(
    root: SystemPath,
    http: HttpFileDownloader,
    config: TorrentDownloaderConfig,
    context: CoroutineContext,
) : AnitorrentTorrentDownloader<NativeTorrentHandle, NativeTorrentAddInfo>(root, http, context) {
    private val reference = StableRef.create(this)
    override val native = NativeTorrentManagerSession(config, reference.asCPointer())
    private val closeLock = SynchronizedObject()
    private var closed = false
    private val lifecycleObserver = NSNotificationCenter.defaultCenter.addObserverForName(
        UIApplicationWillResignActiveNotification, null, NSOperationQueue.mainQueue,
    ) {
        runCatching { native.saveResumeData() }
            .onFailure { error -> logger.error(error) { "Failed to checkpoint torrents before suspension" } }
    }

    init {
        extraTrackers = config.extraTrackers
        scope.launch(Dispatchers.IO_) {
            while (isActive) {
                val events = mutableListOf<NativeEvent>()
                val eventReference = StableRef.create(events)
                try {
                    native.access { session ->
                        nativeCheck(ani_session_poll(session, eventCallback, eventReference.asCPointer()))
                    }
                } finally {
                    eventReference.dispose()
                }
                // Session callbacks acquire their own locks and may call the engine.
                // Dispatch after releasing the native lock to avoid lock-order cycles.
                events.forEach { event ->
                    runCatching { processEvent(event) }
                        .onFailure { error -> logger.error(error) { "Native torrent event failed" } }
                }
                delay(100)
            }
        }
        scope.launch(Dispatchers.IO_) {
            while (isActive) {
                delay(15_000)
                native.saveResumeData()
            }
        }
    }

    private fun shouldBlock(peer: CPointer<ani_peer>): Boolean = filter?.shouldBlock(NativePeer(peer.pointed)) ?: false

    private fun processEvent(event: NativeEvent) = with(event) {
        if (kind == ANI_REMOVED.toInt() && id == 0L) {
            val name = name ?: return@with
            runBlocking(Dispatchers.IO_) {
                withTimeoutOrNull(1_000) { openSessions.value.values.firstOrNull { it.getName() == name } }
            }?.onTorrentRemoved()
            return@with
        }
        dispatchToSession(id) { session ->
            when (kind) {
                ANI_CHECKED.toInt() -> session.onTorrentChecked()
                ANI_METADATA.toInt() -> session.onMetadataReceived()
                ANI_PIECE_DOWNLOADING.toInt() -> session.onPieceDownloading(index)
                ANI_PIECE_FINISHED.toInt() -> session.onPieceFinished(index)
                ANI_FINISHED.toInt() -> session.onTorrentFinished()
                ANI_STATS.toInt() -> stats?.let(session::onStatsUpdate)
                ANI_FILE_COMPLETED.toInt() -> session.onFileCompleted(index)
                ANI_REMOVED.toInt() -> session.onTorrentRemoved()
                ANI_RESUME.toInt() -> resume?.let(session::onSaveResumeData)
            }
        }
    }

    override fun close() = synchronized(closeLock) {
        if (closed) return@synchronized
        closed = true
        NSNotificationCenter.defaultCenter.removeObserver(lifecycleObserver)
        super.close()
        native.close()
        reference.dispose()
    }

    companion object {
        private val eventCallback = staticCFunction { ctx: COpaquePointer?, kind: Int, id: UInt, index: Int, data: COpaquePointer? ->
            try {
                val stats = if (kind == ANI_STATS.toInt()) data?.reinterpret<ani_stats>()?.pointed?.let(::NativeStats) else null
                val resume = if (kind == ANI_RESUME.toInt()) NativeResumeData(nativePointer(ani_resume_copy(data))) else null
                val name = if (kind == ANI_REMOVED.toInt()) data?.reinterpret<ByteVar>()?.toKString() else null
                ctx!!.asStableRef<MutableList<NativeEvent>>().get().add(NativeEvent(kind, id.toLong(), index, stats, resume, name))
            } catch (error: Throwable) {
                logger.error(error) { "Native torrent event failed" }
            }
        }
        val peerCallback = staticCFunction { ctx: COpaquePointer?, peer: CPointer<ani_peer>? ->
            try {
                if (peer != null && ctx!!.asStableRef<NativeAnitorrentDownloader>().get().shouldBlock(peer)) 1 else 0
            } catch (error: Throwable) {
                logger.error(error) { "Native torrent peer filter failed" }
                0
            }
        }
    }
}

private data class NativeEvent(
    val kind: Int,
    val id: Long,
    val index: Int,
    val stats: NativeStats?,
    val resume: NativeResumeData?,
    val name: String?,
)

internal class NativeTorrentManagerSession(config: TorrentDownloaderConfig, context: COpaquePointer) :
    SynchronizedObject(), TorrentManagerSession<NativeTorrentHandle, NativeTorrentAddInfo> {
    private var pointer = config.withSettings {
        nativePointer(ani_session_create(it, NativeAnitorrentDownloader.peerCallback, context))
    }
    private var closed = false
    private val handles = mutableSetOf<NativeTorrentHandle>()

    fun <T> access(block: (CPointer<ani_session>) -> T): T = synchronized(this) {
        check(!closed) { "Torrent session is closed" }
        block(pointer)
    }

    override fun createTorrentHandle() = NativeTorrentHandle(this)
    override fun createTorrentAddInfo() = NativeTorrentAddInfo()
    override fun startDownload(handle: NativeTorrentHandle, addInfo: NativeTorrentAddInfo, saveDir: Path): Boolean = access {
        handle.pointer = nativePointer(ani_session_add(it, addInfo.magnet, addInfo.torrent, addInfo.resume, saveDir.toString()))
        handle.handleId = ani_handle_id(handle.pointer).toLong()
        handles.add(handle)
        true
    }
    override fun releaseHandle(handle: NativeTorrentHandle) = access {
        handle.pointer?.let { pointer ->
            nativeCheck(ani_session_remove(it, pointer))
            nativeCheck(ani_handle_destroy(pointer))
            handle.pointer = null
        }
        handles.remove(handle)
        Unit
    }
    override fun resume() = access { nativeCheck(ani_session_resume(it)) }
    override fun applyConfig(config: TorrentDownloaderConfig) = access { session ->
        config.withSettings { nativeCheck(ani_session_configure(session, it)) }
    }
    fun saveResumeData() = access {
        handles.forEach { handle -> handle.pointer?.let { pointer -> nativeCheck(ani_handle_post_resume(pointer)) } }
    }
    fun close() = synchronized(this) {
        if (closed) return@synchronized
        closed = true
        nativeCheck(ani_session_destroy(pointer))
        handles.forEach { handle ->
            handle.pointer?.let { ani_handle_destroy(it) }
            handle.pointer = null
        }
        handles.clear()
    }
}

internal class NativeTorrentAddInfo : TorrentAddInfo {
    var magnet: String? = null
    var torrent: String? = null
    var resume: String? = null
    override fun setMagnetUri(uri: String) { magnet = uri }
    override fun setTorrentFilePath(absolutePath: String) { torrent = absolutePath }
    override fun setResumeDataPath(absolutePath: String) { resume = absolutePath }
}

internal class NativeTorrentHandle(private val owner: NativeTorrentManagerSession) : TorrentHandle {
    var pointer: CPointer<ani_handle>? = null
    var handleId: Long = 0
    override val id get() = handleId
    private fun <T> access(block: (CPointer<ani_handle>) -> T): T = owner.access {
        block(checkNotNull(pointer) { "Torrent handle is closed" })
    }
    override val isValid get() = owner.access { pointer?.let { ani_handle_valid(it) == 1 } ?: false }
    override fun postStatusUpdates() = access { nativeCheck(ani_handle_post_status(it)) }
    override fun postSaveResume() = access { nativeCheck(ani_handle_post_resume(it)) }
    override fun resume() = access { nativeCheck(ani_handle_resume(it)) }
    override fun setFilePriority(index: Int, priority: FilePriority) = access {
        val value = when (priority) {
            FilePriority.IGNORE -> 0
            FilePriority.LOW -> 1
            FilePriority.NORMAL -> 4
            FilePriority.HIGH -> 7
        }
        nativeCheck(ani_handle_priority(it, index, value))
    }
    override fun getState(): TorrentHandleState? = owner.access {
        pointer?.let { TorrentHandleState.entries.getOrNull(ani_handle_state(it)) }
    }
    override fun reloadFile(): TorrentDescriptor = access { handle ->
        val info = nativePointer(ani_handle_info(handle))
        try {
            NativeDescriptor(
                ani_info_name(info)!!.toKString(),
                List(ani_info_file_count(info)) { index ->
                    NativeFile(ani_info_file_name(info, index)!!.toKString(),
                        ani_info_file_path(info, index)!!.toKString(), ani_info_file_size(info, index))
                },
                ani_info_piece_count(info), ani_info_last_piece_size(info), ani_info_piece_length(info),
            )
        } finally { ani_info_destroy(info) }
    }
    override fun getPeers(): List<PeerInfo> = access { handle ->
        val peers = mutableListOf<PeerInfo>()
        val ref = StableRef.create(peers)
        try { nativeCheck(ani_handle_peers(handle, collectPeer, ref.asCPointer())) }
        finally { ref.dispose() }
        peers
    }
    override fun setPieceDeadline(index: Int, deadline: Int) = access { nativeCheck(ani_handle_deadline(it, index, deadline)) }
    override fun clearPieceDeadlines() = access { nativeCheck(ani_handle_clear_deadlines(it)) }
    override fun addTracker(tracker: String, tier: Short, failLimit: Short) = access {
        nativeCheck(ani_handle_tracker(it, tracker, tier.toInt(), failLimit.toInt()))
    }
    override fun getMagnetUri(): String? = access { ani_handle_magnet(it)?.toKString()?.takeIf(String::isNotBlank) }

    companion object {
        private val collectPeer = staticCFunction { context: COpaquePointer?, peer: CPointer<ani_peer>? ->
            if (peer != null) context!!.asStableRef<MutableList<PeerInfo>>().get().add(NativePeer(peer.pointed))
            Unit
        }
    }
}

private data class NativeFile(override val name: String, override val path: String, override val size: Long) : TorrentFileInfo
private data class NativeDescriptor(
    override val name: String,
    val files: List<TorrentFileInfo>,
    override val numPieces: Int,
    override val lastPieceSize: Long,
    override val pieceLength: Long,
) : TorrentDescriptor {
    override val fileCount get() = files.size
    override fun fileAtOrNull(index: Int) = files.getOrNull(index)
}

private class NativeStats(s: ani_stats) : TorrentStats {
    override val total = s.total
    override val totalDone = s.total_done
    override val allTimeUpload = s.all_time_upload
    override val allTimeDownload = s.all_time_download
    override val downloadPayloadRate = s.download_payload_rate
    override val uploadPayloadRate = s.upload_payload_rate
    override val totalPayloadDownload = s.total_payload_download
    override val totalPayloadUpload = s.total_payload_upload
    override val progress = s.progress
}

private class NativePeer(p: ani_peer) : PeerInfo {
    override val handle = p.handle_id.toLong()
    override val id = CharArray(p.peer_id_size.toInt()) { p.peer_id!![it].toInt().and(255).toChar() }
    override val client = p.client?.toKString().orEmpty()
    override val ipAddr = p.ip_addr?.toKString().orEmpty()
    override val ipPort = p.ip_port.toInt()
    override val progress = p.progress
    override val totalDownload = p.total_download.bytes
    override val totalUpload = p.total_upload.bytes
    override val flags = p.flags.toLong()
}

private class NativeResumeData(private val pointer: CPointer<ani_resume>) : TorrentResumeData {
    private val cleaner = createCleaner(pointer) { ani_resume_destroy(it) }
    override fun saveToPath(path: Path) { nativeCheck(ani_resume_save(pointer, path.toString())) }
}
