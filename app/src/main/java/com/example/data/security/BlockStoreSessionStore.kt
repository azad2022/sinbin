package com.example.data.security

import android.content.Context
import com.google.android.gms.auth.blockstore.Blockstore
import com.google.android.gms.auth.blockstore.DeleteBytesRequest
import com.google.android.gms.auth.blockstore.RetrieveBytesRequest
import com.google.android.gms.auth.blockstore.StoreBytesData
import com.google.android.gms.tasks.Tasks
import java.util.concurrent.TimeUnit

/**
 * Best-effort cross-install session continuity.
 *
 * The server remains the source of truth. Block Store only preserves the Supabase
 * refresh token so an uninstall/reinstall can resume the same Auth identity.
 */
class BlockStoreSessionStore(
    context: Context
) {
    companion object {
        private const val KEY = "sitebin_supabase_session_v1"
        private const val VERSION = 1
        private const val TIMEOUT_SECONDS = 5L

        private const val HEX = "0123456789abcdef"

        private fun encodeField(value: String): String = buildString {
            for (byte in value.toByteArray(Charsets.UTF_8)) {
                val unsigned = byte.toInt() and 0xFF
                append(HEX[unsigned ushr 4])
                append(HEX[unsigned and 0x0F])
            }
        }

        private fun decodeField(value: String): String {
            if (value.length % 2 != 0) error("Invalid hex payload")
            val bytes = ByteArray(value.length / 2)
            for (index in bytes.indices) {
                val high = Character.digit(value[index * 2], 16)
                val low = Character.digit(value[index * 2 + 1], 16)
                if (high < 0 || low < 0) error("Invalid hex payload")
                bytes[index] = ((high shl 4) or low).toByte()
            }
            return String(bytes, Charsets.UTF_8)
        }

        internal fun encode(refreshToken: String, userId: String?): ByteArray =
            buildString {
                append(VERSION).append('\n')
                append(encodeField(refreshToken)).append('\n')
                append(userId?.let(::encodeField) ?: "")
            }.toByteArray(Charsets.UTF_8)

        internal fun decode(bytes: ByteArray): Session? = runCatching {
            val parts = String(bytes, Charsets.UTF_8).split('\n', limit = 3)
            if (parts.size != 3 || parts[0].toIntOrNull() != VERSION) return@runCatching null
            val refreshToken = decodeField(parts[1]).trim()
            if (refreshToken.isBlank()) return@runCatching null
            val userId = parts[2].takeIf { it.isNotBlank() }?.let(::decodeField)
            Session(refreshToken = refreshToken, userId = userId)
        }.getOrNull()
    }

    private val client by lazy { Blockstore.getClient(context.applicationContext) }

    data class Session(
        val refreshToken: String,
        val userId: String?
    )

    fun load(): Session? = runCatching {
        val response = Tasks.await(
            client.retrieveBytes(
                RetrieveBytesRequest.Builder()
                    .setKeys(listOf(KEY))
                    .build()
            ),
            TIMEOUT_SECONDS,
            TimeUnit.SECONDS
        )
        val bytes = response.blockstoreDataMap[KEY]?.bytes ?: return@runCatching null
        decode(bytes)
    }.getOrNull()

    fun save(refreshToken: String?, userId: String?): Boolean = runCatching {
        val token = refreshToken?.trim().orEmpty()
        if (token.isBlank()) return@runCatching false

        val backup = runCatching {
            Tasks.await(
                client.isEndToEndEncryptionAvailable(),
                TIMEOUT_SECONDS,
                TimeUnit.SECONDS
            )
        }.getOrElse { return@runCatching false }

        Tasks.await(
            client.storeBytes(
                StoreBytesData.Builder()
                    .setKey(KEY)
                    .setBytes(encode(token, userId))
                    .setShouldBackupToCloud(backup)
                    .build()
            ),
            TIMEOUT_SECONDS,
            TimeUnit.SECONDS
        )
        true
    }.getOrDefault(false)

    fun clear(): Boolean = runCatching {
        Tasks.await(
            client.deleteBytes(
                DeleteBytesRequest.Builder()
                    .setKeys(listOf(KEY))
                    .build()
            ),
            TIMEOUT_SECONDS,
            TimeUnit.SECONDS
        )
        true
    }.getOrDefault(false)
}
