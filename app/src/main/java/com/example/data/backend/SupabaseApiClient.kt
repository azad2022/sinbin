package com.example.data.backend

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
import java.util.concurrent.TimeUnit

/**
 * Real Supabase Client connecting to Supabase Auth & PostgreSQL RPC.
 * Enforces Server-Authoritative execution:
 * - Uses Supabase Anon Key and User Bearer Token (JWT).
 * - Never includes or requests Service Role keys.
 * - All coin and campaign operations route through PostgreSQL RPC functions.
 */
class SupabaseApiClient(
    private val supabaseUrl: String,
    private val supabaseAnonKey: String
) : ServerAuthoritativeEngine {

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

    override val durationOptions: List<DurationOption> = listOf(
        DurationOption(seconds = 5, advertiserCost = 5, viewerReward = 3),
        DurationOption(seconds = 10, advertiserCost = 9, viewerReward = 6),
        DurationOption(seconds = 15, advertiserCost = 14, viewerReward = 10, isPopular = true),
        DurationOption(seconds = 30, advertiserCost = 26, viewerReward = 19),
        DurationOption(seconds = 60, advertiserCost = 50, viewerReward = 38)
    )

    private var currentUserToken: String? = null
    private var currentUserId: String? = null

    override suspend fun initAccount(installId: String, handle: String?): Result<UserAccount> = withContext(Dispatchers.IO) {
        try {
            // Sign in or sign up anonymously
            ensureAuthenticated(installId)

            val body = JSONObject().apply {
                put("p_install_id", installId)
                if (handle != null) put("p_handle", handle)
            }

            val responseJson = callRpc("init_user_account", body)
            val account = parseUserAccount(responseJson, installId)
            currentUserId = account.userId
            Result.success(account)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun fetchAccount(userId: String): Result<UserAccount> = withContext(Dispatchers.IO) {
        try {
            val url = "$supabaseUrl/rest/v1/profiles?id=eq.$userId&select=*"
            val request = Request.Builder()
                .url(url)
                .addHeader("apikey", supabaseAnonKey)
                .addHeader("Authorization", "Bearer ${currentUserToken ?: supabaseAnonKey}")
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
            val url = "$supabaseUrl/rest/v1/coin_ledger?user_id=eq.$userId&order=created_at.desc&limit=100"
            val request = Request.Builder()
                .url(url)
                .addHeader("apikey", supabaseAnonKey)
                .addHeader("Authorization", "Bearer ${currentUserToken ?: supabaseAnonKey}")
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
            val url = "$supabaseUrl/rest/v1/campaigns?select=*&order=created_at.desc"
            val request = Request.Builder()
                .url(url)
                .addHeader("apikey", supabaseAnonKey)
                .addHeader("Authorization", "Bearer ${currentUserToken ?: supabaseAnonKey}")
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
        targetViews: Int
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

    override suspend fun signalContentReady(sessionId: String): Result<Boolean> = withContext(Dispatchers.IO) {
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
        idempotencyKey: String
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

    override suspend fun cancelCampaign(campaignId: String): Result<Long> = withContext(Dispatchers.IO) {
        try {
            val body = JSONObject().apply { put("p_campaign_id", campaignId) }
            val res = callRpc("cancel_campaign", body)
            Result.success(res.optLong("refunded_amount", 0L))
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun pauseCampaign(campaignId: String): Result<Boolean> = withContext(Dispatchers.IO) {
        try {
            val body = JSONObject().apply { put("p_campaign_id", campaignId) }
            val res = callRpcRaw("pause_campaign", body)
            Result.success(res.toBoolean())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    override suspend fun resumeCampaign(campaignId: String): Result<Boolean> = withContext(Dispatchers.IO) {
        try {
            val body = JSONObject().apply { put("p_campaign_id", campaignId) }
            val res = callRpcRaw("resume_campaign", body)
            Result.success(res.toBoolean())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun ensureAuthenticated(installId: String) {
        if (currentUserToken != null) return

        val cleanInstall = installId.filter { it.isLetterOrDigit() }.ifEmpty { "device12345" }
        val email = "sitebin_${cleanInstall.take(20)}@sitebin.internal"
        val password = "SiteBinSecure_${cleanInstall.hashCode().toUInt()}_Pass!"

        val signupBody = JSONObject().apply {
            put("email", email)
            put("password", password)
        }.toString().toRequestBody(jsonMediaType)

        val request = Request.Builder()
            .url("$supabaseUrl/auth/v1/signup")
            .addHeader("apikey", supabaseAnonKey)
            .post(signupBody)
            .build()

        val response = httpClient.newCall(request).execute()
        val raw = response.body?.string() ?: ""
        if (response.isSuccessful) {
            val json = JSONObject(raw)
            currentUserToken = json.optString("access_token")
            val user = json.optJSONObject("user")
            currentUserId = user?.optString("id")
        } else {
            // Attempt token login if already signed up
            val tokenUrl = "$supabaseUrl/auth/v1/token?grant_type=password"
            val tokenReq = Request.Builder()
                .url(tokenUrl)
                .addHeader("apikey", supabaseAnonKey)
                .post(signupBody)
                .build()
            val tokenRes = httpClient.newCall(tokenReq).execute()
            val tokenRaw = tokenRes.body?.string() ?: ""
            if (tokenRes.isSuccessful) {
                val json = JSONObject(tokenRaw)
                currentUserToken = json.optString("access_token")
                val user = json.optJSONObject("user")
                currentUserId = user?.optString("id")
            } else {
                // Fallback to anon key authorization for public RPC calls
                currentUserToken = supabaseAnonKey
            }
        }
    }

    private fun callRpc(functionName: String, body: JSONObject): JSONObject {
        val raw = callRpcRaw(functionName, body)
        return if (raw.isBlank() || raw == "null") JSONObject() else JSONObject(raw)
    }

    private fun callRpcRaw(functionName: String, body: JSONObject): String {
        val requestBody = body.toString().toRequestBody(jsonMediaType)
        val request = Request.Builder()
            .url("$supabaseUrl/rest/v1/rpc/$functionName")
            .addHeader("apikey", supabaseAnonKey)
            .addHeader("Authorization", "Bearer ${currentUserToken ?: supabaseAnonKey}")
            .post(requestBody)
            .build()

        val response = httpClient.newCall(request).execute()
        val raw = response.body?.string() ?: ""
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
