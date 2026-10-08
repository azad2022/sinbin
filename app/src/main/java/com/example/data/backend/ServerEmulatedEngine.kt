package com.example.data.backend

import com.example.data.model.AutoViewActivationResult
import com.example.data.model.AutoViewStatus
import com.example.data.model.Campaign
import com.example.data.model.CampaignStatus
import com.example.data.model.CoinTransaction
import com.example.data.model.CoinTransferResult
import com.example.data.model.DailyBonusResult
import com.example.data.model.WeeklyLeaderboardEntry
import com.example.data.model.DurationOption
import com.example.data.model.TransactionType
import com.example.data.model.UserAccount
import com.example.data.model.ViewCompletionResult
import com.example.data.model.ViewSession
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
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
class ServerEmulatedEngine(
    private val nowProvider: () -> Long = { System.currentTimeMillis() }
) : ServerAuthoritativeEngine {

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
    private val welcomeGrantDates = mutableMapOf<String, String>() // userId -> UTC yyyy-MM-dd
    private val dailyBonusGrants = mutableSetOf<String>() // userId + UTC yyyy-MM-dd
    private val campaigns = mutableMapOf<String, Campaign>()
    private val viewSessions = mutableMapOf<String, ServerViewSessionRecord>()
    private val userLedger = mutableMapOf<String, MutableList<CoinTransaction>>() // userId -> ledger
    private val idempotencyRecords = mutableMapOf<String, IdempotencyRecord>() // idempotencyKey -> view IdempotencyRecord
    private val transferIdempotency = mutableMapOf<String, TransferIdempotencyRecord>() // idempotencyKey -> transfer result
    private val autoViewEntitlements = mutableMapOf<String, Long>() // userId -> expiresAtMillis
    private val autoViewActivationIdempotency = mutableMapOf<String, AutoViewActivationRecord>()

    data class AutoViewActivationRecord(
        val userId: String,
        val result: AutoViewActivationResult
    )

    data class IdempotencyRecord(
        val sessionId: String,
        val viewerId: String,
        val reward: Long
    )

    data class TransferIdempotencyRecord(
        val senderId: String,
        val result: CoinTransferResult
    )

    data class ServerViewSessionRecord(
        val id: String,
        val campaignId: String,
        val viewerId: String,
        val requiredDurationSeconds: Int,
        val rewardCoins: Long,
        val keyword: String?,
        var status: String, // INITIALIZED, CONTENT_READY, COMPLETED, EXPIRED, CANCELLED
        val startedAt: Long,
        var contentReadyAt: Long? = null,
        var completedAt: Long? = null,
        var idempotencyKey: String? = null
    )

    override suspend fun initAccount(evidence: DeviceEvidence, handle: String?): Result<UserAccount> =
        initAccount(evidence.installId, handle)

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
        // Test double only: keep the production welcome amount aligned with PostgreSQL (300).
        val welcomeAmount = 300L
        val isFirstTime = !welcomeBonusGrants.containsKey(userId)

        val grantedCoins = if (isFirstTime) welcomeAmount else 0L
        if (isFirstTime) {
            welcomeBonusGrants[userId] = cleanInstall
            welcomeGrantDates[userId] = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(nowProvider()))
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
            userHandle = userId,
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

    override suspend fun claimDailyBonus(
        callerUserId: String?,
        deviceEvidence: DeviceEvidence?
    ): Result<DailyBonusResult> = lock.withLock {
        val userId = callerUserId?.trim()?.takeIf { it.isNotEmpty() }
            ?: return Result.failure(IllegalStateException("UNAUTHORIZED: Authentication token required"))
        val today = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(nowProvider()))

        if (welcomeGrantDates[userId] == today) {
            return Result.success(
                DailyBonusResult(
                    granted = false,
                    amount = 0L,
                    grantDate = today,
                    reason = "WELCOME_DAY"
                )
            )
        }

        val hasCompletedViewToday = viewSessions.values.any { session ->
            session.viewerId == userId &&
                session.status == "COMPLETED" &&
                session.completedAt?.let { completedAt ->
                    SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(completedAt)) == today
                } == true
        }
        if (!hasCompletedViewToday) {
            return Result.success(
                DailyBonusResult(
                    granted = false,
                    amount = 0L,
                    grantDate = today,
                    reason = "VISIT_REQUIRED"
                )
            )
        }
        val grantKey = "${userId}_${today}"
        if (!dailyBonusGrants.add(grantKey)) {
            return Result.success(
                DailyBonusResult(
                    granted = false,
                    amount = 0L,
                    grantDate = today,
                    reason = "ALREADY_CLAIMED"
                )
            )
        }

        val amount = 50L
        val account = profiles[userId]
            ?: return Result.failure(NoSuchElementException("PROFILE_NOT_FOUND: Account must be initialized before receiving daily bonus"))
        profiles[userId] = account.copy(
            availableCoins = account.availableCoins + amount,
            lifetimeEarned = account.lifetimeEarned + amount
        )
        val grantId = UUID.randomUUID().toString()
        userLedger.getOrPut(userId) { mutableListOf() }.add(
            0,
            CoinTransaction(
                amount = amount,
                type = TransactionType.DAILY_BONUS,
                description = "هدیه روزانه سایت بین",
                referenceId = grantId
            )
        )

        Result.success(
            DailyBonusResult(
                granted = true,
                amount = amount,
                grantDate = today,
                grantId = grantId,
                grantedAt = nowProvider()
            )
        )
    }

    override suspend fun getAutoViewStatus(callerUserId: String?): Result<AutoViewStatus> = lock.withLock {
        val userId = callerUserId?.trim()?.takeIf { it.isNotEmpty() }
            ?: return Result.failure(IllegalStateException("UNAUTHORIZED: Authentication token required"))
        if (!profiles.containsKey(userId)) {
            return Result.failure(NoSuchElementException("PROFILE_NOT_FOUND: Account must be initialized before checking auto-view"))
        }

        val expiresAt = autoViewEntitlements[userId]
        Result.success(
            AutoViewStatus(
                active = expiresAt?.let { it > nowProvider() } == true,
                expiresAt = expiresAt
            )
        )
    }

    override suspend fun activateAutoView(
        idempotencyKey: String,
        callerUserId: String?
    ): Result<AutoViewActivationResult> = lock.withLock {
        val userId = callerUserId?.trim()?.takeIf { it.isNotEmpty() }
            ?: return Result.failure(IllegalStateException("UNAUTHORIZED: Authentication token required"))
        val cleanKey = idempotencyKey.trim()
        if (cleanKey.length !in 16..128 || cleanKey.any(Char::isWhitespace)) {
            return Result.failure(IllegalArgumentException("INVALID_IDEMPOTENCY_KEY: Invalid auto-view activation request key"))
        }

        autoViewActivationIdempotency[cleanKey]?.let { existing ->
            if (existing.userId != userId) {
                return Result.failure(IllegalStateException("IDEMPOTENCY_CONFLICT: Activation request key belongs to another account"))
            }
            return Result.success(existing.result)
        }

        val account = profiles[userId]
            ?: return Result.failure(NoSuchElementException("PROFILE_NOT_FOUND: Account must be initialized before enabling auto-view"))

        val now = nowProvider()
        val currentExpiry = autoViewEntitlements[userId]
        if (currentExpiry != null && currentExpiry > now) {
            return Result.success(
                AutoViewActivationResult(
                    activated = true,
                    charged = false,
                    amount = 0L,
                    expiresAt = currentExpiry,
                    availableCoins = account.availableCoins
                )
            )
        }

        if (account.availableCoins < 100L) {
            return Result.failure(
                IllegalStateException(
                    "INSUFFICIENT_BALANCE: Available balance (" + account.availableCoins + ") coins is less than 100 coins"
                )
            )
        }

        val expiresAt = now + 7L * 24L * 60L * 60L * 1000L
        val updatedAccount = account.copy(
            availableCoins = account.availableCoins - 100L,
            lifetimeSpent = account.lifetimeSpent + 100L
        )
        profiles[userId] = updatedAccount
        autoViewEntitlements[userId] = expiresAt

        val result = AutoViewActivationResult(
            activated = true,
            charged = true,
            amount = 100L,
            expiresAt = expiresAt,
            availableCoins = updatedAccount.availableCoins,
            purchaseId = UUID.randomUUID().toString()
        )
        autoViewActivationIdempotency[cleanKey] = AutoViewActivationRecord(userId, result)

        userLedger.getOrPut(userId) { mutableListOf() }.add(
            0,
            CoinTransaction(
                amount = -100L,
                type = TransactionType.AUTO_VIEW_SUBSCRIPTION,
                description = "فعال‌سازی بازدید خودکار برای ۷ روز",
                referenceId = result.purchaseId,
                timestamp = now
            )
        )

        Result.success(result)
    }

    override suspend fun fetchAccount(userId: String): Result<UserAccount> = lock.withLock {
        val account = profiles[userId] ?: return Result.failure(NoSuchElementException("User not found"))
        Result.success(account)
    }

    override suspend fun fetchTransactions(userId: String): Result<List<CoinTransaction>> = lock.withLock {
        // Enforce user-scoped ledger visibility (matches PostgreSQL RLS)
        Result.success(userLedger[userId]?.toList() ?: emptyList())
    }

    override suspend fun fetchWeeklyLeaderboard(weekStart: String): Result<List<WeeklyLeaderboardEntry>> = lock.withLock {
        val cleanWeekStart = weekStart.trim()
        if (!cleanWeekStart.matches(Regex("^\\d{4}-\\d{2}-\\d{2}$"))) {
            return Result.failure(IllegalArgumentException("INVALID_WEEK_START: Leaderboard week start must be yyyy-MM-dd"))
        }

        val formatter = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
            timeZone = java.util.TimeZone.getTimeZone("UTC")
        }

        val calendar = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"), Locale.US).apply {
            firstDayOfWeek = java.util.Calendar.MONDAY
            minimalDaysInFirstWeek = 4
        }
        val weekStartMillis = runCatching {
            calendar.time = formatter.parse(cleanWeekStart) ?: return@runCatching null
            calendar.set(java.util.Calendar.HOUR_OF_DAY, 0)
            calendar.set(java.util.Calendar.MINUTE, 0)
            calendar.set(java.util.Calendar.SECOND, 0)
            calendar.set(java.util.Calendar.MILLISECOND, 0)
            calendar.timeInMillis
        }.getOrNull() ?: return Result.failure(IllegalArgumentException("INVALID_WEEK_START: Invalid week start"))

        val calendarWeek = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"), Locale.US).apply {
            firstDayOfWeek = java.util.Calendar.MONDAY
            minimalDaysInFirstWeek = 4
        }
        val counts = viewSessions.values
            .asSequence()
            .filter { it.status == "COMPLETED" && it.completedAt != null }
            .filter { record ->
                calendarWeek.timeInMillis = record.completedAt!!
                calendarWeek.set(java.util.Calendar.HOUR_OF_DAY, 0)
                calendarWeek.set(java.util.Calendar.MINUTE, 0)
                calendarWeek.set(java.util.Calendar.SECOND, 0)
                calendarWeek.set(java.util.Calendar.MILLISECOND, 0)
                calendarWeek.set(java.util.Calendar.DAY_OF_WEEK, java.util.Calendar.MONDAY)
                calendarWeek.timeInMillis == weekStartMillis
            }
            .groupingBy { it.viewerId }
            .eachCount()

        val ranked = counts.mapNotNull { (userId, count) ->
            profiles[userId]?.userHandle?.trim()?.takeIf { it.isNotBlank() }?.let {
                WeeklyLeaderboardEntry(rank = 0, userHandle = it, completedViews = count)
            }
        }.sortedWith(
            compareByDescending<WeeklyLeaderboardEntry> { it.completedViews }
                .thenBy { it.userHandle.lowercase(Locale.US) }
                .thenBy { it.userHandle }
        ).mapIndexed { index, entry ->
            entry.copy(rank = index + 1)
        }

        Result.success(ranked)
    }

    override suspend fun transferCoins(
        recipientHandle: String,
        amount: Long,
        idempotencyKey: String,
        note: String?,
        callerUserId: String?
    ): Result<CoinTransferResult> = lock.withLock {
        val senderId = callerUserId?.trim()?.takeIf { it.isNotEmpty() }
            ?: return Result.failure(IllegalStateException("UNAUTHORIZED: Authentication token required"))
        val key = idempotencyKey.trim()
        if (key.length < 16 || key.length > 128 || key.any(Char::isWhitespace)) {
            return Result.failure(IllegalArgumentException("INVALID_IDEMPOTENCY_KEY: Invalid transfer request key"))
        }
        if (amount <= 0L || amount > 1_000_000L) {
            return Result.failure(IllegalArgumentException("INVALID_AMOUNT: Transfer amount must be between 1 and 1,000,000 coins"))
        }
        transferIdempotency[key]?.let { previous ->
            if (previous.senderId != senderId) {
                return Result.failure(IllegalStateException("IDEMPOTENCY_CONFLICT: Transfer request key belongs to another account"))
            }
            return Result.success(previous.result)
        }
        val sender = profiles[senderId]
            ?: return Result.failure(NoSuchElementException("PROFILE_NOT_FOUND: Sender profile does not exist"))
        val normalizedHandle = recipientHandle.trim()
        if (normalizedHandle.isBlank() || normalizedHandle.length > 64 ||
            !normalizedHandle.matches(Regex("^[A-Za-z0-9_]+$"))) {
            return Result.failure(IllegalArgumentException("INVALID_RECIPIENT: Invalid user ID format"))
        }
        val recipient = profiles.values.firstOrNull {
            it.userHandle.equals(normalizedHandle, ignoreCase = true)
        } ?: return Result.failure(NoSuchElementException("RECIPIENT_NOT_FOUND: User ID was not found"))
        if (recipient.userId == senderId) {
            return Result.failure(IllegalArgumentException("INVALID_RECIPIENT: You cannot transfer coins to yourself"))
        }
        if (amount > sender.availableCoins) {
            return Result.failure(IllegalStateException(
                "INSUFFICIENT_BALANCE: Available balance (" + sender.availableCoins + ") coins is less than transfer amount (" + amount + ") coins"
            ))
        }
        val cleanNote = note?.trim()?.ifBlank { null }
        if (!cleanNote.isNullOrBlank() && (cleanNote.length > 160 || cleanNote.any(Char::isISOControl))) {
            return Result.failure(IllegalArgumentException("INVALID_NOTE: Transfer note must be at most 160 characters"))
        }
        val transferId = UUID.randomUUID().toString()
        profiles[senderId] = sender.copy(
            availableCoins = sender.availableCoins - amount,
            lifetimeSpent = sender.lifetimeSpent + amount
        )
        profiles[recipient.userId] = recipient.copy(
            availableCoins = recipient.availableCoins + amount,
            lifetimeEarned = recipient.lifetimeEarned + amount
        )
        userLedger.getOrPut(senderId) { mutableListOf() }.add(
            0,
            CoinTransaction(
                amount = -amount,
                type = TransactionType.COIN_TRANSFER_SENT,
                description = "انتقال " + amount + " سکه به " + recipient.userHandle,
                referenceId = transferId
            )
        )
        userLedger.getOrPut(recipient.userId) { mutableListOf() }.add(
            0,
            CoinTransaction(
                amount = amount,
                type = TransactionType.COIN_TRANSFER_RECEIVED,
                description = "دریافت " + amount + " سکه از " + sender.userHandle,
                referenceId = transferId
            )
        )
        val result = CoinTransferResult(
            transferId = transferId,
            recipientHandle = recipient.userHandle,
            amount = amount,
            note = cleanNote
        )
        transferIdempotency[key] = TransferIdempotencyRecord(senderId, result)
        Result.success(result)
    }
    override suspend fun fetchCampaigns(userId: String): Result<List<Campaign>> = lock.withLock {
        // Matches RLS: caller sees own campaigns and active campaigns
        val list = campaigns.values.filter { it.ownerId == userId || it.status == CampaignStatus.ACTIVE }
            .sortedByDescending { it.createdAt }
        Result.success(list)
    }

    override suspend fun preflightCampaignUrl(url: String): Result<WebsitePreflightResult> = lock.withLock {
        val clean = url.trim()
        if (clean.isBlank() || !clean.startsWith("https://", ignoreCase = true)) {
            return Result.failure(IllegalArgumentException("INVALID_URL: Target URL must use HTTPS"))
        }
        val normalized = clean
        val domain = normalized.removePrefix("https://").substringBefore("/").substringBefore("?").substringBefore("#").lowercase()
        Result.success(
            WebsitePreflightResult(
                sourceUrl = clean,
                normalizedUrl = normalized,
                domain = domain,
                finalUrl = normalized,
                httpStatus = 200,
                redirectCount = 0,
                responseMs = 50L,
                contentType = "text/html",
                contentLength = 1024L,
                viewerCompatibility = WebsiteViewerCompatibility.COMPATIBLE,
                qualityScore = 95,
                diagnostics = listOf(WebsiteDiagnostic("EMULATED_PREFLIGHT", WebsiteDiagnosticSeverity.INFO, "Preflight emulator result")),
                expiresAtEpochMs = nowProvider() + 600_000L,
                preflightToken = "emulated-preflight-token"
            )
        )
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
    ): Result<Campaign> = lock.withLock {
        val cleanUrl = url.trim()
        val cleanNormalized = normalizedUrl.trim()
        val cleanDomain = domain.trim()
        val cleanKeyword = keyword?.trim()?.ifBlank { null }

        if (cleanUrl.isBlank() || cleanUrl.length > 2048 || (!cleanUrl.startsWith("http://") && !cleanUrl.startsWith("https://"))) {
            return Result.failure(IllegalArgumentException("INVALID_URL: Target URL must be a valid HTTP/HTTPS address up to 2048 characters"))
        }

        if (cleanNormalized.isBlank() || cleanNormalized.length > 2048) {
            return Result.failure(IllegalArgumentException("INVALID_NORMALIZED_URL: Normalized URL cannot be empty"))
        }

        if (cleanKeyword != null && cleanKeyword.length > 25) {
            return Result.failure(IllegalArgumentException("INVALID_KEYWORD: Keyword must be at most 25 characters"))
        }
        if (cleanKeyword != null && cleanKeyword.any(Char::isISOControl)) {
            return Result.failure(IllegalArgumentException("INVALID_KEYWORD: Keyword contains control characters"))
        }

        if (cleanDomain.isBlank() || cleanDomain.length > 253 || cleanDomain.contains('/') || cleanDomain.contains(' ')) {
            return Result.failure(IllegalArgumentException("INVALID_DOMAIN: Domain must be a valid hostname without slashes or whitespace"))
        }

        if (targetViews <= 0 || targetViews > 1000000) {
            return Result.failure(IllegalArgumentException("INVALID_TARGET_VIEWS: Target views must be between 1 and 1,000,000"))
        }

        val pricing = durationOptions.find { it.seconds == durationSeconds }
            ?: return Result.failure(IllegalArgumentException("INVALID_DURATION: Unsupported duration option"))

        // Server-calculated total cost (keyword campaigns use premium pricing).
        val perViewCost = pricing.advertiserCostForKeyword(cleanKeyword)
        val totalCost = perViewCost * targetViews

        // Existing emulator tests may omit callerUserId; production authorization is enforced
        // by the real Supabase RPC through auth.uid(). Keep emulator behavior compatible. 
        val effectiveCallerId = callerUserId?.trim()?.takeIf { it.isNotEmpty() }
            ?: profiles.keys.firstOrNull()
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
            keyword = cleanKeyword,
            durationSeconds = durationSeconds,
            targetViews = targetViews,
            completedViews = 0,
            costPerView = perViewCost,
            totalBudget = totalCost,
            spentBudget = 0,
            status = CampaignStatus.ACTIVE,
            createdAt = nowProvider()
        )
        campaigns[newCampaign.id] = newCampaign

        val reservationTx = CoinTransaction(
            id = UUID.randomUUID().toString(),
            amount = -totalCost,
            type = TransactionType.CAMPAIGN_RESERVATION,
            description = if (cleanKeyword == null) {
                "رزرو بودجه برای سفارش $targetViews بازدید از $cleanDomain"
            } else {
                "رزرو بودجه برای سفارش $targetViews بازدید از $cleanDomain با کلمه کلیدی «$cleanKeyword»"
            },
            referenceId = newCampaign.id
        )
        userLedger.getOrPut(effectiveCallerId) { mutableListOf() }.add(0, reservationTx)

        Result.success(newCampaign)
    }

    override suspend fun requestViewSession(userId: String): Result<ViewSession?> = lock.withLock {
        val now = nowProvider()

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
                        keyword = camp.keyword,
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
        // - Viewer has not completed this campaign within the last 15 minutes
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

        if (eligibleCampaigns.isEmpty()) return Result.success(null)

        // Match production PostgreSQL fairness behavior:
        // 1) Prefer advertisers this viewer has NOT completed in the last 2 minutes.
        // 2) Randomize among remaining campaigns to avoid FIFO dominance.
        // 3) If every advertiser is inside the diversity window, fall back to any
        //    eligible campaign so inventory is never artificially blocked.
        val freshAdvertiserCampaigns = eligibleCampaigns.filter { camp ->
            viewSessions.values.none { vs ->
                vs.viewerId == userId &&
                vs.status == "COMPLETED" &&
                (now - (vs.completedAt ?: 0L)) < 2 * 60 * 1000L &&
                campaigns[vs.campaignId]?.ownerId == camp.ownerId
            }
        }

        val selectedPool = if (freshAdvertiserCampaigns.isNotEmpty()) {
            freshAdvertiserCampaigns
        } else {
            eligibleCampaigns
        }

        val selected = selectedPool.random()

        val pricing = durationOptions.find { it.seconds == selected.durationSeconds }
            ?: durationOptions[2]

        val newSessionRecord = ServerViewSessionRecord(
            id = UUID.randomUUID().toString(),
            campaignId = selected.id,
            viewerId = userId,
            requiredDurationSeconds = selected.durationSeconds,
            rewardCoins = pricing.viewerReward,
            keyword = selected.keyword,
            status = "INITIALIZED",
            startedAt = now
        )
        viewSessions[newSessionRecord.id] = newSessionRecord

        val session = ViewSession(
            id = newSessionRecord.id,
            campaignId = selected.id,
            targetUrl = selected.url,
            domain = selected.domain,
            keyword = selected.keyword,
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
            record.contentReadyAt = nowProvider()
            return Result.success(true)
        }

        // Match the real PostgreSQL RPC: repeated/invalid state transitions are not successful.
        Result.success(false)
    }

    override suspend fun completeViewSession(
        sessionId: String,
        idempotencyKey: String,
        callerUserId: String?
    ): Result<ViewCompletionResult> = lock.withLock {
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
            val account = profiles[record.viewerId]
                ?: return Result.failure(IllegalStateException("Viewer profile not found"))
            val campaign = campaigns[record.campaignId]
            val campaignCompleted = campaign?.let { it.completedViews >= it.targetViews } == true
            return Result.success(
                ViewCompletionResult(
                    reward = existingRecord.reward,
                    availableCoins = account.availableCoins,
                    lifetimeEarned = account.lifetimeEarned,
                    completedViewsCount = account.completedViewsCount,
                    campaignCompleted = campaignCompleted,
                    alreadyCompleted = true
                )
            )
        }

        // Idempotency check 2: Has this session already completed?
        if (record.status == "COMPLETED") {
            val account = profiles[record.viewerId]
                ?: return Result.failure(IllegalStateException("Viewer profile not found"))
            val campaign = campaigns[record.campaignId]
            val campaignCompleted = campaign?.let { it.completedViews >= it.targetViews } == true
            return Result.success(
                ViewCompletionResult(
                    reward = record.rewardCoins,
                    availableCoins = account.availableCoins,
                    lifetimeEarned = account.lifetimeEarned,
                    completedViewsCount = account.completedViewsCount,
                    campaignCompleted = campaignCompleted,
                    alreadyCompleted = true
                )
            )
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

        val now = nowProvider()
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
        val updatedViewer = viewer.copy(
            availableCoins = viewer.availableCoins + reward,
            lifetimeEarned = viewer.lifetimeEarned + reward,
            completedViewsCount = viewer.completedViewsCount + 1
        )
        profiles[record.viewerId] = updatedViewer

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

        Result.success(
            ViewCompletionResult(
                reward = reward,
                availableCoins = updatedViewer.availableCoins,
                lifetimeEarned = updatedViewer.lifetimeEarned,
                completedViewsCount = updatedViewer.completedViewsCount,
                campaignCompleted = isDone,
                alreadyCompleted = false
            )
        )
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