package com.example.data.repository

import android.content.Context
import com.example.core.security.PolicyResult
import com.example.core.security.UrlSecurityPolicy
import com.example.data.backend.BackendManager
import com.example.data.backend.ServerAuthoritativeEngine
import com.example.data.model.AbuseReport
import com.example.data.model.AutoViewActivationResult
import com.example.data.model.AutoViewStatus
import com.example.data.model.Campaign
import com.example.data.model.CoinTransaction
import com.example.data.model.CoinTransferResult
import com.example.data.model.DailyBonusResult
import com.example.data.model.DurationOption
import com.example.data.model.UserAccount
import com.example.data.model.ViewCompletionResult
import com.example.data.model.ViewSession

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.UUID

sealed interface ServerInitializationState {
    data object Initializing : ServerInitializationState
    data object Ready : ServerInitializationState
    data class Failed(val message: String) : ServerInitializationState
}

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

    private val _dailyBonus = MutableStateFlow<DailyBonusResult?>(null)
    val dailyBonus: StateFlow<DailyBonusResult?> = _dailyBonus.asStateFlow()

    private val _autoViewStatus = MutableStateFlow(AutoViewStatus(active = false))
    val autoViewStatus: StateFlow<AutoViewStatus> = _autoViewStatus.asStateFlow()

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

        // Daily bonus is optional to startup readiness: authentication/account state remains
        // available during a transient bonus RPC failure, but the entitlement itself is decided
        // exclusively by PostgreSQL.
        claimDailyBonus()
        refreshAutoViewStatus()

        engine.fetchTransactions(acc.userId)
            .onSuccess { _transactions.value = it }
            .onFailure { throw it }

        engine.fetchCampaigns(acc.userId)
            .onSuccess { _campaigns.value = it }
            .onFailure { throw it }
    }

    suspend fun transferCoins(
        recipientHandle: String,
        amount: Long
    ): Result<CoinTransferResult> {
        val currentUserId = _account.value.userId
        val idempotencyKey = "transfer_" + UUID.randomUUID().toString()
        val result = engine.transferCoins(
            recipientHandle = recipientHandle.trim(),
            amount = amount,
            idempotencyKey = idempotencyKey,
            note = null,
            callerUserId = currentUserId
        )
        if (result.isSuccess) {
            runCatching { refreshServerState() }
        }
        return result
    }

    suspend fun getAutoViewStatus(): Result<AutoViewStatus> {
        val currentUserId = _account.value.userId
        val result = engine.getAutoViewStatus(callerUserId = currentUserId)
        result.onSuccess { _autoViewStatus.value = it }
        return result
    }

    suspend fun refreshAutoViewStatus(): Result<AutoViewStatus> = getAutoViewStatus()

    suspend fun activateAutoView(): Result<AutoViewActivationResult> {
        val currentUserId = _account.value.userId
        val idempotencyKey = "auto_view_" + UUID.randomUUID().toString()
        val result = engine.activateAutoView(
            idempotencyKey = idempotencyKey,
            callerUserId = currentUserId
        )
        result.onSuccess { activation ->
            _autoViewStatus.value = AutoViewStatus(
                active = true,
                expiresAt = activation.expiresAt
            )
            engine.fetchAccount(currentUserId).onSuccess { _account.value = it }
        }
        return result
    }

    suspend fun claimDailyBonus(): Result<DailyBonusResult> {
        val currentUserId = _account.value.userId
        val result = engine.claimDailyBonus(callerUserId = currentUserId)
        result.onSuccess { bonus ->
            _dailyBonus.value = bonus

            // The claim RPC mutates authoritative financial state. Re-read both balance
            // and ledger so Android never derives the new balance locally.
            if (bonus.granted) {
                val currentUserId = _account.value.userId
                engine.fetchAccount(currentUserId).onSuccess { _account.value = it }
                engine.fetchTransactions(currentUserId).onSuccess { _transactions.value = it }
            }
        }
        return result
    }

    suspend fun refreshFinancialState(): Result<Unit> {
        val currentUserId = _account.value.userId
        return runCatching {
            val acc = engine.fetchAccount(currentUserId).getOrThrow()
            val tx = engine.fetchTransactions(currentUserId).getOrThrow()
            _account.value = acc
            _transactions.value = tx
        }
    }
    /**
     * Creates a new campaign on the server with strict server-side budget reservation.
     */
    suspend fun createCampaign(
        rawUrl: String,
        durationSeconds: Int,
        targetViews: Int,
        keyword: String? = null
    ): Result<Campaign> {
        val cleanKeyword = keyword?.trim()?.ifBlank { null }
        if (cleanKeyword != null && cleanKeyword.length > 25) {
            return Result.failure(IllegalArgumentException("INVALID_KEYWORD: Keyword must be at most 25 characters"))
        }
        if (cleanKeyword != null && cleanKeyword.any(Char::isISOControl)) {
            return Result.failure(IllegalArgumentException("INVALID_KEYWORD: Keyword contains control characters"))
        }

        val policy = UrlSecurityPolicy.evaluateUrl(rawUrl)
        if (policy is PolicyResult.Blocked) {
            return Result.failure(IllegalArgumentException(policy.reason))
        }
        val allowed = policy as PolicyResult.Allowed

        val currentUserId = _account.value.userId
        val createResult = engine.createCampaign(
            url = allowed.normalizedUrl,
            normalizedUrl = allowed.normalizedUrl,
            domain = allowed.domain,
            durationSeconds = durationSeconds,
            targetViews = targetViews,
            keyword = cleanKeyword,
            callerUserId = currentUserId
        )

        val created = createResult.getOrNull() ?: return createResult

        if (cleanKeyword != null) {
            val resolution = engine.resolveCampaignTarget(created.id)
            if (resolution.isSuccess) {
                val resolvedCampaign = engine.fetchCampaigns(currentUserId)
                    .getOrNull()
                    ?.firstOrNull { it.id == created.id }
                    ?: created.copy(resolverStatus = "READY")

                runCatching { refreshServerState() }
                return Result.success(resolvedCampaign)
            }

            val resolverMessage = resolution.exceptionOrNull()?.message.orEmpty()
            if (resolverMessage.startsWith("NO_MATCH:")) {
                // No-match is deterministic: cancel the newly reserved campaign so
                // advertiser coins are not stranded in an unusable pending campaign.
                engine.cancelCampaign(created.id, callerUserId = currentUserId)
                return Result.failure(
                    IllegalStateException("NO_MATCH: صفحه‌ای مرتبط با این کلمه کلیدی در سایت پیدا نشد.")
                )
            }

            // A transient resolver failure leaves the campaign safely PENDING.
            // It is excluded from the Viewer queue until a later resolver retry succeeds.
            runCatching { refreshServerState() }
            return Result.success(created.copy(resolverStatus = "PENDING"))
        }

        runCatching { refreshServerState() }
        return createResult
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
    ): Result<ViewCompletionResult> {
        val currentUserId = _account.value.userId
        val result = engine.completeViewSession(
            session.id,
            idempotencyKey,
            callerUserId = currentUserId
        )

        result.onSuccess { completion ->
            // The completion RPC returns the authoritative financial snapshot,
            // so the Viewer path does not block on a broad refresh waterfall.
            _account.update { current ->
                current.copy(
                    availableCoins = completion.availableCoins,
                    lifetimeEarned = completion.lifetimeEarned,
                    completedViewsCount = completion.completedViewsCount
                )
            }

            // Non-critical UI state is synchronized in the background.
            scope.launch {
                engine.fetchTransactions(currentUserId)
                    .onSuccess { _transactions.value = it }
                engine.fetchCampaigns(currentUserId)
                    .onSuccess { _campaigns.value = it }
            }
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
