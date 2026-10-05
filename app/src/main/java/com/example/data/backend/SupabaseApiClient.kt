package com.example.data.backend

import android.content.Context
import android.os.SystemClock
import com.example.BuildConfig
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.example.data.model.AutoViewActivationResult
import com.example.data.model.AutoViewStatus
import com.example.data.model.Campaign
import com.example.data.model.CampaignStatus
import com.example.data.model.CoinTransaction
import com.example.data.model.CoinTransferResult
import com.example.data.model.DailyBonusResult
import com.example.data.model.DurationOption
import com.example.data.model.TransactionType
import com.example.data.model.UserAccount
import com.example.data.model.ViewCompletionResult
import com.example.data.model.ViewSession
import com.example.data.security.BlockStoreSessionStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Locale
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import java.util.concurrent.TimeUnit

/**
 * Raised when the server-side SiteBin rate limiter returns HTTP 429.
 *
 * retryAfterSeconds is authoritative guidance from the server and is used by
 * callers to avoid immediate retry storms.
 */
class RateLimitException(
    val retryAfterSeconds: Long,
    message: String
) : IOException(message)

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

    // The Edge Function itself has a 6s server-side fetch deadline. Keep the client
    // bounded as well so a stalled function/network path cannot leave the UI hanging
    // for the generic 20s REST read timeout.
    private val preflightHttpClient = httpClient.newBuilder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .callTimeout(12, TimeUnit.SECONDS)
        .build()

    private val prefs by lazy {
        context?.getSharedPreferences("sitebin_supabase_session", Context.MODE_PRIVATE)
    }

    private val blockStoreSessionStore by lazy { context?.let(::BlockStoreSessionStore) }
    private val authenticationMutex = Mutex()

    // Dynamic Pricing (Single Source of Truth)
    private var _dynamicPricing: List<DurationOption> = listOf(
        DurationOption(seconds = 5, advertiserCost = 5, viewerReward = 3),
        DurationOption(seconds = 10, advertiserCost = 9, viewerReward = 6),
        DurationOption(seconds = 15, advertiserCost = 14, viewerReward = 10, isPopular = true),
        DurationOption(seconds = 30, advertiserCost = 26, viewerReward = 19),
        DurationOption(seconds = 60, advertiserCost = 50, viewerReward = 38)
    )

    @Volatile
    private var pricingFetchedAtMs: Long = 0L

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
        val now = SystemClock.elapsedRealtime()
        if (_dynamicPricing.isNotEmpty() && now - pricingFetchedAtMs < 60_000L) {
            return@withContext Result.success(_dynamicPricing)
        }

        try {
            val startedAt = SystemClock.elapsedRealtime()
            val request = Request.Builder()
                .url("$supabaseUrl/rest/v1/duration_pricing?select=*&order=duration_seconds.asc")
                .addHeader("apikey", supabasePublishableKey)
                .get()
                .build()

            val response = httpClient.newCall(request).execute()
            val elapsedMs = SystemClock.elapsedRealtime() - startedAt
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
                        isPopular = obj.optBoolean("is_popular", false),
                        keywordAdvertiserCost = obj.optLong(
                            "keyword_advertiser_cost",
                            obj.getLong("advertiser_cost") * 3L
                        )
                    )
                )
            }
            if (list.isNotEmpty()) {
                _dynamicPricing = list
                pricingFetchedAtMs = SystemClock.elapsedRealtime()
            }
            debugPerformance("pricing", elapsedMs)
            Result.success(_dynamicPricing)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun initAccount(
        evidence: DeviceEvidence,
        handle: String?
    ): Result<UserAccount> = withContext(Dispatchers.IO) {
        try {
            // Authentication establishes the application session. Welcome Bonus
            // eligibility is decided independently by PostgreSQL using device evidence.
            ensureAuthenticated(evidence.installId)

            val body = JSONObject().apply {
                put("p_install_id", evidence.installId)
                put("p_handle", handle ?: JSONObject.NULL)
                put("p_android_id", evidence.androidId ?: JSONObject.NULL)
                put("p_app_set_id", evidence.appSetId ?: JSONObject.NULL)
                put("p_app_set_scope", evidence.appSetScope ?: JSONObject.NULL)
                put("p_installation_key_fingerprint", evidence.installationKeyFingerprint ?: JSONObject.NULL)
            }

            val responseJson = callRpc("init_user_account", body)
            val account = parseUserAccount(responseJson, evidence.installId)
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

    override suspend fun claimDailyBonus(evidence: DeviceEvidence, callerUserId: String?): Result<DailyBonusResult> = withContext(Dispatchers.IO) {
        try {
            val body = JSONObject().apply {
                put("p_android_id", evidence.androidId ?: JSONObject.NULL)
                put("p_app_set_id", evidence.appSetId ?: JSONObject.NULL)
                put("p_app_set_scope", evidence.appSetScope ?: JSONObject.NULL)
                put("p_installation_key_fingerprint", evidence.installationKeyFingerprint ?: JSONObject.NULL)
            }
            val res = callRpc("claim_daily_bonus", body)
            val amount = res.optLong("amount", 0L)
            if (res.optBoolean("granted", false) && amount <= 0L) {
                return@withContext Result.failure(
                    IllegalStateException("INVALID_DAILY_BONUS_RESPONSE: Granted bonus must contain a positive amount")
                )
            }
            Result.success(
                DailyBonusResult(
                    granted = res.optBoolean("granted", false),
                    amount = amount,
                    grantDate = res.optString("grant_date", ""),
                    reason = res.optString("reason", "").ifBlank { null },
                    grantId = res.optString("grant_id", "").ifBlank { null },
                    grantedAt = if (res.has("granted_at")) {
                        res.optLong("granted_at", 0L).takeIf { it > 0L }
                    } else {
                        null
                    }
                )
            )
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun getAutoViewStatus(callerUserId: String?): Result<AutoViewStatus> = withContext(Dispatchers.IO) {
        try {
            val res = callRpc("get_auto_view_status", JSONObject())
            val expiresAt = if (res.has("expires_at") && !res.isNull("expires_at")) {
                res.optLong("expires_at", 0L).takeIf { it > 0L }
            } else {
                null
            }
            val active = res.optBoolean("active", false)
            Result.success(AutoViewStatus(active = active, expiresAt = expiresAt))
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun activateAutoView(
        idempotencyKey: String,
        callerUserId: String?
    ): Result<AutoViewActivationResult> = withContext(Dispatchers.IO) {
        try {
            val cleanKey = idempotencyKey.trim()
            if (cleanKey.length < 16 || cleanKey.length > 128 || cleanKey.any(Char::isWhitespace)) {
                return@withContext Result.failure(
                    IllegalArgumentException("INVALID_IDEMPOTENCY_KEY: Invalid auto-view activation request key")
                )
            }

            val body = JSONObject().apply {
                put("p_idempotency_key", cleanKey)
            }
            val res = callRpc("activate_auto_view", body)
            if (!res.optBoolean("success", false) || !res.optBoolean("activated", false)) {
                return@withContext Result.failure(
                    IllegalStateException("فعال‌سازی بازدید خودکار توسط سرور تایید نشد.")
                )
            }

            val expiresAt = if (res.has("expires_at") && !res.isNull("expires_at")) {
                res.optLong("expires_at", 0L).takeIf { it > 0L }
            } else {
                null
            }

            Result.success(
                AutoViewActivationResult(
                    activated = true,
                    charged = res.optBoolean("charged", false),
                    amount = res.optLong("amount", 0L),
                    expiresAt = expiresAt,
                    availableCoins = res.optLong("available_coins", 0L),
                    purchaseId = res.optString("purchase_id", "").ifBlank { null }
                )
            )
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

    override suspend fun transferCoins(
        recipientHandle: String,
        amount: Long,
        idempotencyKey: String,
        note: String?,
        callerUserId: String?
    ): Result<CoinTransferResult> = withContext(Dispatchers.IO) {
        try {
            val cleanHandle = recipientHandle.trim()
            if (cleanHandle.isBlank()) {
                return@withContext Result.failure(IllegalArgumentException("شناسه کاربری مقصد را وارد کنید."))
            }
            if (amount <= 0L) {
                return@withContext Result.failure(IllegalArgumentException("مقدار انتقال باید بیشتر از صفر باشد."))
            }

            val body = JSONObject().apply {
                put("p_recipient_handle", cleanHandle)
                put("p_amount", amount)
                put("p_idempotency_key", idempotencyKey)
                note?.trim()?.takeIf { it.isNotBlank() }?.let { put("p_note", it) }
            }

            val res = callRpc("transfer_coins", body)
            Result.success(
                CoinTransferResult(
                    transferId = res.getString("transfer_id"),
                    recipientHandle = res.getString("recipient_handle"),
                    amount = res.getLong("amount"),
                    note = res.optString("note", "").ifBlank { null },
                    createdAt = parseTimestamp(res.optString("created_at"))
                )
            )
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
                        keyword = item.optString("keyword", "").ifBlank { null },
                        durationSeconds = item.optInt("duration_seconds"),
                        targetViews = item.optInt("target_views"),
                        completedViews = item.optInt("completed_views"),
                        costPerView = item.optLong("cost_per_view"),
                        totalBudget = item.optLong("total_budget"),
                        spentBudget = item.optLong("spent_budget"),
                        resolverStatus = item.optString("resolver_status", "NOT_REQUIRED"),
                        status = status
                    )
                )
            }
            Result.success(list)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun preflightCampaignUrl(url: String): Result<WebsitePreflightResult> = withContext(Dispatchers.IO) {
        try {
            val cleanUrl = url.trim()
            val body = JSONObject().apply {
                put("url", cleanUrl)
            }.toString().toRequestBody(jsonMediaType)

            fun execute(token: String): Triple<Int, String, String?> {
                val request = Request.Builder()
                    .url("$" + "{supabaseUrl}/functions/v1/campaign-url-preflight")
                    .addHeader("apikey", supabasePublishableKey)
                    .addHeader("Authorization", "Bearer " + token)
                    .addHeader("Content-Type", "application/json")
                    .post(body)
                    .build()

                preflightHttpClient.newCall(request).execute().use { response ->
                    return Triple(response.code, response.body?.string().orEmpty(), response.header("Retry-After"))
                }
            }

            var token = getValidUserToken()
            var result = execute(token)
            var status = result.first
            var raw = result.second
            var retryAfterHeader = result.third

            if ((status == 401 || status == 403) && !currentRefreshToken.isNullOrBlank()) {
                val refreshed = refreshSession(currentRefreshToken!!)
                if (refreshed != null) {
                    token = refreshed
                    result = execute(token)
                    status = result.first
                    raw = result.second
                    retryAfterHeader = result.third
                }
            }

            if (status == 429) {
                val obj = runCatching { JSONObject(raw) }.getOrNull()
                val retryAfterBody = obj?.optLong("retry_after_seconds", 0L) ?: 0L
                val retryAfterSeconds = maxOf(
                    1L,
                    retryAfterHeader?.trim()?.toLongOrNull() ?: 0L,
                    retryAfterBody
                )
                throw RateLimitException(
                    retryAfterSeconds = retryAfterSeconds,
                    message = (obj?.optString("message")?.takeIf { it.isNotBlank() }
                        ?: "تعداد بررسی‌های آدرس شما بیش از حد مجاز است.") +
                        " لطفاً " + retryAfterSeconds + " ثانیه دیگر دوباره تلاش کنید."
                )
            }

            if (status !in 200..299) {
                val obj = runCatching { JSONObject(raw) }.getOrNull()
                val code = obj?.optString("code", "PREFLIGHT_FAILED") ?: "PREFLIGHT_FAILED"
                val message = obj?.optString("message", "بررسی سایت ناموفق بود.")
                    ?: "بررسی سایت ناموفق بود."
                throw IOException(code + ": " + message)
            }

            val json = JSONObject(raw)
            val diagnosticsJson = json.optJSONArray("diagnostics")
            val diagnostics = buildList {
                if (diagnosticsJson != null) {
                    for (i in 0 until diagnosticsJson.length()) {
                        val item = diagnosticsJson.optJSONObject(i) ?: continue
                        val severity = when (item.optString("severity").uppercase(Locale.ROOT)) {
                            "WARNING" -> WebsiteDiagnosticSeverity.WARNING
                            "BLOCK" -> WebsiteDiagnosticSeverity.BLOCK
                            else -> WebsiteDiagnosticSeverity.INFO
                        }
                        add(
                            WebsiteDiagnostic(
                                code = item.optString("code", "UNKNOWN"),
                                severity = severity,
                                message = item.optString("message", "")
                            )
                        )
                    }
                }
            }

            val expiresAtEpochMs = json.optLong("expires_at_epoch_ms", 0L)
                .takeIf { it > 0L }
                ?: parseTimestamp(json.optString("expires_at", ""))

            Result.success(
                WebsitePreflightResult(
                    sourceUrl = json.optString("source_url", cleanUrl),
                    normalizedUrl = json.getString("normalized_url"),
                    domain = json.getString("domain"),
                    finalUrl = json.getString("final_url"),
                    httpStatus = json.optInt("http_status", 0),
                    redirectCount = json.optInt("redirect_count", 0),
                    responseMs = json.optLong("response_ms", 0L),
                    contentType = json.optString("content_type", "").ifBlank { null },
                    contentLength = if (json.has("content_length") && !json.isNull("content_length")) {
                        json.optLong("content_length")
                    } else {
                        null
                    },
                    viewerCompatibility = when (
                        json.optString("viewer_compatibility", "INCOMPATIBLE").uppercase(Locale.ROOT)
                    ) {
                        "COMPATIBLE" -> WebsiteViewerCompatibility.COMPATIBLE
                        "NEEDS_ATTENTION" -> WebsiteViewerCompatibility.NEEDS_ATTENTION
                        else -> WebsiteViewerCompatibility.INCOMPATIBLE
                    },
                    qualityScore = json.optInt("quality_score", 0).coerceIn(0, 100),
                    diagnostics = diagnostics,
                    expiresAtEpochMs = expiresAtEpochMs,
                    preflightToken = json.getString("preflight_token")
                )
            )
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
        keyword: String?,
        callerUserId: String?,
        preflightToken: String?
    ): Result<Campaign> = withContext(Dispatchers.IO) {
        try {
            val body = JSONObject().apply {
                put("p_url", url)
                put("p_normalized_url", normalizedUrl)
                put("p_domain", domain)
                put("p_duration_seconds", durationSeconds)
                put("p_target_views", targetViews)
                keyword?.trim()?.takeIf { it.isNotBlank() }?.let { put("p_keyword", it) }
                preflightToken?.trim()?.takeIf { it.isNotBlank() }?.let { put("p_preflight_token", it) }
            }
            val res = callRpc("create_campaign", body)
            val status = runCatching { CampaignStatus.valueOf(res.optString("status", "ACTIVE")) }.getOrDefault(CampaignStatus.ACTIVE)
            Result.success(
                Campaign(
                    id = res.optString("id"),
                    ownerId = res.optString("owner_id"),
                    url = res.optString("url"),
                    domain = res.optString("domain"),
                    keyword = res.optString("keyword", "").ifBlank { null },
                    durationSeconds = res.optInt("duration_seconds"),
                    targetViews = res.optInt("target_views"),
                    completedViews = res.optInt("completed_views", 0),
                    costPerView = res.optLong("cost_per_view"),
                    totalBudget = res.optLong("total_budget"),
                    spentBudget = res.optLong("spent_budget", 0),
                    resolverStatus = res.optString("resolver_status", "NOT_REQUIRED"),
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
                    keyword = res.optString("keyword", "").ifBlank { null },
                    requiredDurationSeconds = res.getInt("required_duration_seconds"),
                    rewardCoins = res.getLong("reward_coins"),
                    startedAt = res.optLong("started_at", System.currentTimeMillis())
                )
            )
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun resolveCampaignTarget(campaignId: String): Result<String> = withContext(Dispatchers.IO) {
        try {
            val token = getValidUserToken()
            val body = JSONObject().apply {
                put("campaign_id", campaignId)
            }.toString().toRequestBody(jsonMediaType)

            val request = Request.Builder()
                .url("${supabaseUrl}/functions/v1/resolve-campaign-target")
                .addHeader("apikey", supabasePublishableKey)
                .addHeader("Authorization", "Bearer $token")
                .addHeader("Content-Type", "application/json")
                .post(body)
                .build()

            val response = httpClient.newCall(request).execute()
            val raw = response.body?.string() ?: ""

            if ((response.code == 401 || response.code == 403) && !currentRefreshToken.isNullOrBlank()) {
                val refreshed = refreshSession(currentRefreshToken!!)
                if (refreshed != null) {
                    val retryRequest = Request.Builder()
                        .url("${supabaseUrl}/functions/v1/resolve-campaign-target")
                        .addHeader("apikey", supabasePublishableKey)
                        .addHeader("Authorization", "Bearer $refreshed")
                        .addHeader("Content-Type", "application/json")
                        .post(body)
                        .build()
                    val retry = httpClient.newCall(retryRequest).execute()
                    val retryRaw = retry.body?.string() ?: ""
                    if (!retry.isSuccessful) {
                        val errorJson = runCatching { JSONObject(retryRaw) }.getOrNull()
                        val code = errorJson?.optString("code", "RESOLVER_FAILED") ?: "RESOLVER_FAILED"
                        val message = errorJson?.optString("message", "Keyword target resolution failed")
                            ?: "Keyword target resolution failed"
                        throw IOException("${code}: $message")
                    }
                    return@withContext Result.success(
                        JSONObject(retryRaw).getString("resolved_target_url")
                    )
                }
            }

            if (!response.isSuccessful) {
                val errorJson = runCatching { JSONObject(raw) }.getOrNull()
                val code = errorJson?.optString("code", "RESOLVER_FAILED") ?: "RESOLVER_FAILED"
                val message = errorJson?.optString("message", "Keyword target resolution failed")
                    ?: "Keyword target resolution failed"
                throw IOException("${code}: $message")
            }

            Result.success(JSONObject(raw).getString("resolved_target_url"))
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
    ): Result<ViewCompletionResult> = withContext(Dispatchers.IO) {
        try {
            val body = JSONObject().apply {
                put("p_session_id", sessionId)
                put("p_idempotency_key", idempotencyKey)
            }
            val startedAt = SystemClock.elapsedRealtime()
            val res = callRpc("complete_view_session", body)
            val elapsedMs = SystemClock.elapsedRealtime() - startedAt
            if (res.optBoolean("success", false)) {
                debugPerformance("complete_view_session", elapsedMs)
                Result.success(
                    ViewCompletionResult(
                        reward = res.optLong("reward", 0L),
                        availableCoins = res.optLong("available_coins", 0L),
                        lifetimeEarned = res.optLong("lifetime_earned", 0L),
                        completedViewsCount = res.optInt("completed_views_count", 0),
                        campaignCompleted = res.optBoolean("campaign_completed", false),
                        alreadyCompleted = res.optBoolean("already_completed", false)
                    )
                )
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

    private suspend fun ensureAuthenticated(installId: String) = authenticationMutex.withLock {
        val now = System.currentTimeMillis()

        // 1. Valid existing token
        if (!currentUserToken.isNullOrBlank() && currentUserToken != supabasePublishableKey && (tokenExpiresAt == 0L || now < (tokenExpiresAt - 60_000L))) {
            return@withLock
        }

        // 2. Try refreshing the locally persisted session first.
        val refreshToken = currentRefreshToken
        if (!refreshToken.isNullOrBlank()) {
            val refreshed = refreshSession(refreshToken)
            if (refreshed != null) {
                return@withLock
            }
        }

        // 3. On a reinstall, restore the previous Supabase session from Block Store
        // before ever creating a new Auth user. This preserves the canonical Auth UID,
        // profile, campaigns and ledger without rewriting financial history.
        val restored = blockStoreSessionStore?.load()
        if (restored != null) {
            currentUserToken = null
            currentUserId = restored.userId
            currentRefreshToken = restored.refreshToken
            when (refreshSessionOutcome(restored.refreshToken)) {
                RefreshOutcome.SUCCESS -> return@withLock
                RefreshOutcome.INVALID -> {
                    // A revoked session must not trap the app forever. Clear only the
                    // invalid recovery token, then allow normal first-account signup.
                    val store = blockStoreSessionStore
                    store?.clear()
                    currentRefreshToken = null
                    currentUserId = null
                }
                RefreshOutcome.TRANSIENT -> {
                    // Never create a second account merely because the network/Auth
                    // service is temporarily unavailable after a restore.
                    throw IOException("AUTH_RESTORE_UNAVAILABLE: Saved account could not be restored right now.")
                }
            }
        }

        // 4. Acquire or generate a high-entropy cryptographically secure random device secret (256-bit).
        // Keep the email stable for existing installations, but never build a password
        // longer than Supabase Auth's 72-character limit.
        val deviceSecret = getOrGenerateDeviceSecret()
        val cleanInstall = installId.filter { it.isLetterOrDigit() }.ifEmpty { "dev" }
        val email = "sitebin_${cleanInstall.take(12)}_${deviceSecret.take(12)}@sitebin.internal"
        val legacyPassword = "SB_${deviceSecret}_Auth9!"
        val derivedPassword = AuthCredentialPolicy.buildDerivedDevicePassword(deviceSecret)

        // 4. Preserve compatibility with credentials created by the previous client.
        var loginStatus = 0
        run {
            val authBody = JSONObject().apply {
                put("email", email)
                put("password", legacyPassword)
            }.toString().toRequestBody(jsonMediaType)
            val tokenRes = httpClient.newCall(
                Request.Builder()
                    .url("$supabaseUrl/auth/v1/token?grant_type=password")
                    .addHeader("apikey", supabasePublishableKey)
                    .post(authBody)
                    .build()
            ).execute().also { loginStatus = it.code }
            val tokenRaw = tokenRes.body?.string() ?: ""
            if (tokenRes.isSuccessful) {
                handleAuthSuccess(tokenRaw)
                return
            }
        }

        // 5. Support the new bounded credential without breaking older installations.
        if (derivedPassword != legacyPassword) {
            val authBody = JSONObject().apply {
                put("email", email)
                put("password", derivedPassword)
            }.toString().toRequestBody(jsonMediaType)
            val tokenRes = httpClient.newCall(
                Request.Builder()
                    .url("$supabaseUrl/auth/v1/token?grant_type=password")
                    .addHeader("apikey", supabasePublishableKey)
                    .post(authBody)
                    .build()
            ).execute().also { loginStatus = it.code }
            val raw = tokenRes.body?.string() ?: ""
            if (tokenRes.isSuccessful) {
                handleAuthSuccess(raw)
                return
            }
        }

        // 6. New signups always use the bounded password.
        val signupBody = JSONObject().apply {
            put("email", email)
            put("password", derivedPassword)
        }.toString().toRequestBody(jsonMediaType)

        val signupRes = httpClient.newCall(
            Request.Builder()
                .url("$supabaseUrl/auth/v1/signup")
                .addHeader("apikey", supabasePublishableKey)
                .post(signupBody)
                .build()
        ).execute()
        val signupStatus = signupRes.code
        val signupRaw = signupRes.body?.string() ?: ""
        if (signupRes.isSuccessful) {
            handleAuthSuccess(signupRaw)
            if (!currentUserToken.isNullOrBlank()) return
        }

        // 7. Strict Failure: never use the publishable key as a user identity.
        // Status codes make the Debug startup error actionable without exposing credentials.
        throw IllegalStateException(
            "SUPABASE_AUTH_FAILED: login HTTP $loginStatus; signup HTTP $signupStatus"
        )
    }

    private enum class RefreshOutcome { SUCCESS, INVALID, TRANSIENT }

    private fun refreshSessionOutcome(refreshToken: String): RefreshOutcome {
        return try {
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
                RefreshOutcome.SUCCESS
            } else if (res.code == 400 && run {
                val lower = raw.lowercase(Locale.ROOT)
                lower.contains("invalid_grant") ||
                    lower.contains("refresh_token_not_found") ||
                    lower.contains("invalid refresh token") ||
                    lower.contains("refresh token not found")
            }) {
                RefreshOutcome.INVALID
            } else {
                RefreshOutcome.TRANSIENT
            }
        } catch (_: Exception) {
            RefreshOutcome.TRANSIENT
        }
    }

    private fun refreshSession(refreshToken: String): String? =
        refreshSessionOutcome(refreshToken).takeIf { it == RefreshOutcome.SUCCESS }?.let { currentUserToken }

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

        // Best-effort external session continuity. Failure here must never change
        // the authoritative Supabase session or financial state.
        blockStoreSessionStore?.save(currentRefreshToken, currentUserId)
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

        if (response.code == 429) {
            val errObj = runCatching { JSONObject(raw) }.getOrNull()
            val details = errObj?.optString("details", "").orEmpty()

            val bodyRetryAfter = runCatching {
                JSONObject(details).optLong("retry_after_seconds", 0L)
            }.getOrDefault(0L)

            val headerRetryAfter = response.header("Retry-After")
                ?.trim()
                ?.toLongOrNull()
                ?: 0L

            val retryAfterSeconds = maxOf(
                1L,
                headerRetryAfter,
                bodyRetryAfter
            )

            val serverMessage = errObj?.optString("message")
                ?.takeIf { it.isNotBlank() }
                ?: "تعداد درخواست‌های شما بیش از حد مجاز است."

            throw RateLimitException(
                retryAfterSeconds = retryAfterSeconds,
                message = "$serverMessage لطفاً ${retryAfterSeconds} ثانیه دیگر دوباره تلاش کنید."
            )
        }

        if (!response.isSuccessful) {
            val errObj = runCatching { JSONObject(raw) }.getOrNull()
            val errMsg = errObj?.optString("message") ?: "Server error ${response.code}"
            throw IOException(errMsg)
        }
        return raw
    }

    private fun debugPerformance(operation: String, elapsedMs: Long) {
        if (BuildConfig.DEBUG) {
            android.util.Log.d("SiteBinPerf", "operation=$operation elapsedMs=$elapsedMs")
        }
    }

    private fun parseTimestamp(raw: String): Long {
        val value = raw.trim()
        if (value.isBlank()) return System.currentTimeMillis()
        val formats = listOf(
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXX"
        )
        for (pattern in formats) {
            runCatching {
                return SimpleDateFormat(pattern, Locale.US).parse(value)?.time
                    ?: System.currentTimeMillis()
            }
        }
        return System.currentTimeMillis()
    }

    private fun parseUserAccount(json: JSONObject, installId: String): UserAccount {
        return UserAccount(
            userId = json.optString("id", json.optString("user_handle", "user")),
            userHandle = json.optString("user_handle", ""),
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