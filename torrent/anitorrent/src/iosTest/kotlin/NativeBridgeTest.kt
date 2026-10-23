@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package me.him188.ani.app.torrent.anitorrent

import kotlinx.cinterop.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import me.him188.ani.app.torrent.anitorrent.binding.*
import me.him188.ani.utils.io.SystemPaths
import me.him188.ani.utils.io.absolutePath
import me.him188.ani.utils.io.createTempDirectory
import me.him188.ani.utils.io.deleteRecursively
import me.him188.ani.utils.io.exists
import me.him188.ani.utils.io.resolve
import me.him188.ani.utils.io.writeBytes
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NativeBridgeTest {
    private fun <T> withSession(block: (CPointer<ani_session>) -> T): T = memScoped {
        val config = alloc<ani_settings>()
        config.user_agent = "AnimekoNativeTest/1".cstr.ptr
        config.peer_fingerprint = "-AT0001-".cstr.ptr
        config.handshake_client_version = "test".cstr.ptr
        config.download_rate_limit = 0
        config.upload_rate_limit = 0
        config.share_ratio_limit = 200
        val session = assertNotNull(ani_session_create(config.ptr, null, null), ani_last_error()?.toKString())
        try { block(session) } finally { assertEquals(0, ani_session_destroy(session)) }
    }

    @Test
    fun `invalid torrent reports an error across C ABI`() {
        withSession { session ->
            assertNull(ani_session_add(session, "magnet:?xt=invalid", null, null, "/tmp"))
            assertFalse(ani_last_error()?.toKString().isNullOrBlank())
        }
    }

    @Test
    fun `metadata priorities resume persistence and handle release`() {
        val directory = SystemPaths.createTempDirectory("native-bt-test")
        try {
            val torrent = directory.resolve("fixture.torrent")
            // A four-byte file containing "test", with its SHA-1 piece hash.
            val hash = byteArrayOf(0xa9.toByte(), 0x4a, 0x8f.toByte(), 0xe5.toByte(), 0xcc.toByte(),
                0xb1.toByte(), 0x9b.toByte(), 0xa6.toByte(), 0x1c, 0x4c, 0x08, 0x73, 0xd3.toByte(),
                0x91.toByte(), 0xe9.toByte(), 0x87.toByte(), 0x98.toByte(), 0x2f, 0xbb.toByte(), 0xd3.toByte())
            torrent.writeBytes("d4:infod6:lengthi4e4:name8:test.bin12:piece lengthi16384e6:pieces20:".encodeToByteArray() + hash + "ee".encodeToByteArray())
            val resume = directory.resolve("fastresume")
            withSession { session ->
                val handle = assertNotNull(ani_session_add(session, null, torrent.absolutePath, null, directory.absolutePath))
                try {
                    assertEquals(1, ani_handle_valid(handle))
                    val info = assertNotNull(ani_handle_info(handle))
                    try {
                        assertEquals("test.bin", ani_info_name(info)?.toKString())
                        assertEquals(1, ani_info_file_count(info))
                        assertEquals(4L, ani_info_file_size(info, 0))
                        assertEquals(1, ani_info_piece_count(info))
                        assertEquals(4L, ani_info_last_piece_size(info))
                    } finally { ani_info_destroy(info) }
                    assertEquals(0, ani_handle_priority(handle, 0, 7))
                    assertEquals(0, ani_handle_deadline(handle, 0, 100))
                    assertEquals(0, ani_handle_clear_deadlines(handle))
                    assertEquals(0, ani_session_resume(session))
                    assertEquals(0, ani_handle_post_resume(handle))
                    val capture = ResumeCapture(resume.absolutePath)
                    val reference = StableRef.create(capture)
                    try {
                        runBlocking {
                            withTimeout(10_000) {
                                while (!capture.saved) {
                                    assertEquals(0, ani_session_poll(session, saveResume, reference.asCPointer()))
                                    delay(20)
                                }
                            }
                        }
                    } finally { reference.dispose() }
                    assertTrue(resume.exists())
                    assertEquals(0, ani_session_remove(session, handle))
                } finally { ani_handle_destroy(handle) }
            }
            withSession { session ->
                val handle = assertNotNull(ani_session_add(session, null, torrent.absolutePath, resume.absolutePath, directory.absolutePath))
                try { assertEquals(1, ani_handle_valid(handle)) }
                finally { ani_session_remove(session, handle); ani_handle_destroy(handle) }
            }
        } finally { directory.deleteRecursively() }
    }

    private class ResumeCapture(val path: String, var saved: Boolean = false)
    companion object {
        private val saveResume = staticCFunction { context: COpaquePointer?, kind: Int, _: UInt, _: Int, data: COpaquePointer? ->
            if (kind == ANI_RESUME) {
                val capture = context!!.asStableRef<ResumeCapture>().get()
                val copy = ani_resume_copy(data)
                if (copy != null) {
                    capture.saved = ani_resume_save(copy, capture.path) == 0
                    ani_resume_destroy(copy)
                }
            }
            Unit
        }
    }
}
