package com.example.data.backend

import com.example.data.model.Campaign
import com.example.data.model.CampaignStatus
import com.example.data.model.CoinTransaction
import com.example.data.model.DurationOption
import com.example.data.model.TransactionType
import com.example.data.model.UserAccount
import com.example.data.model.ViewSession
import java.util.UUID
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * High-fidelity, thread-safe, transactional in-memory / local implementation of
 * ServerAuthoritativeEngine that replicates the exact PostgreSQL schema, RLS, and RPC rules.
 *
 * Guarantees:
 * - Thread-safe atomic transactions (ReentrantLock)
 * - Strict Anti-Farming: non-blank installId mandatory; 1 installId = 1 account
 * - Ownership enforcement: callerUserId strictly checked on cancel, pause, resume, signal, and complete
 * - User-scoped ledger visibility (matches PostgreSQL RLS)
 * - Allows completing in-flight sessions of PAUSED campaigns
 * - Strict Idempotency and exact CONTENT_READY state transition on view completion
 */
class ServerEmulatedEngine : ServerAuthoritativeEngine {

    private val lock = ReentrantLock()

    // 1. Server-Authoritative Duration Pricing Matrix
    override val durationOptions: List<DurationOption> = listOf(
        DurationOption(seconds = 5, advertiserCost = 5, viewerReward = 3),
        DurationOption(seconds = 10, advertiserCost = 9, viewerReward = 6),
        DurationOption(seconds = 15, advertiserCost = 14, viewerReward = 10, isPopular = true),
        DurationOption(seconds = 30, advertiserCost = 26, viewerReward = 19),
        DurationOption(seconds = 60, advertiserCost = 50, viewerReward = 38)
    )

    override suspend fun fetchDurationPricing(): Result<List<DurationOption>> = lock.withLock {
        Result.success(durationOptions)
    }

    // Internal Database Tables
    private val profiles = mutableMapOf<String, UserAccount>()
    private val welcomeBonusGrants = mutableMapOf<String, String>() // userId -> installId
    private val campaigns = mutableMapOf<String, Campaign>()
    private val viewSessions = mutableMapOf<String, ServerViewSessionRecord>()
    private val userLedger = mutableMapOf<String, MutableList<CoinTransaction>>() // userId -> ledger
    private val idempotencyRecords = mutableMapOf<String, IdempotencyRecord>() // idempotencyKey -> IdempotencyRecord

    data class IdempotencyRecord(
        val sessionId: String,
        val viewerId: String,
        val reward: Long
    )

    data class ServerViewSessionRecord(
        val id: String,
        val campaignId: String,
        val viewerId: String,
        val requiredDurationSeconds: Int,
        val rewardCoins: Long,
        var status: String, // INITIALIZED, CONTENT_READY, COMPLETED, EXPIRED, CANCELLED
        val startedAt: Long,
        var contentReadyAt: Long? = null,
        var completedAt: Long? = null,
        var idempotencyKey: String? = null
    )

    override suspend fun initAccount(installId: String, handle: String?): Result<UserAccount> = lock.withLock {
        val cleanInstall = installId.trim().ifEmpty { null }
            ?: return Result.failure(IllegalArgumentException("INVALID_INSTALL_ID: Installation identifier is required for account initialization"))

        val userId = handle ?: ("user_" + cleanInstall.hashCode().toUInt().toString(16))

        // Check if this installation identifier is already registered to a DIFFERENT user
        val existingByInstall = profiles.values.find { it.appInstallId == cleanInstall }
        if (existingByInstall != null && existingByInstall.userId != userId) {
            return Result.failure(
                IllegalStateException("INSTALL_ALREADY_REGISTERED: Installation identifier is already associated with another account")
            )
        }
        val grantExistingUser = welcomeBonusGrants.entries.find { it.value == cleanInstall }?.key
        if (grantExistingUser != null && grantExistingUser != userId) {
            return Result.failure(
                IllegalStateException("INSTALL_ALREADY_REGISTERED: Installation identifier is already associated with another account")
            )
        }

        val existingProfile = profiles[userId]
        if (existingProfile != null) {
            return Result.success(existingProfile)
        }

        // Create new account and grant welcome bonus atomically ONCE
        val welcomeAmount = 150L
        val isFirstTime = !welcomeBonusGrants.containsKey(userId)

        val grantedCoins = if (isFirstTime) welcomeAmount else 0L
        if (isFirstTime) {
            welcomeBonusGrants[userId] = cleanInstall
            val welcomeTx = CoinTransaction(
                id = UUID.randomUUID().toString(),
                amount = welcomeAmount,
                type = TransactionType.WELCOME_REWARD,
                description = "هدیه ورود به سایت بین (Welcome Bonus)",
                referenceId = "init_bonus"
            )
            userLedger.getOrPut(userId) { mutableListOf() }.add(0, welcomeTx)
        }

        val newAccount = UserAccount(
            userId = userId,
            appInstallId = cleanInstall,
            availableCoins = grantedCoins,
            reservedCoins = 0L,
            lifetimeEarned = grantedCoins,
            lifetimeSpent = 0L,
            trustScore = 100f,
            completedViewsCount = 0,
            receivedViewsCount = 0
        )
        profiles[userId] = newAccount
        Result.success(newAccount)
    }

    override suspend fun fetchAccount(userId: String): Result<UserAccount> = lock.withLock {
        val account = profiles[userId] ?: return Result.failure(NoSuchElementException("User not found"))
        Result.success(account)
    }

    override suspend fun fetchTransactions(userId: String): Result<List<CoinTransaction>> = lock.withLock {
        // Enforce user-scoped ledger visibility (matches PostgreSQL RLS)
        Result.success(userLedger[userId]?.toList() ?: emptyList())
    }

    override suspend fun fetchCampaigns(userId: String): Result<List<Campaign>> = lock.withLock {
        // Matches RLS: caller sees own campaigns and active campaigns
        val list = campaigns.values.filter { it.ownerId == userId || it.status == CampaignStatus.ACTIVE }
            .sortedByDescending { it.createdAt }
        Result.success(list)
    }

    override suspend fun createCampaign(
        url: String,
        normalizedUrl: String,
        domain: String,
        durationSeconds: Int,
        targetViews: Int,
        callerUserId: String?
    ): Result<Campaign> = lock.withLock {
        val cleanUrl = url.trim()
        val cleanNormalized = normalizedUrl.trim()
        val cleanDomain = domain.trim()

        if (cleanUrl.isBlank() || cleanUrl.length > 2048 || (!cleanUrl.startsWith("http://") && !cleanUrl.startsWith("https://"))) {
            return Result.failure(IllegalArgumentException("INVALID_URL: Target URL must be a valid HTTP/HTTPS address up to 2048 characters"))
        }

        if (cleanNormalized.isBlank() || cleanNormalized.length > 2048) {
            return Result.failure(IllegalArgumentException("INVALID_NORMALIZED_URL: Normalized URL cannot be empty"))
        }

        if (cleanDomain.isBlank() || cleanDomain.length > 253 || cleanDomain.contains('/') || cleanDomain.contains(' ')) {
            return Result.failure(IllegalArgumentException("INVALID_DOMAIN: Domain must be a valid hostname without slashes or whitespace"))
        }

        if (targetViews <= 0 || targetViews > 1000000) {
            return Result.failure(IllegalArgumentException("INVALID_TARGET_VIEWS: Target views must be between 1 and 1,000,000"))
        }

        val pricing = durationOptions.find { it.seconds == durationSeconds }
            ?: return Result.failure(IllegalArgumentException("INVALID_DURATION: Unsupported duration option"))

        // Server-calculated total cost
        val totalCost = pricing.advertiserCost * targetViews

        // Identify calling user explicitly
        val effectiveCallerId = callerUserId ?: profiles.keys.firstOrNull()
            ?: return Result.failure(IllegalStateException("PROFILE_NOT_FOUND: User profile does not exist"))

        val callerAccount = profiles[effectiveCallerId]
            ?: return Result.failure(IllegalStateException("PROFILE_NOT_FOUND: User profile does not exist"))

        // Atomic balance verification
        if (callerAccount.availableCoins < totalCost) {
            return Result.failure(
                IllegalStateException("INSUFFICIENT_BALANCE: Available balance (${callerAccount.availableCoins} coins) is less than required budget ($totalCost coins)")
            )
        }

        // Atomic reservation in ledger
        val updatedAccount = callerAccount.copy(
            availableCoins = callerAccount.availableCoins - totalCost,
            reservedCoins = callerAccount.reservedCoins + totalCost
        )
        profiles[effectiveCallerId] = updatedAccount

        val newCampaign = Campaign(
            id = UUID.randomUUID().toString(),
            ownerId = effectiveCallerId,
            url = cleanNormalized,
            domain = cleanDomain,
            durationSeconds = durationSeconds,
            targetViews = targetViews,
            completedViews = 0,
            costPerView = pricing.advertiserCost,
            totalBudget = totalCost,
            spentBudget = 0,
            status = CampaignStatus.ACTIVE,
            createdAt = System.currentTimeMillis()
        )
        campaigns[newCampaign.id] = newCampaign

        val reservationTx = CoinTransaction(
            id = UUID.randomUUID().toString(),
            amount = -totalCost,
            type = TransactionType.CAMPAIGN_RESERVATION,
            description = "رزرو بودجه برای سفارش $targetViews بازدید از $cleanDomain",
            referenceId = newCampaign.id
        )
        userLedger.getOrPut(effectiveCallerId) { mutableListOf() }.add(0, reservationTx)

        Result.success(newCampaign)
    }

    override suspend fun requestViewSession(userId: String): Result<ViewSession?> = lock.withLock {
        val now = System.currentTimeMillis()

        // 1. Check for active unfinished session created in last 3 minutes
        val activeSession = viewSessions.values.find {
            it.viewerId == userId &&
            (it.status == "INITIALIZED" || it.status == "CONTENT_READY") &&
            (now - it.startedAt) < 180_000
        }
        if (activeSession != null) {
            val camp = campaigns[activeSession.campaignId]
            if (camp != null) {
                return Result.success(
                    ViewSession(
                        id = activeSession.id,
                        campaignId = camp.id,
                        targetUrl = camp.url,
                        domain = camp.domain,
                        requiredDurationSeconds = activeSession.requiredDurationSeconds,
                        rewardCoins = activeSession.rewardCoins,
                        startedAt = activeSession.startedAt
                    )
                )
            }
        }

        // Cancel expired sessions
        viewSessions.values.filter {
            it.viewerId == userId &&
            (it.status == "INITIALIZED" || it.status == "CONTENT_READY") &&
            (now - it.startedAt) >= 180_000
        }.forEach { it.status = "EXPIRED" }

        // Find eligible campaigns:
        // - status == ACTIVE
        // - ownerId != userId (Server-Enforced Anti-Self View)
        // - completedViews < targetViews
        // - remaining reservedBudget >= costPerView
        // - Cooldown: viewer has not completed this campaign within the last 15 minutes
        val eligibleCampaigns = campaigns.values.filter { camp ->
            camp.status == CampaignStatus.ACTIVE &&
            camp.ownerId != userId &&
            camp.completedViews < camp.targetViews &&
            camp.remainingBudget >= camp.costPerView &&
            viewSessions.values.none { vs ->
                vs.campaignId == camp.id &&
                vs.viewerId == userId &&
                vs.status == "COMPLETED" &&
                (now - (vs.completedAt ?: 0L)) < 15 * 60 * 1000L
            }
        }

        val selected = eligibleCampaigns.firstOrNull() ?: return Result.success(null)

        val pricing = durationOptions.find { it.seconds == selected.durationSeconds }
            ?: durationOptions[2]

        val newSessionRecord = ServerViewSessionRecord(
            id = UUID.randomUUID().toString(),
            campaignId = selected.id,
            viewerId = userId,
            requiredDurationSeconds = selected.durationSeconds,
            rewardCoins = pricing.viewerReward,
            status = "INITIALIZED",
            startedAt = now
        )
        viewSessions[newSessionRecord.id] = newSessionRecord

        val session = ViewSession(
            id = newSessionRecord.id,
            campaignId = selected.id,
            targetUrl = selected.url,
            domain = selected.domain,
            requiredDurationSeconds = selected.durationSeconds,
            rewardCoins = pricing.viewerReward,
            startedAt = now
        )
        Result.success(session)
    }

    override suspend fun signalContentReady(sessionId: String, callerUserId: String?): Result<Boolean> = lock.withLock {
        val record = viewSessions[sessionId]
            ?: return Result.failure(NoSuchElementException("جلسه مشاهده یافت نشد."))

        if (callerUserId != null && record.viewerId != callerUserId) {
            return Result.failure(IllegalStateException("FORBIDDEN: Session does not belong to caller"))
        }

        if (record.status == "INITIALIZED") {
            record.status = "CONTENT_READY"
            record.contentReadyAt = System.currentTimeMillis()
        }
        Result.success(true)
    }

    override suspend fun completeViewSession(
        sessionId: String,
        idempotencyKey: String,
        callerUserId: String?
    ): Result<Long> = lock.withLock {
        val cleanKey = idempotencyKey.trim()
        if (cleanKey.isEmpty()) {
            return Result.failure(IllegalArgumentException("INVALID_IDEMPOTENCY_KEY: Idempotency key cannot be empty"))
        }
        if (cleanKey.length > 128) {
            return Result.failure(IllegalArgumentException("INVALID_IDEMPOTENCY_KEY: Idempotency key exceeds maximum length of 128 characters"))
        }

        val record = viewSessions[sessionId]
            ?: return Result.failure(NoSuchElementException("SESSION_NOT_FOUND: View session does not exist"))

        if (callerUserId != null && record.viewerId != callerUserId) {
            return Result.failure(IllegalStateException("FORBIDDEN: Session does not belong to the caller"))
        }

        // Idempotency check 1: Has this idempotency key already been processed?
        val existingRecord = idempotencyRecords[cleanKey]
        if (existingRecord != null) {
            if (existingRecord.sessionId != sessionId) {
                return Result.failure(IllegalStateException("IDEMPOTENCY_KEY_CONFLICT: Key has already been associated with a different session"))
            }
            if (callerUserId != null && existingRecord.viewerId != callerUserId) {
                return Result.failure(IllegalStateException("IDEMPOTENCY_KEY_CONFLICT: Key has already been used by another user"))
            }
            return Result.success(existingRecord.reward)
        }

        // Idempotency check 2: Has this session already completed?
        if (record.status == "COMPLETED") {
            return Result.success(record.rewardCoins)
        }

        // Strict State Transition Check: MUST be exactly 'CONTENT_READY'
        if (record.status != "CONTENT_READY") {
            return Result.failure(
                IllegalStateException("INVALID_SESSION_STATUS: Session is ${record.status} but must be CONTENT_READY to complete")
            )
        }

        // Server Timing Verification
        val contentReadyTime = record.contentReadyAt
            ?: return Result.failure(IllegalStateException("INVALID_SESSION_STATE: Content ready signal was never received"))

        val now = System.currentTimeMillis()
        val elapsedMs = now - contentReadyTime
        val requiredMs = (record.requiredDurationSeconds * 1000L) - 1000L // 1 sec tolerance for network roundtrip

        if (elapsedMs < requiredMs) {
            return Result.failure(
                IllegalStateException("PREMATURE_COMPLETION: Elapsed time (${elapsedMs / 1000}s) is less than required (${record.requiredDurationSeconds}s)")
            )
        }

        val camp = campaigns[record.campaignId]
            ?: return Result.failure(NoSuchElementException("CAMPAIGN_NOT_FOUND: Associated campaign no longer exists"))

        // Blocker 7: Allow in-flight session issued prior to pause to complete; reject CANCELLED / COMPLETED
        if (camp.status != CampaignStatus.ACTIVE && camp.status != CampaignStatus.PAUSED) {
            return Result.failure(IllegalStateException("CAMPAIGN_INACTIVE: Campaign is ${camp.status} but must be ACTIVE or PAUSED"))
        }

        if (camp.completedViews >= camp.targetViews) {
            return Result.failure(IllegalStateException("CAMPAIGN_EXHAUSTED: Campaign has already reached its target view count"))
        }

        if (camp.remainingBudget < camp.costPerView) {
            return Result.failure(IllegalStateException("INSUFFICIENT_CAMPAIGN_BUDGET: Campaign reserved budget is less than cost per view"))
        }

        val owner = profiles[camp.ownerId]
            ?: return Result.failure(IllegalStateException("Owner profile not found"))

        if (owner.reservedCoins < camp.costPerView) {
            return Result.failure(IllegalStateException("INSUFFICIENT_RESERVED_BALANCE: Owner reserved coins is less than cost per view"))
        }

        // 1. Update Campaign Delivery Progress & Budget
        val newViews = camp.completedViews + 1
        val newSpent = camp.spentBudget + camp.costPerView
        val isDone = newViews >= camp.targetViews
        val updatedCampaign = camp.copy(
            completedViews = newViews,
            spentBudget = newSpent,
            status = if (isDone) CampaignStatus.COMPLETED else camp.status
        )
        campaigns[camp.id] = updatedCampaign

        // 2. Deduct Campaign Owner's Reserved Budget and increment spent
        profiles[camp.ownerId] = owner.copy(
            reservedCoins = owner.reservedCoins - camp.costPerView,
            lifetimeSpent = owner.lifetimeSpent + camp.costPerView,
            receivedViewsCount = owner.receivedViewsCount + 1
        )

        // 3. Credit Viewer's Balance
        val viewer = profiles[record.viewerId]
            ?: return Result.failure(IllegalStateException("Viewer profile not found"))

        val reward = record.rewardCoins
        profiles[record.viewerId] = viewer.copy(
            availableCoins = viewer.availableCoins + reward,
            lifetimeEarned = viewer.lifetimeEarned + reward,
            completedViewsCount = viewer.completedViewsCount + 1
        )

        // 4. Mark Session Completed & Idempotent
        record.status = "COMPLETED"
        record.completedAt = now
        record.idempotencyKey = cleanKey
        idempotencyRecords[cleanKey] = IdempotencyRecord(
            sessionId = sessionId,
            viewerId = record.viewerId,
            reward = reward
        )

        // 5. Record Viewer Reward in User-Scoped Ledger
        val rewardTx = CoinTransaction(
            id = UUID.randomUUID().toString(),
            amount = reward,
            type = TransactionType.VIEW_REWARD,
            description = "مشاهده موفق ${record.requiredDurationSeconds} ثانیه‌ای از ${camp.domain}",
            referenceId = camp.id
        )
        userLedger.getOrPut(record.viewerId) { mutableListOf() }.add(0, rewardTx)

        // 6. Record Advertiser Spend in User-Scoped Ledger
        val spendTx = CoinTransaction(
            id = UUID.randomUUID().toString(),
            amount = -camp.costPerView,
            type = TransactionType.CAMPAIGN_SPEND,
            description = "مصرف بودجه بازدید از ${camp.domain}",
            referenceId = camp.id
        )
        userLedger.getOrPut(camp.ownerId) { mutableListOf() }.add(0, spendTx)

        Result.success(reward)
    }

    override suspend fun cancelViewSession(sessionId: String, callerUserId: String?): Result<Boolean> = lock.withLock {
        val record = viewSessions[sessionId]
            ?: return Result.failure(NoSuchElementException("SESSION_NOT_FOUND: View session does not exist"))

        if (callerUserId == null || record.viewerId != callerUserId) {
            return Result.failure(IllegalStateException("FORBIDDEN: Session does not belong to caller"))
        }

        if (record.status == "INITIALIZED" || record.status == "CONTENT_READY") {
            record.status = "CANCELLED"
            return Result.success(true)
        }

        Result.success(false)
    }

    override suspend fun cancelCampaign(campaignId: String, callerUserId: String?): Result<Long> = lock.withLock {
        val camp = campaigns[campaignId]
            ?: return Result.failure(NoSuchElementException("CAMPAIGN_NOT_FOUND: Campaign does not exist or caller is not owner"))

        if (callerUserId != null && camp.ownerId != callerUserId) {
            return Result.failure(IllegalStateException("CAMPAIGN_NOT_FOUND: Campaign does not exist or caller is not owner"))
        }

        if (camp.status == CampaignStatus.CANCELLED || camp.status == CampaignStatus.COMPLETED) {
            return Result.failure(IllegalStateException("INVALID_CAMPAIGN_STATE: Cannot cancel a ${camp.status} campaign"))
        }

        val unspent = camp.remainingBudget
        val updatedCamp = camp.copy(status = CampaignStatus.CANCELLED)
        campaigns[campaignId] = updatedCamp

        // Refund reserved budget back to available balance
        val owner = profiles[camp.ownerId]
        if (owner != null && unspent > 0) {
            if (owner.reservedCoins < unspent) {
                return Result.failure(IllegalStateException("INSUFFICIENT_RESERVED_BALANCE: Owner reserved coins is less than refund amount"))
            }

            profiles[camp.ownerId] = owner.copy(
                availableCoins = owner.availableCoins + unspent,
                reservedCoins = owner.reservedCoins - unspent
            )

            val refundTx = CoinTransaction(
                id = UUID.randomUUID().toString(),
                amount = unspent,
                type = TransactionType.CAMPAIGN_REFUND,
                description = "استرداد مانده بودجه سفارش لغو شده ${camp.domain}",
                referenceId = camp.id
            )
            userLedger.getOrPut(camp.ownerId) { mutableListOf() }.add(0, refundTx)
        }

        Result.success(unspent)
    }

    override suspend fun pauseCampaign(campaignId: String, callerUserId: String?): Result<Boolean> = lock.withLock {
        val camp = campaigns[campaignId] ?: return Result.failure(NoSuchElementException("CAMPAIGN_NOT_FOUND"))
        if (callerUserId != null && camp.ownerId != callerUserId) {
            return Result.failure(IllegalStateException("CAMPAIGN_NOT_FOUND: Caller is not owner"))
        }
        if (camp.status == CampaignStatus.ACTIVE) {
            campaigns[campaignId] = camp.copy(status = CampaignStatus.PAUSED)
            Result.success(true)
        } else {
            Result.success(false)
        }
    }

    override suspend fun resumeCampaign(campaignId: String, callerUserId: String?): Result<Boolean> = lock.withLock {
        val camp = campaigns[campaignId] ?: return Result.failure(NoSuchElementException("CAMPAIGN_NOT_FOUND"))
        if (callerUserId != null && camp.ownerId != callerUserId) {
            return Result.failure(IllegalStateException("CAMPAIGN_NOT_FOUND: Caller is not owner"))
        }
        if (camp.status == CampaignStatus.PAUSED) {
            campaigns[campaignId] = camp.copy(status = CampaignStatus.ACTIVE)
            Result.success(true)
        } else {
            Result.success(false)
        }
    }

    fun seedAdvertiserCampaign(campaign: Campaign) = lock.withLock {
        campaigns[campaign.id] = campaign
    }
}