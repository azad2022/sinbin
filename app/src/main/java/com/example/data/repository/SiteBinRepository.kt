package com.example.data.repository

import android.content.Context
import com.example.core.security.PolicyResult
import com.example.core.security.UrlSecurityPolicy
import com.example.data.backend.BackendManager
import com.example.data.backend.ServerAuthoritativeEngine
import com.example.data.model.AbuseReport
import com.example.data.model.Campaign
import com.example.data.model.CoinTransaction
import com.example.data.model.DurationOption
import com.example.data.model.UserAccount
import com.example.data.model.ViewSession

sealed interface ServerInitializationState {
    data object Initializing : ServerInitializationState
    data object Ready : ServerInitializationState
    data class Failed(val message: String) : ServerInitializationState
}
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * SiteBinRepository — Clean MVVM Presentation Repository.
 *
 * All financial mutations, session creation, timer validation, and campaign progress
 * are strictly delegated to the ServerAuthoritativeEngine (Supabase / PostgreSQL RPC).
 * SharedPreferences is strictly non-authoritative.
 */
class SiteBinRepository(
    private val context: Context,
    val engine: ServerAuthoritativeEngine = BackendManager.getEngine(context)
) {
    private val scope = CoroutineScope(Dispatchers.IO)
    private val prefs = context.getSharedPreferences("sitebin_prefs", Context.MODE_PRIVATE)

    private val _serverState = MutableStateFlow<ServerInitializationState>(ServerInitializationState.Initializing)
    val serverState: StateFlow<ServerInitializationState> = _serverState.asStateFlow()

    private val _account = MutableStateFlow(
        UserAccount(
            userId = getOrGenerateInstallId(),
            appInstallId = getOrGenerateInstallId(),
            availableCoins = 0,
            reservedCoins = 0,
            lifetimeEarned = 0,
            lifetimeSpent = 0,
            trustScore = 100f,
            completedViewsCount = 0,
            receivedViewsCount = 0
        )
    )
    val account: StateFlow<UserAccount> = _account.asStateFlow()

    private val _transactions = MutableStateFlow<List<CoinTransaction>>(emptyList())
    val transactions: StateFlow<List<CoinTransaction>> = _transactions.asStateFlow()

    private val _campaigns = MutableStateFlow<List<Campaign>>(emptyList())
    val campaigns: StateFlow<List<Campaign>> = _campaigns.asStateFlow()

    private val _reports = MutableStateFlow<List<AbuseReport>>(emptyList())
    val reports: StateFlow<List<AbuseReport>> = _reports.asStateFlow()

    val durationOptions: List<DurationOption>
        get() = engine.durationOptions

    init {
        // Asynchronously initialize server-side identity & fetch server state
        scope.launch {
            initializeServerState()
        }
    }

    private fun getOrGenerateInstallId(): String {
        var installId = prefs.getString("app_install_id", null)
        if (installId == null) {
            installId = "inst_" + UUID.randomUUID().toString()
            prefs.edit().putString("app_install_id", installId).apply()
        }
        return installId
    }

    /**
     * Performs the mandatory startup handshake with the real backend.
     * The app must not expose the main UI until authentication, pricing, and
     * server-side account initialization have completed successfully.
     */
    suspend fun initializeServerState() {
        _serverState.value = ServerInitializationState.Initializing
        try {
            refreshServerState()
            _serverState.value = ServerInitializationState.Ready
        } catch (e: Exception) {
            _serverState.value = ServerInitializationState.Failed(
                e.message ?: "ارتباط با سرور برای آماده‌سازی حساب ناموفق بود."
            )
        }
    }

    /**
     * Refreshes user account, ledger transactions, and campaigns from Server.
     * Failures here are propagated so startup cannot silently fall back to a
     * fake zero-balance account.
     */
    suspend fun refreshServerState() {
        val installId = getOrGenerateInstallId()

        val pricingResult = engine.fetchDurationPricing()
        if (pricingResult.isFailure) {
            throw pricingResult.exceptionOrNull()
                ?: IllegalStateException("قیمت‌گذاری سرور در دسترس نیست.")
        }

        val initRes = engine.initAccount(installId)
        if (initRes.isFailure) {
            throw initRes.exceptionOrNull()
                ?: IllegalStateException("راه‌اندازی حساب در سرور ناموفق بود.")
        }

        val acc = initRes.getOrThrow()
        _account.value = acc

        engine.fetchTransactions(acc.userId)
            .onSuccess { _transactions.value = it }
            .onFailure { throw it }

        engine.fetchCampaigns(acc.userId)
            .onSuccess { _campaigns.value = it }
            .onFailure { throw it }
    }

    /**
     * Creates a new campaign on the server with strict server-side budget reservation.
     */
    suspend fun createCampaign(
        rawUrl: String,
        durationSeconds: Int,
        targetViews: Int
    ): Result<Campaign> {
        val policy = UrlSecurityPolicy.evaluateUrl(rawUrl)
        if (policy is PolicyResult.Blocked) {
            return Result.failure(IllegalArgumentException(policy.reason))
        }
        val allowed = policy as PolicyResult.Allowed

        val currentUserId = _account.value.userId
        val result = engine.createCampaign(
            url = allowed.normalizedUrl,
            normalizedUrl = allowed.normalizedUrl,
            domain = allowed.domain,
            durationSeconds = durationSeconds,
            targetViews = targetViews,
            callerUserId = currentUserId
        )

        result.onSuccess {
            // Re-sync authoritative server state
            refreshServerState()
        }

        return result
    }

    /**
     * Requests an active, server-approved view session from the authoritative engine.
     */
    suspend fun getNextViewSession(): Result<ViewSession?> {
        val currentUserId = _account.value.userId
        return engine.requestViewSession(currentUserId)
    }

    /**
     * Signals content ready in WebView to the authoritative server clock.
     */
    suspend fun signalContentReady(sessionId: String): Result<Boolean> {
        val currentUserId = _account.value.userId
        return engine.signalContentReady(sessionId, callerUserId = currentUserId)
    }

    /**
     * Idempotently completes a view session on the server.
     * Android Client timer is strictly for UI; coin reward is issued strictly by the server.
     */
    suspend fun completeViewSession(
        session: ViewSession,
        idempotencyKey: String = "complete_" + session.id + "_" + session.startedAt
    ): Result<Long> {
        val currentUserId = _account.value.userId
        val result = engine.completeViewSession(session.id, idempotencyKey, callerUserId = currentUserId)
        result.onSuccess {
            refreshServerState()
        }
        return result
    }

    suspend fun pauseCampaign(campaignId: String): Result<Boolean> {
        val currentUserId = _account.value.userId
        val result = engine.pauseCampaign(campaignId, callerUserId = currentUserId)
        if (result.isSuccess && result.getOrNull() == true) {
            refreshServerState()
        }
        return result
    }

    suspend fun resumeCampaign(campaignId: String): Result<Boolean> {
        val currentUserId = _account.value.userId
        val result = engine.resumeCampaign(campaignId, callerUserId = currentUserId)
        if (result.isSuccess && result.getOrNull() == true) {
            refreshServerState()
        }
        return result
    }

    suspend fun cancelViewSession(sessionId: String): Result<Boolean> {
        val currentUserId = _account.value.userId
        return engine.cancelViewSession(sessionId, callerUserId = currentUserId)
    }

    suspend fun cancelCampaign(campaignId: String): Result<Long> {
        val currentUserId = _account.value.userId
        val res = engine.cancelCampaign(campaignId, callerUserId = currentUserId)
        res.onSuccess {
            refreshServerState()
        }
        return res
    }

    fun submitReport(campaignId: String, domain: String, reason: String, details: String) {
        val report = AbuseReport(
            campaignId = campaignId,
            domain = domain,
            reason = reason,
            details = details
        )
        _reports.update { listOf(report) + it }
    }
}
