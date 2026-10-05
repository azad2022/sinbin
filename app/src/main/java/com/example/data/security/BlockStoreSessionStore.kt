package com.example.data.security

import android.content.Context
import com.google.android.gms.auth.blockstore.Blockstore
import com.google.android.gms.auth.blockstore.RetrieveBytesRequest
import com.google.android.gms.auth.blockstore.StoreBytesData
import com.google.android.gms.tasks.Tasks
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Best-effort cross-install session continuity.
 *
 * The server remains the source of truth. Block Store only preserves the Supabase
 * session credential so an uninstall/reinstall can resume the same Auth identity.
 */
class BlockStoreSessionStore(
    context: Context
) {
    companion object {
        private const val KEY = "sitebin_supabase_session_v1"
        private const val VERSION = 1
        private const val TIMEOUT_SECONDS = 5L
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
        val bytes = response.blockstoreDataList.firstOrNull()?.bytes ?: return null
        val json = JSONObject(String(bytes, Charsets.UTF_8))
        if (json.optInt("version", 0) != VERSION) return null
        val refreshToken = json.optString("refresh_token").trim()
        if (refreshToken.isBlank()) return null
        Session(
            refreshToken = refreshToken,
            userId = json.optString("user_id").takeIf { it.isNotBlank() }
        )
    }.getOrNull()

    fun save(refreshToken: String?, userId: String?): Boolean = runCatching {
        val token = refreshToken?.trim().orEmpty()
        if (token.isBlank()) return false

        val backup = runCatching {
            Tasks.await(
                client.isEndToEndEncryptionAvailable(),
                TIMEOUT_SECONDS,
                TimeUnit.SECONDS
            )
        }.getOrDefault(false)

        val payload = JSONObject()
            .put("version", VERSION)
            .put("refresh_token", token)
            .put("user_id", userId ?: JSONObject.NULL)
            .toString()
            .toByteArray(Charsets.UTF_8)

        Tasks.await(
            client.storeBytes(
                StoreBytesData.Builder()
                    .setKey(KEY)
                    .setBytes(payload)
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
            client.deleteBytes(KEY),
            TIMEOUT_SECONDS,
            TimeUnit.SECONDS
        )
        true
    }.getOrDefault(false)
}
