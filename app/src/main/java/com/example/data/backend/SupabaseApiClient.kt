package com.example.data.backend

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.example.data.model.Campaign
import com.example.data.model.CampaignStatus
import com.example.data.model.CoinTransaction
import com.example.data.model.DurationOption
import com.example.data.model.TransactionType
import com.example.data.model.UserAccount
import com.example.data.model.ViewSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import java.util.concurrent.TimeUnit

/**
 * Production-Grade Supabase Client for SiteBin.
 *
 * Guarantees:
 * 1. Authenticated User Sessions: Real Supabase Auth (JWT) is always acquired. Never falls back to anon key.
 * 2. Unguessable Security: Cryptographically random device secrets (256-bit entropy) instead of deterministic hashes.
 * 3. Session Persistence & Auto-Refresh: Stores access & refresh tokens locally; automatically refreshes expired sessions.
 * 4. Single Source of Truth for Pricing: Dynamically fetches duration_pricing matrix from Supabase database.
 * 5. Strict Server-Authoritative Execution: All mutations execute via PostgreSQL SECURITY DEFINER RPCs.
 */
class SupabaseApiClient(
    private val supabaseUrl: String,
    private val supabasePublishableKey: String,
    private val context: Context? = null
) : ServerAuthoritativeEngine {

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

    private val prefs by lazy {
        context?.getSharedPreferences("sitebin_supabase_session", Context.MODE_PRIVATE)
    }

    // Dynamic Pricing (Single Source of Truth)
    private var _dynamicPricing: List<DurationOption> = listOf(
        DurationOption(seconds = 5, advertiserCost = 5, viewerReward = 3),
        DurationOption(seconds = 10, advertiserCost = 9, viewerReward = 6),
        DurationOption(seconds = 15, advertiserCost = 14, viewerReward = 10, isPopular = true),
        DurationOption(seconds = 30, advertiserCost = 26, viewerReward = 19),
        DurationOption(seconds = 60, advertiserCost = 50, viewerReward = 38)
    )

    override val durationOptions: List<DurationOption>
        get() = _dynamicPricing

    @Volatile
    private var currentUserToken: String? = null

    @Volatile
    private var currentRefreshToken: String? = null

    @Volatile
    private var currentUserId: String? = null

    @Volatile
    private var tokenExpiresAt: Long = 0L

    init {
        // Load persisted session on startup. Sensitive values are encrypted with Android Keystore.
        currentUserToken = getSecureString("access_token")
        currentRefreshToken = getSecureString("refresh_token")
        currentUserId = getSecureString("user_id")
        tokenExpiresAt = getSecureString("token_expires_at")?.toLongOrNull() ?: prefs?.getLong("token_expires_at", 0L) ?: 0L
    }

    /**
     * Dynamically fetches duration pricing from Supabase database (Single Source of Truth).
     */
    override suspend fun fetchDurationPricing(): Result<List<DurationOption>> = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder()
                .url("$supabaseUrl/rest/v1/duration_pricing?select=*&order=duration_seconds.asc")
                .addHeader("apikey", supabasePublishableKey)
                .get()
                .build()

            val response = httpClient.newCall(request).execute()
            val raw = response.body?.string() ?: ""
            if (!response.isSuccessful) {
                return@withContext Result.failure(IOException("Failed to fetch duration pricing: HTTP ${response.code}"))
            }

            val array = JSONArray(raw)
            val list = mutableListOf<DurationOption>()
            for (i in 0 until array.length()) {
                val obj = array.getJSONObject(i)
                list.add(
                    DurationOption(
                        seconds = obj.getInt("duration_seconds"),
                        advertiserCost = obj.getLong("advertiser_cost"),
                        viewerReward = obj.getLong("viewer_reward"),
                        isPopular = obj.optBoolean("is_popular", false)
                    )
                )
            }
            if (list.isNotEmpty()) {
                _dynamicPricing = list
            }
            Result.success(_dynamicPricing)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun initAccount(installId: String, handle: String?): Result<UserAccount> = withContext(Dispatchers.IO) {
        try {
            // 1. Fetch live pricing from Supabase
            fetchDurationPricing()

            // 2. Ensure real authenticated Supabase session
            ensureAuthenticated(installId)

            val body = JSONObject().apply {
                put("p_install_id", installId)
                if (handle != null) put("p_handle", handle)
            }

            val responseJson = callRpc("init_user_account", body)
            val account = parseUserAccount(responseJson, installId)
            currentUserId = account.userId
            saveSession()
            Result.success(account)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun fetchAccount(userId: String): Result<UserAccount> = withContext(Dispatchers.IO) {
        try {
            val token = getValidUserToken()
            val url = "$supabaseUrl/rest/v1/profiles?id=eq.$userId&select=*"
            val request = Request.Builder()
                .url(url)
                .addHeader("apikey", supabasePublishableKey)
                .addHeader("Authorization", "Bearer $token")
                .get()
                .build()

            val response = httpClient.newCall(request).execute()
            val raw = response.body?.string() ?: ""
            val jsonArray = JSONArray(raw)
            if (jsonArray.length() == 0) return@withContext Result.failure(NoSuchElementException("User profile not found"))

            val obj = jsonArray.getJSONObject(0)
            Result.success(parseUserAccount(obj, obj.optString("app_install_id", "")))
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun fetchTransactions(userId: String): Result<List<CoinTransaction>> = withContext(Dispatchers.IO) {
        try {
            val token = getValidUserToken()
            val url = "$supabaseUrl/rest/v1/coin_ledger?user_id=eq.$userId&order=created_at.desc&limit=100"
            val request = Request.Builder()
                .url(url)
                .addHeader("apikey", supabasePublishableKey)
                .addHeader("Authorization", "Bearer $token")
                .get()
                .build()

            val response = httpClient.newCall(request).execute()
            val raw = response.body?.string() ?: ""
            val arr = JSONArray(raw)
            val list = mutableListOf<CoinTransaction>()
            for (i in 0 until arr.length()) {
                val item = arr.getJSONObject(i)
                val typeName = item.optString("transaction_type", "VIEW_REWARD")
                val type = runCatching { TransactionType.valueOf(typeName) }.getOrDefault(TransactionType.VIEW_REWARD)
                list.add(
                    CoinTransaction(
                        id = item.optString("id"),
                        amount = item.optLong("amount"),
                        type = type,
                        description = item.optString("description"),
                        referenceId = item.optString("reference_id", "").ifEmpty { null }
                    )
                )
            }
            Result.success(list)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun fetchCampaigns(userId: String): Result<List<Campaign>> = withContext(Dispatchers.IO) {
        try {
            val token = getValidUserToken()
            val url = "$supabaseUrl/rest/v1/campaigns?owner_id=eq.$userId&select=*&order=created_at.desc"
            val request = Request.Builder()
                .url(url)
                .addHeader("apikey", supabasePublishableKey)
                .addHeader("Authorization", "Bearer $token")
                .get()
                .build()

            val response = httpClient.newCall(request).execute()
            val raw = response.body?.string() ?: ""
            val arr = JSONArray(raw)
            val list = mutableListOf<Campaign>()
            for (i in 0 until arr.length()) {
                val item = arr.getJSONObject(i)
                val statusName = item.optString("status", "ACTIVE")
                val status = runCatching { CampaignStatus.valueOf(statusName) }.getOrDefault(CampaignStatus.ACTIVE)
                list.add(
                    Campaign(
                        id = item.optString("id"),
                        ownerId = item.optString("owner_id"),
                        url = item.optString("url"),
                        domain = item.optString("domain"),
                        durationSeconds = item.optInt("duration_seconds"),
                        targetViews = item.optInt("target_views"),
                        completedViews = item.optInt("completed_views"),
                        costPerView = item.optLong("cost_per_view"),
                        totalBudget = item.optLong("total_budget"),
                        spentBudget = item.optLong("spent_budget"),
                        status = status
                    )
                )
            }
            Result.success(list)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun createCampaign(
        url: String,
        normalizedUrl: String,
        domain: String,
        durationSeconds: Int,
        targetViews: Int,
        callerUserId: String?
    ): Result<Campaign> = withContext(Dispatchers.IO) {
        try {
            val body = JSONObject().apply {
                put("p_url", url)
                put("p_normalized_url", normalizedUrl)
                put("p_domain", domain)
                put("p_duration_seconds", durationSeconds)
                put("p_target_views", targetViews)
            }
            val res = callRpc("create_campaign", body)
            val status = runCatching { CampaignStatus.valueOf(res.optString("status", "ACTIVE")) }.getOrDefault(CampaignStatus.ACTIVE)
            Result.success(
                Campaign(
                    id = res.optString("id"),
                    ownerId = res.optString("owner_id"),
                    url = res.optString("url"),
                    domain = res.optString("domain"),
                    durationSeconds = res.optInt("duration_seconds"),
                    targetViews = res.optInt("target_views"),
                    completedViews = res.optInt("completed_views", 0),
                    costPerView = res.optLong("cost_per_view"),
                    totalBudget = res.optLong("total_budget"),
                    spentBudget = res.optLong("spent_budget", 0),
                    status = status
                )
            )
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun requestViewSession(userId: String): Result<ViewSession?> = withContext(Dispatchers.IO) {
        try {
            val res = callRpc("request_view_session", JSONObject())
            if (res.length() == 0 || !res.has("id")) {
                return@withContext Result.success(null)
            }
            Result.success(
                ViewSession(
                    id = res.getString("id"),
                    campaignId = res.getString("campaign_id"),
                    targetUrl = res.getString("target_url"),
                    domain = res.getString("domain"),
                    requiredDurationSeconds = res.getInt("required_duration_seconds"),
                    rewardCoins = res.getLong("reward_coins"),
                    startedAt = res.optLong("started_at", System.currentTimeMillis())
                )
            )
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun signalContentReady(sessionId: String, callerUserId: String?): Result<Boolean> = withContext(Dispatchers.IO) {
        try {
            val body = JSONObject().apply { put("p_session_id", sessionId) }
            val res = callRpcRaw("signal_content_ready", body)
            Result.success(res.toBoolean())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun completeViewSession(
        sessionId: String,
        idempotencyKey: String,
        callerUserId: String?
    ): Result<Long> = withContext(Dispatchers.IO) {
        try {
            val body = JSONObject().apply {
                put("p_session_id", sessionId)
                put("p_idempotency_key", idempotencyKey)
            }
            val res = callRpc("complete_view_session", body)
            if (res.optBoolean("success", false)) {
                Result.success(res.optLong("reward", 0L))
            } else {
                Result.failure(IllegalStateException("خطا در تایید سرور برای بازدید."))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun cancelViewSession(sessionId: String, callerUserId: String?): Result<Boolean> = withContext(Dispatchers.IO) {
        try {
            val body = JSONObject().apply { put("p_session_id", sessionId) }
            val raw = callRpcRaw("cancel_view_session", body)
            Result.success(raw.trim().equals("true", ignoreCase = true))
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun cancelCampaign(campaignId: String, callerUserId: String?): Result<Long> = withContext(Dispatchers.IO) {
        try {
            val body = JSONObject().apply { put("p_campaign_id", campaignId) }
            val res = callRpc("cancel_campaign", body)
            Result.success(res.optLong("refunded_amount", 0L))
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun pauseCampaign(campaignId: String, callerUserId: String?): Result<Boolean> = withContext(Dispatchers.IO) {
        try {
            val body = JSONObject().apply { put("p_campaign_id", campaignId) }
            val res = callRpcRaw("pause_campaign", body)
            Result.success(res.toBoolean())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun resumeCampaign(campaignId: String, callerUserId: String?): Result<Boolean> = withContext(Dispatchers.IO) {
        try {
            val body = JSONObject().apply { put("p_campaign_id", campaignId) }
            val res = callRpcRaw("resume_campaign", body)
            Result.success(res.toBoolean())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    // =========================================================================
    // Robust User Authentication & Session Lifecycle (No Anon Key Fallback)
    // =========================================================================

    @Synchronized
    private fun getValidUserToken(): String {
        val token = currentUserToken
        val now = System.currentTimeMillis()

        // 1. If active token exists and is valid for at least 60 seconds, use it
        if (!token.isNullOrBlank() && token != supabasePublishableKey && (tokenExpiresAt == 0L || now < (tokenExpiresAt - 60_000L))) {
            return token
        }

        // 2. If token is expiring or expired, refresh session using refresh_token
        val refreshToken = currentRefreshToken
        if (!refreshToken.isNullOrBlank()) {
            val refreshed = refreshSession(refreshToken)
            if (refreshed != null) {
                return refreshed
            }
        }

        // 3. If no session or refresh failed, throw explicit authentication exception (NEVER use anon key!)
        throw IllegalStateException("UNAUTHENTICATED: No valid Supabase user session token found. Call initAccount first.")
    }

    @Synchronized
    private fun ensureAuthenticated(installId: String) {
        val now = System.currentTimeMillis()

        // 1. Valid existing token
        if (!currentUserToken.isNullOrBlank() && currentUserToken != supabasePublishableKey && (tokenExpiresAt == 0L || now < (tokenExpiresAt - 60_000L))) {
            return
        }

        // 2. Try refreshing token if available
        val refreshToken = currentRefreshToken
        if (!refreshToken.isNullOrBlank()) {
            val refreshed = refreshSession(refreshToken)
            if (refreshed != null) {
                return
            }
        }

        // 3. Acquire or generate a high-entropy cryptographically secure random device secret (256-bit)
        val deviceSecret = getOrGenerateDeviceSecret()

        // Construct unique user credentials bound to this private device secret
        val cleanInstall = installId.filter { it.isLetterOrDigit() }.ifEmpty { "dev" }
        val email = "sitebin_${cleanInstall.take(12)}_${deviceSecret.take(12)}@sitebin.internal"
        val password = "SB_${deviceSecret}_Auth9!"

        val authBody = JSONObject().apply {
            put("email", email)
            put("password", password)
        }.toString().toRequestBody(jsonMediaType)

        // 4. Try Token Login first (fast path for existing account; avoids hitting signup rate limits)
        val tokenUrl = "$supabaseUrl/auth/v1/token?grant_type=password"
        val tokenReq = Request.Builder()
            .url(tokenUrl)
            .addHeader("apikey", supabasePublishableKey)
            .post(authBody)
            .build()

        val tokenRes = httpClient.newCall(tokenReq).execute()
        val tokenRaw = tokenRes.body?.string() ?: ""
        if (tokenRes.isSuccessful) {
            handleAuthSuccess(tokenRaw)
            return
        }

        // 5. If login fails (user does not exist yet), try Signup
        val signupReq = Request.Builder()
            .url("$supabaseUrl/auth/v1/signup")
            .addHeader("apikey", supabasePublishableKey)
            .post(authBody)
            .build()

        val signupRes = httpClient.newCall(signupReq).execute()
        val signupRaw = signupRes.body?.string() ?: ""
        if (signupRes.isSuccessful) {
            handleAuthSuccess(signupRaw)
            if (!currentUserToken.isNullOrBlank()) return
        }

        // 6. Strict Failure: do not create an anonymous Supabase user and do not
        // fall back to the publishable key. SiteBin financial RPCs require a
        // non-anonymous authenticated session.
        throw IllegalStateException(
            "SUPABASE_AUTH_FAILED: Unable to create or authenticate a permanent Supabase user session. Ensure email/password sign-in is enabled and email confirmation is configured for this app."
        )
    }

    private fun refreshSession(refreshToken: String): String? {
        try {
            val body = JSONObject().apply {
                put("refresh_token", refreshToken)
            }.toString().toRequestBody(jsonMediaType)

            val req = Request.Builder()
                .url("$supabaseUrl/auth/v1/token?grant_type=refresh_token")
                .addHeader("apikey", supabasePublishableKey)
                .post(body)
                .build()

            val res = httpClient.newCall(req).execute()
            val raw = res.body?.string() ?: ""
            if (res.isSuccessful) {
                handleAuthSuccess(raw)
                return currentUserToken
            }
        } catch (_: Exception) {}
        return null
    }

    private fun handleAuthSuccess(responseJson: String) {
        val json = JSONObject(responseJson)
        val token = json.optString("access_token").ifEmpty { null }
        val refresh = json.optString("refresh_token").ifEmpty { null }
        val expiresIn = json.optLong("expires_in", 3600L) // Default 1 hour
        val user = json.optJSONObject("user")
        val uid = user?.optString("id")

        if (token != null) {
            currentUserToken = token
            currentRefreshToken = refresh ?: currentRefreshToken
            currentUserId = uid ?: currentUserId
            tokenExpiresAt = System.currentTimeMillis() + (expiresIn * 1000L)
            saveSession()
        }
    }

    private fun getOrGenerateDeviceSecret(): String {
        getSecureString("device_secret")?.let { return it }
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        val newSecret = Base64.encodeToString(bytes, Base64.NO_WRAP or Base64.URL_SAFE)
        putSecureString("device_secret", newSecret)
        return newSecret
    }

    private fun saveSession() {
        putSecureString("access_token", currentUserToken)
        putSecureString("refresh_token", currentRefreshToken)
        putSecureString("user_id", currentUserId)
        putSecureString("token_expires_at", tokenExpiresAt.toString())
    }

    private fun getKeystoreKey(): SecretKey {
        val alias = "sitebin_session_aes256"
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }

        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        keyGenerator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return keyGenerator.generateKey()
    }

    private fun encryptSecret(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getKeystoreKey())
        val iv = cipher.iv
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(iv + ciphertext, Base64.NO_WRAP or Base64.URL_SAFE)
    }

    private fun decryptSecret(encoded: String): String? {
        return runCatching {
            val payload = Base64.decode(encoded, Base64.NO_WRAP or Base64.URL_SAFE)
            if (payload.size <= 12) return@runCatching null
            val iv = payload.copyOfRange(0, 12)
            val ciphertext = payload.copyOfRange(12, payload.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, getKeystoreKey(), GCMParameterSpec(128, iv))
            String(cipher.doFinal(ciphertext), Charsets.UTF_8)
        }.getOrNull()
    }

    private fun getSecureString(key: String): String? {
        val p = prefs ?: return null
        p.getString("enc_$key", null)?.let { return decryptSecret(it) }

        // One-time migration from the previous plaintext SharedPreferences implementation.
        val legacy = p.getString(key, null)
        if (legacy != null) {
            putSecureString(key, legacy)
            p.edit().remove(key).apply()
            return legacy
        }
        return null
    }

    private fun putSecureString(key: String, value: String?) {
        val p = prefs ?: return
        if (value == null) {
            p.edit().remove("enc_$key").remove(key).apply()
        } else {
            p.edit().putString("enc_$key", encryptSecret(value)).remove(key).apply()
        }
    }

    private fun callRpc(functionName: String, body: JSONObject): JSONObject {
        val raw = callRpcRaw(functionName, body)
        return if (raw.isBlank() || raw == "null") JSONObject() else JSONObject(raw)
    }

    private fun callRpcRaw(functionName: String, body: JSONObject, isRetry: Boolean = false): String {
        val token = getValidUserToken()
        val requestBody = body.toString().toRequestBody(jsonMediaType)
        val request = Request.Builder()
            .url("$supabaseUrl/rest/v1/rpc/$functionName")
            .addHeader("apikey", supabasePublishableKey)
            .addHeader("Authorization", "Bearer $token")
            .post(requestBody)
            .build()

        val response = httpClient.newCall(request).execute()
        val raw = response.body?.string() ?: ""

        // If 401 Unauthorized occurs, attempt a proactive token refresh and retry ONCE
        if ((response.code == 401 || response.code == 403) && !isRetry) {
            val refresh = currentRefreshToken
            if (!refresh.isNullOrBlank()) {
                val newToken = refreshSession(refresh)
                if (newToken != null) {
                    return callRpcRaw(functionName, body, isRetry = true)
                }
            }
        }

        if (!response.isSuccessful) {
            val errObj = runCatching { JSONObject(raw) }.getOrNull()
            val errMsg = errObj?.optString("message") ?: "Server error ${response.code}"
            throw IOException(errMsg)
        }
        return raw
    }

    private fun parseUserAccount(json: JSONObject, installId: String): UserAccount {
        return UserAccount(
            userId = json.optString("id", json.optString("user_handle", "user")),
            appInstallId = installId,
            availableCoins = json.optLong("available_coins", 0L),
            reservedCoins = json.optLong("reserved_coins", 0L),
            lifetimeEarned = json.optLong("lifetime_earned", 0L),
            lifetimeSpent = json.optLong("lifetime_spent", 0L),
            trustScore = json.optDouble("trust_score", 100.0).toFloat(),
            completedViewsCount = json.optInt("completed_views_count", 0),
            receivedViewsCount = json.optInt("received_views_count", 0)
        )
    }
}