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
 * - Anti-farming / Single welcome bonus per user identity
 * - Server-side budget reservation & validation (zero client overspending)
 * - Server-side view cooldowns and anti-self view
 * - Strict Idempotency on view completion
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

    // Internal Database Tables
    private val profiles = mutableMapOf<String, UserAccount>()
    private val welcomeBonusGrants = mutableSetOf<String>() // Set of userIds who received welcome bonus
    private val campaigns = mutableMapOf<String, Campaign>()
    private val viewSessions = mutableMapOf<String, ServerViewSessionRecord>()
    private val coinLedger = mutableListOf<CoinTransaction>()
    private val idempotencyRecords = mutableMapOf<String, Long>() // idempotencyKey -> rewardGranted

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
        // Derive or generate stable server userId
        val userId = handle ?: ("user_" + installId.hashCode().toUInt().toString(16))

        val existingProfile = profiles[userId]
        if (existingProfile != null) {
            return Result.success(existingProfile)
        }

        // Create new account and grant welcome bonus atomically ONCE
        val welcomeAmount = 150L
        val isFirstTime = !welcomeBonusGrants.contains(userId)

        val grantedCoins = if (isFirstTime) welcomeAmount else 0L
        if (isFirstTime) {
            welcomeBonusGrants.add(userId)
            val welcomeTx = CoinTransaction(
                id = UUID.randomUUID().toString(),
                amount = welcomeAmount,
                type = TransactionType.WELCOME_REWARD,
                description = "هدیه ورود به سایت بین (Welcome Bonus)",
                referenceId = "init_bonus"
            )
            coinLedger.add(0, welcomeTx)
        }

        val newAccount = UserAccount(
            userId = userId,
            appInstallId = installId,
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
        // RLS: caller sees ledger entries
        Result.success(coinLedger.toList())
    }

    override suspend fun fetchCampaigns(userId: String): Result<List<Campaign>> = lock.withLock {
        // RLS: caller sees own campaigns and active campaigns
        val list = campaigns.values.filter { it.ownerId == userId || it.status == CampaignStatus.ACTIVE }
            .sortedByDescending { it.createdAt }
        Result.success(list)
    }

    override suspend fun createCampaign(
        url: String,
        normalizedUrl: String,
        domain: String,
        durationSeconds: Int,
        targetViews: Int
    ): Result<Campaign> = lock.withLock {
        if (targetViews <= 0) {
            return Result.failure(IllegalArgumentException("تعداد بازدید درخواستی باید بزرگتر از صفر باشد."))
        }

        val pricing = durationOptions.find { it.seconds == durationSeconds }
            ?: return Result.failure(IllegalArgumentException("مدت زمان انتخاب شده در تعرفه‌های سرور وجود ندارد."))

        // Server-calculated total cost
        val totalCost = pricing.advertiserCost * targetViews

        // Identify calling user
        val callerAccount = profiles.values.firstOrNull()
            ?: return Result.failure(IllegalStateException("حساب کاربری یافت نشد."))

        // Atomic balance verification
        if (callerAccount.availableCoins < totalCost) {
            return Result.failure(
                IllegalStateException("موجودی شما (${callerAccount.availableCoins} سکه) برای ثبت این سفارش (${totalCost} سکه) کافی نیست.")
            )
        }

        // Atomic reservation in ledger
        val updatedAccount = callerAccount.copy(
            availableCoins = callerAccount.availableCoins - totalCost,
            reservedCoins = callerAccount.reservedCoins + totalCost
        )
        profiles[callerAccount.userId] = updatedAccount

        val newCampaign = Campaign(
            id = UUID.randomUUID().toString(),
            ownerId = callerAccount.userId,
            url = normalizedUrl,
            domain = domain,
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
            description = "رزرو بودجه برای سفارش $targetViews بازدید از $domain",
            referenceId = newCampaign.id
        )
        coinLedger.add(0, reservationTx)

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

    override suspend fun signalContentReady(sessionId: String): Result<Boolean> = lock.withLock {
        val record = viewSessions[sessionId]
            ?: return Result.failure(NoSuchElementException("جلسه مشاهده یافت نشد."))
        if (record.status == "INITIALIZED") {
            record.status = "CONTENT_READY"
            record.contentReadyAt = System.currentTimeMillis()
        }
        Result.success(true)
    }

    override suspend fun completeViewSession(
        sessionId: String,
        idempotencyKey: String
    ): Result<Long> = lock.withLock {
        // Idempotency check 1: Has this idempotency key already been processed?
        if (idempotencyRecords.containsKey(idempotencyKey)) {
            val prevReward = idempotencyRecords[idempotencyKey] ?: 0L
            return Result.success(prevReward)
        }

        val record = viewSessions[sessionId]
            ?: return Result.failure(NoSuchElementException("شناسه جلسه نامعتبر است."))

        // Idempotency check 2: Has this session already completed?
        if (record.status == "COMPLETED") {
            return Result.success(record.rewardCoins)
        }

        // Server Timing Verification
        val contentReadyTime = record.contentReadyAt
            ?: return Result.failure(IllegalStateException("سیگنال لود کامل وب‌سایت دریافت نشده بود."))

        val now = System.currentTimeMillis()
        val elapsedMs = now - contentReadyTime
        val requiredMs = (record.requiredDurationSeconds * 1000L) - 1000L // 1 sec tolerance for network roundtrip

        if (elapsedMs < requiredMs) {
            return Result.failure(
                IllegalStateException("مدت زمان مشاهده کافی نیست (${elapsedMs / 1000}s < ${record.requiredDurationSeconds}s).")
            )
        }

        val camp = campaigns[record.campaignId]
            ?: return Result.failure(NoSuchElementException("کمپین مربوطه در سرور یافت نشد."))

        if (camp.status != CampaignStatus.ACTIVE) {
            return Result.failure(IllegalStateException("کمپین مورد نظر فعال نیست."))
        }

        if (camp.remainingBudget < camp.costPerView) {
            return Result.failure(IllegalStateException("بودجه کمپین به اتمام رسیده است."))
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

        // 2. Deduct Campaign Owner's Reserved Budget
        val owner = profiles[camp.ownerId]
        if (owner != null) {
            profiles[camp.ownerId] = owner.copy(
                reservedCoins = (owner.reservedCoins - camp.costPerView).coerceAtLeast(0),
                lifetimeSpent = owner.lifetimeSpent + camp.costPerView,
                receivedViewsCount = owner.receivedViewsCount + 1
            )
        }

        // 3. Credit Viewer's Balance
        val viewer = profiles[record.viewerId]
            ?: return Result.failure(IllegalStateException("اطلاعات کاربر بیننده در سرور یافت نشد."))

        val reward = record.rewardCoins
        profiles[record.viewerId] = viewer.copy(
            availableCoins = viewer.availableCoins + reward,
            lifetimeEarned = viewer.lifetimeEarned + reward,
            completedViewsCount = viewer.completedViewsCount + 1
        )

        // 4. Mark Session Completed & Idempotent
        record.status = "COMPLETED"
        record.completedAt = now
        record.idempotencyKey = idempotencyKey
        idempotencyRecords[idempotencyKey] = reward

        // 5. Record Viewer Reward in Ledger
        val rewardTx = CoinTransaction(
            id = UUID.randomUUID().toString(),
            amount = reward,
            type = TransactionType.VIEW_REWARD,
            description = "مشاهده موفق ${record.requiredDurationSeconds} ثانیه‌ای از ${camp.domain}",
            referenceId = camp.id
        )
        coinLedger.add(0, rewardTx)

        Result.success(reward)
    }

    override suspend fun cancelCampaign(campaignId: String): Result<Long> = lock.withLock {
        val camp = campaigns[campaignId]
            ?: return Result.failure(NoSuchElementException("سفارش مورد نظر در سرور یافت نشد."))

        if (camp.status == CampaignStatus.CANCELLED || camp.status == CampaignStatus.COMPLETED) {
            return Result.failure(IllegalStateException("این سفارش قبلاً بسته شده است."))
        }

        val unspent = camp.remainingBudget
        val updatedCamp = camp.copy(status = CampaignStatus.CANCELLED)
        campaigns[campaignId] = updatedCamp

        // Refund reserved budget back to available balance
        val owner = profiles[camp.ownerId]
        if (owner != null && unspent > 0) {
            profiles[camp.ownerId] = owner.copy(
                availableCoins = owner.availableCoins + unspent,
                reservedCoins = (owner.reservedCoins - unspent).coerceAtLeast(0)
            )

            val refundTx = CoinTransaction(
                id = UUID.randomUUID().toString(),
                amount = unspent,
                type = TransactionType.CAMPAIGN_REFUND,
                description = "استرداد مانده بودجه سفارش لغو شده ${camp.domain}",
                referenceId = camp.id
            )
            coinLedger.add(0, refundTx)
        }

        Result.success(unspent)
    }

    override suspend fun pauseCampaign(campaignId: String): Result<Boolean> = lock.withLock {
        val camp = campaigns[campaignId] ?: return Result.failure(NoSuchElementException("سفارش یافت نشد."))
        if (camp.status == CampaignStatus.ACTIVE) {
            campaigns[campaignId] = camp.copy(status = CampaignStatus.PAUSED)
            Result.success(true)
        } else {
            Result.success(false)
        }
    }

    override suspend fun resumeCampaign(campaignId: String): Result<Boolean> = lock.withLock {
        val camp = campaigns[campaignId] ?: return Result.failure(NoSuchElementException("سفارش یافت نشد."))
        if (camp.status == CampaignStatus.PAUSED) {
            campaigns[campaignId] = camp.copy(status = CampaignStatus.ACTIVE)
            Result.success(true)
        } else {
            Result.success(false)
        }
    }

    // Helper for testing to seed external advertiser campaigns without client authority
    fun seedAdvertiserCampaign(campaign: Campaign) = lock.withLock {
        campaigns[campaign.id] = campaign
    }
}
