package com.example.data.backend

import com.example.data.model.AutoViewActivationResult
import com.example.data.model.AutoViewStatus
import com.example.data.model.Campaign
import com.example.data.model.CoinTransaction
import com.example.data.model.CoinTransferResult
import com.example.data.model.DurationOption
import com.example.data.model.DailyBonusResult
import com.example.data.model.UserAccount
import com.example.data.model.ViewCompletionResult
import com.example.data.model.ViewSession

enum class WebsiteViewerCompatibility {
    COMPATIBLE,
    NEEDS_ATTENTION,
    INCOMPATIBLE
}

enum class WebsiteDiagnosticSeverity {
    INFO,
    WARNING,
    BLOCK
}

data class WebsiteDiagnostic(
    val code: String,
    val severity: WebsiteDiagnosticSeverity,
    val message: String
)

data class WebsitePreflightResult(
    val sourceUrl: String,
    val normalizedUrl: String,
    val domain: String,
    val finalUrl: String,
    val httpStatus: Int,
    val redirectCount: Int,
    val responseMs: Long,
    val contentType: String?,
    val contentLength: Long?,
    val viewerCompatibility: WebsiteViewerCompatibility,
    val qualityScore: Int,
    val diagnostics: List<WebsiteDiagnostic>,
    val expiresAtEpochMs: Long,
    val preflightToken: String
)

/**
 * Server-Authoritative Engine Interface
 * Android Client must never mutate financial balance, coin ledger, or campaign progress directly.
 * All mutations are executed strictly by the authoritative backend (Supabase PostgreSQL / RPC).
 */
interface RealtimeCapableEngine {
    /**
     * Enables/disables the foreground realtime transport. The transport remains
     * server-authoritative; realtime events only trigger fresh reads from PostgREST.
     */
    fun setRealtimeActive(active: Boolean)

    /** Exposes realtime connection health for the polling fallback. */
    fun isRealtimeConnected(): Boolean

    /** Receives table-level change hints from Supabase Realtime. */
    fun setRealtimeEventListener(listener: ((String) -> Unit)?)
}

interface ServerAuthoritativeEngine {

    /** Server-authoritative duration pricing matrix */
    val durationOptions: List<DurationOption>

    /** Fetch server-authoritative duration pricing matrix dynamically from database */
    suspend fun fetchDurationPricing(): Result<List<DurationOption>> = Result.success(durationOptions)

    /**
     * Initialize application account and submit platform device evidence.
     * Eligibility is always decided server-side; installId is not a trust root.
     */
    suspend fun initAccount(
        evidence: DeviceEvidence,
        handle: String? = null
    ): Result<UserAccount>

    /** Legacy compatibility path. The server intentionally receives no strong evidence here,
     * so legacy clients can initialize an account but cannot mint a new welcome bonus. */
    suspend fun initAccount(installId: String, handle: String? = null): Result<UserAccount> =
        initAccount(DeviceEvidence(installId = installId), handle)

    /** Fetch latest server-authoritative account state */
    suspend fun fetchAccount(userId: String): Result<UserAccount>

    /** Fetch server coin transactions ledger */
    suspend fun fetchTransactions(userId: String): Result<List<CoinTransaction>>

    /** Claims the server-authoritative daily login bonus for the current authenticated user. */
    suspend fun claimDailyBonus(callerUserId: String? = null): Result<DailyBonusResult>

    /** Returns the server-authoritative seven-day auto-view entitlement state. */
    suspend fun getAutoViewStatus(callerUserId: String? = null): Result<AutoViewStatus>

    /** Atomically charges 100 coins for a seven-day auto-view entitlement. */
    suspend fun activateAutoView(
        idempotencyKey: String,
        callerUserId: String? = null
    ): Result<AutoViewActivationResult>

    /** Atomically transfers available coins between two authenticated accounts. */
    suspend fun transferCoins(
        recipientHandle: String,
        amount: Long,
        idempotencyKey: String,
        note: String? = null,
        callerUserId: String? = null
    ): Result<CoinTransferResult>

    /** Fetch active & user campaigns from server */
    suspend fun fetchCampaigns(userId: String): Result<List<Campaign>>

    /**
     * Creates a campaign on the server with atomic budget calculation,
     * balance verification, and ledger reservation.
     */
    suspend fun createCampaign(
        url: String,
        normalizedUrl: String,
        domain: String,
        durationSeconds: Int,
        targetViews: Int,
        keyword: String? = null,
        callerUserId: String? = null,
        preflightToken: String? = null
    ): Result<Campaign>

    /** Runs the authoritative server-side website preflight before campaign creation. */
    suspend fun preflightCampaignUrl(url: String): Result<WebsitePreflightResult> =
        Result.failure(UnsupportedOperationException("Website preflight is unavailable."))

    /**
     * Requests an eligible view session selected by the server,
     * enforcing anti-self view, cooldowns, and active budget.
     */
    suspend fun requestViewSession(userId: String): Result<ViewSession?>

    /** Resolves a keyword campaign to a relevant page on the advertiser's own origin. */
    suspend fun resolveCampaignTarget(campaignId: String): Result<String> =
        Result.failure(UnsupportedOperationException("Keyword target resolver is unavailable."))

    /**
     * Signals the server that page content is genuinely rendered in WebView,
     * starting the authoritative server timer.
     */
    suspend fun signalContentReady(sessionId: String, callerUserId: String? = null): Result<Boolean>

    /**
     * Idempotently completes a view session on the server.
     * Verifies server clock duration, increments views, reserves/spends budget,
     * and credits coins to viewer.
     */
    suspend fun completeViewSession(
        sessionId: String,
        idempotencyKey: String,
        callerUserId: String? = null
    ): Result<ViewCompletionResult>

    /** Cancels an active or paused campaign and refunds remaining reserved budget */
    suspend fun cancelCampaign(campaignId: String, callerUserId: String? = null): Result<Long>

    /** Cancels an unfinished viewing session without affecting coins */
    suspend fun cancelViewSession(sessionId: String, callerUserId: String? = null): Result<Boolean>

    /** Pauses a campaign on the server */
    suspend fun pauseCampaign(campaignId: String, callerUserId: String? = null): Result<Boolean>

    /** Resumes a paused campaign on the server */
    suspend fun resumeCampaign(campaignId: String, callerUserId: String? = null): Result<Boolean>
}
