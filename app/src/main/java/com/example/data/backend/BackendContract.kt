package com.example.data.backend

import com.example.data.model.Campaign
import com.example.data.model.CoinTransaction
import com.example.data.model.CoinTransferResult
import com.example.data.model.DurationOption
import com.example.data.model.UserAccount
import com.example.data.model.ViewSession

/**
 * Server-Authoritative Engine Interface
 * Android Client must never mutate financial balance, coin ledger, or campaign progress directly.
 * All mutations are executed strictly by the authoritative backend (Supabase PostgreSQL / RPC).
 */
interface ServerAuthoritativeEngine {

    /** Server-authoritative duration pricing matrix */
    val durationOptions: List<DurationOption>

    /** Fetch server-authoritative duration pricing matrix dynamically from database */
    suspend fun fetchDurationPricing(): Result<List<DurationOption>> = Result.success(durationOptions)

    /** Initialize account with server identity and grant exactly one welcome bonus */
    suspend fun initAccount(installId: String, handle: String? = null): Result<UserAccount>

    /** Fetch latest server-authoritative account state */
    suspend fun fetchAccount(userId: String): Result<UserAccount>

    /** Fetch server coin transactions ledger */
    suspend fun fetchTransactions(userId: String): Result<List<CoinTransaction>>

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
        callerUserId: String? = null
    ): Result<Campaign>

    /**
     * Requests an eligible view session selected by the server,
     * enforcing anti-self view, cooldowns, and active budget.
     */
    suspend fun requestViewSession(userId: String): Result<ViewSession?>

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
    ): Result<Long>

    /** Cancels an active or paused campaign and refunds remaining reserved budget */
    suspend fun cancelCampaign(campaignId: String, callerUserId: String? = null): Result<Long>

    /** Cancels an unfinished viewing session without affecting coins */
    suspend fun cancelViewSession(sessionId: String, callerUserId: String? = null): Result<Boolean>

    /** Pauses a campaign on the server */
    suspend fun pauseCampaign(campaignId: String, callerUserId: String? = null): Result<Boolean>

    /** Resumes a paused campaign on the server */
    suspend fun resumeCampaign(campaignId: String, callerUserId: String? = null): Result<Boolean>
}
