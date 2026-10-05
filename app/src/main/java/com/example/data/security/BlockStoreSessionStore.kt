package com.example.data.security

import android.content.Context
import com.google.android.gms.auth.blockstore.Blockstore
import com.google.android.gms.auth.blockstore.DeleteBytesRequest
import com.google.android.gms.auth.blockstore.RetrieveBytesRequest
import com.google.android.gms.auth.blockstore.StoreBytesData
import com.google.android.gms.tasks.Tasks
import org.json.JSONObject
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

        internal fun encode(refreshToken: String, userId: String?): ByteArray =
            JSONObject()
                .put("version", VERSION)
                .put("refresh_token", refreshToken)
                .put("user_id", userId ?: JSONObject.NULL)
                .toString()
                .toByteArray(Charsets.UTF_8)

        internal fun decode(bytes: ByteArray): Session? = runCatching {
            val json = JSONObject(String(bytes, Charsets.UTF_8))
            if (json.optInt("version", 0) != VERSION) return@runCatching null
            val refreshToken = json.optString("refresh_token").trim()
            if (refreshToken.isBlank()) return@runCatching null
            Session(
                refreshToken = refreshToken,
                userId = json.optString("user_id").takeIf { it.isNotBlank() }
            )
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
