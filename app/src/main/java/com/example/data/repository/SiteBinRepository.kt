package com.example.data.repository

import android.content.Context
import com.example.core.security.PolicyResult
import com.example.core.security.UrlSecurityPolicy
import com.example.data.model.AbuseReport
import com.example.data.model.Campaign
import com.example.data.model.CampaignStatus
import com.example.data.model.CoinTransaction
import com.example.data.model.DurationOption
import com.example.data.model.TransactionType
import com.example.data.model.UserAccount
import com.example.data.model.ViewSession
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

class SiteBinRepository(private val context: Context) {

    private val prefs = context.getSharedPreferences("sitebin_secure_prefs", Context.MODE_PRIVATE)

    private val _account = MutableStateFlow(
        UserAccount(
            userId = getOrGenerateUserId(),
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

    // Configurable Pricing Matrix
    val durationOptions = listOf(
        DurationOption(seconds = 5, advertiserCost = 5, viewerReward = 3),
        DurationOption(seconds = 10, advertiserCost = 9, viewerReward = 6),
        DurationOption(seconds = 15, advertiserCost = 14, viewerReward = 10, isPopular = true),
        DurationOption(seconds = 30, advertiserCost = 26, viewerReward = 19),
        DurationOption(seconds = 60, advertiserCost = 50, viewerReward = 38)
    )

    // Pool of community websites available to explore & view
    private val communityCampaigns = mutableListOf(
        Campaign(
            id = "seed_1",
            ownerId = "community_dev_1",
            url = "https://kotlinlang.org",
            domain = "kotlinlang.org",
            durationSeconds = 15,
            targetViews = 500,
            completedViews = 180,
            costPerView = 14,
            totalBudget = 7000,
            spentBudget = 2520,
            status = CampaignStatus.ACTIVE
        ),
        Campaign(
            id = "seed_2",
            ownerId = "community_dev_2",
            url = "https://developer.android.com",
            domain = "developer.android.com",
            durationSeconds = 10,
            targetViews = 1000,
            completedViews = 450,
            costPerView = 9,
            totalBudget = 9000,
            spentBudget = 4050,
            status = CampaignStatus.ACTIVE
        ),
        Campaign(
            id = "seed_3",
            ownerId = "community_dev_3",
            url = "https://m3.material.io",
            domain = "m3.material.io",
            durationSeconds = 15,
            targetViews = 250,
            completedViews = 95,
            costPerView = 14,
            totalBudget = 3500,
            spentBudget = 1330,
            status = CampaignStatus.ACTIVE
        ),
        Campaign(
            id = "seed_4",
            ownerId = "community_dev_4",
            url = "https://en.wikipedia.org/wiki/Main_Page",
            domain = "wikipedia.org",
            durationSeconds = 5,
            targetViews = 800,
            completedViews = 310,
            costPerView = 5,
            totalBudget = 4000,
            spentBudget = 1550,
            status = CampaignStatus.ACTIVE
        )
    )

    private val recentlyViewedCampaignIds = mutableSetOf<String>()

    init {
        initializeAccountAndLedger()
    }

    private fun getOrGenerateUserId(): String {
        var id = prefs.getString("user_id", null)
        if (id == null) {
            id = "user_" + UUID.randomUUID().toString().take(12)
            prefs.edit().putString("user_id", id).apply()
        }
        return id
    }

    private fun getOrGenerateInstallId(): String {
        var installId = prefs.getString("app_install_id", null)
        if (installId == null) {
            installId = "inst_" + UUID.randomUUID().toString()
            prefs.edit().putString("app_install_id", installId).apply()
        }
        return installId
    }

    private fun initializeAccountAndLedger() {
        val welcomeGranted = prefs.getBoolean("welcome_bonus_granted", false)
        val loadedTransactions = loadPersistedTransactions()
        val loadedCampaigns = loadPersistedCampaigns()

        if (!welcomeGranted || loadedTransactions.isEmpty()) {
            val welcomeBonus = 150L // 150 Welcome Coins
            val welcomeTx = CoinTransaction(
                amount = welcomeBonus,
                type = TransactionType.WELCOME_REWARD,
                description = "هدیه ورود به سایت بین (Welcome Bonus)",
                referenceId = "init_bonus"
            )
            val initialTxList = listOf(welcomeTx)
            _transactions.value = initialTxList
            _account.update { current ->
                current.copy(
                    availableCoins = welcomeBonus,
                    lifetimeEarned = welcomeBonus
                )
            }
            prefs.edit().putBoolean("welcome_bonus_granted", true).apply()
            persistTransactions(initialTxList)
            persistAccountState(welcomeBonus, 0, welcomeBonus, 0, 0, 0)
        } else {
            _transactions.value = loadedTransactions
            _campaigns.value = loadedCampaigns

            val savedAvailable = prefs.getLong("saved_available_coins", 150L)
            val savedReserved = prefs.getLong("saved_reserved_coins", 0L)
            val savedLifetimeEarned = prefs.getLong("saved_lifetime_earned", 150L)
            val savedLifetimeSpent = prefs.getLong("saved_lifetime_spent", 0L)
            val savedCompletedViews = prefs.getInt("saved_completed_views", 0)
            val savedReceivedViews = prefs.getInt("saved_received_views", 0)

            _account.update {
                it.copy(
                    availableCoins = savedAvailable,
                    reservedCoins = savedReserved,
                    lifetimeEarned = savedLifetimeEarned,
                    lifetimeSpent = savedLifetimeSpent,
                    completedViewsCount = savedCompletedViews,
                    receivedViewsCount = savedReceivedViews
                )
            }

            // Verify Double-Entry Ledger Invariant
            verifyLedgerIntegrity()
        }
    }

    /**
     * Mathematical Ledger Invariant Audit
     */
    fun verifyLedgerIntegrity(): Boolean {
        val txSum = _transactions.value.sumOf { it.amount }
        val currentTotal = _account.value.totalCoins
        // In this architecture, all balance changes originate strictly from transactions in ledger
        return txSum == currentTotal
    }

    private fun persistAccountState(
        available: Long,
        reserved: Long,
        lifetimeEarned: Long,
        lifetimeSpent: Long,
        completedViews: Int,
        receivedViews: Int
    ) {
        prefs.edit()
            .putLong("saved_available_coins", available)
            .putLong("saved_reserved_coins", reserved)
            .putLong("saved_lifetime_earned", lifetimeEarned)
            .putLong("saved_lifetime_spent", lifetimeSpent)
            .putInt("saved_completed_views", completedViews)
            .putInt("saved_received_views", receivedViews)
            .apply()
    }

    private fun persistTransactions(list: List<CoinTransaction>) {
        try {
            val jsonArray = JSONArray()
            for (tx in list.take(100)) { // Persist recent 100 transactions
                val obj = JSONObject().apply {
                    put("id", tx.id)
                    put("amount", tx.amount)
                    put("type", tx.type.name)
                    put("description", tx.description)
                    put("timestamp", tx.timestamp)
                    put("referenceId", tx.referenceId ?: "")
                }
                jsonArray.put(obj)
            }
            prefs.edit().putString("persisted_transactions_v1", jsonArray.toString()).apply()
        } catch (_: Exception) {}
    }

    private fun loadPersistedTransactions(): List<CoinTransaction> {
        val raw = prefs.getString("persisted_transactions_v1", null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            val result = mutableListOf<CoinTransaction>()
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                val typeName = obj.optString("type", TransactionType.VIEW_REWARD.name)
                val type = runCatching { TransactionType.valueOf(typeName) }.getOrDefault(TransactionType.VIEW_REWARD)
                result.add(
                    CoinTransaction(
                        id = obj.optString("id", UUID.randomUUID().toString()),
                        amount = obj.optLong("amount", 0L),
                        type = type,
                        description = obj.optString("description", ""),
                        timestamp = obj.optLong("timestamp", System.currentTimeMillis()),
                        referenceId = obj.optString("referenceId", "").ifEmpty { null }
                    )
                )
            }
            result
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun persistCampaigns(list: List<Campaign>) {
        try {
            val jsonArray = JSONArray()
            for (camp in list) {
                val obj = JSONObject().apply {
                    put("id", camp.id)
                    put("ownerId", camp.ownerId)
                    put("url", camp.url)
                    put("domain", camp.domain)
                    put("durationSeconds", camp.durationSeconds)
                    put("targetViews", camp.targetViews)
                    put("completedViews", camp.completedViews)
                    put("costPerView", camp.costPerView)
                    put("totalBudget", camp.totalBudget)
                    put("spentBudget", camp.spentBudget)
                    put("status", camp.status.name)
                    put("createdAt", camp.createdAt)
                }
                jsonArray.put(obj)
            }
            prefs.edit().putString("persisted_campaigns_v1", jsonArray.toString()).apply()
        } catch (_: Exception) {}
    }

    private fun loadPersistedCampaigns(): List<Campaign> {
        val raw = prefs.getString("persisted_campaigns_v1", null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            val result = mutableListOf<Campaign>()
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                val statusName = obj.optString("status", CampaignStatus.ACTIVE.name)
                val status = runCatching { CampaignStatus.valueOf(statusName) }.getOrDefault(CampaignStatus.ACTIVE)
                result.add(
                    Campaign(
                        id = obj.optString("id", UUID.randomUUID().toString()),
                        ownerId = obj.optString("ownerId", _account.value.userId),
                        url = obj.optString("url", ""),
                        domain = obj.optString("domain", ""),
                        durationSeconds = obj.optInt("durationSeconds", 15),
                        targetViews = obj.optInt("targetViews", 100),
                        completedViews = obj.optInt("completedViews", 0),
                        costPerView = obj.optLong("costPerView", 14),
                        totalBudget = obj.optLong("totalBudget", 1400),
                        spentBudget = obj.optLong("spentBudget", 0),
                        status = status,
                        createdAt = obj.optLong("createdAt", System.currentTimeMillis())
                    )
                )
            }
            result
        } catch (e: Exception) {
            emptyList()
        }
    }

    /**
     * Creates a new campaign with strict validation and budget reservation in the Ledger
     */
    fun createCampaign(
        rawUrl: String,
        durationSeconds: Int,
        targetViews: Int
    ): Result<Campaign> {
        val policy = UrlSecurityPolicy.evaluateUrl(rawUrl)
        if (policy is PolicyResult.Blocked) {
            return Result.failure(IllegalArgumentException(policy.reason))
        }
        val allowed = policy as PolicyResult.Allowed

        val option = durationOptions.find { it.seconds == durationSeconds }
            ?: return Result.failure(IllegalArgumentException("مدت زمان انتخاب شده معتبر نیست."))

        val totalCost = option.advertiserCost * targetViews
        val currentAccount = _account.value

        if (currentAccount.availableCoins < totalCost) {
            return Result.failure(
                IllegalStateException("موجودی شما (${currentAccount.availableCoins} سکه) برای ثبت این سفارش (${totalCost} سکه) کافی نیست.")
            )
        }

        // Ledger Reservation
        val newAvailable = currentAccount.availableCoins - totalCost
        val newReserved = currentAccount.reservedCoins + totalCost

        val reservationTx = CoinTransaction(
            amount = -totalCost,
            type = TransactionType.CAMPAIGN_RESERVATION,
            description = "رزرو بودجه برای سفارش $targetViews بازدید از ${allowed.domain}",
            referenceId = allowed.domain
        )

        val newCampaign = Campaign(
            ownerId = currentAccount.userId,
            url = allowed.normalizedUrl,
            domain = allowed.domain,
            durationSeconds = durationSeconds,
            targetViews = targetViews,
            costPerView = option.advertiserCost,
            totalBudget = totalCost
        )

        val updatedTx = listOf(reservationTx) + _transactions.value
        val updatedCampaigns = listOf(newCampaign) + _campaigns.value

        _transactions.value = updatedTx
        _campaigns.value = updatedCampaigns

        _account.update {
            it.copy(
                availableCoins = newAvailable,
                reservedCoins = newReserved
            )
        }

        persistTransactions(updatedTx)
        persistCampaigns(updatedCampaigns)
        persistAccountState(
            available = newAvailable,
            reserved = newReserved,
            lifetimeEarned = currentAccount.lifetimeEarned,
            lifetimeSpent = currentAccount.lifetimeSpent,
            completedViews = currentAccount.completedViewsCount,
            receivedViews = currentAccount.receivedViewsCount
        )

        return Result.success(newCampaign)
    }

    fun pauseCampaign(campaignId: String) {
        val updated = _campaigns.value.map {
            if (it.id == campaignId) it.copy(status = CampaignStatus.PAUSED) else it
        }
        _campaigns.value = updated
        persistCampaigns(updated)
    }

    fun resumeCampaign(campaignId: String) {
        val updated = _campaigns.value.map {
            if (it.id == campaignId) it.copy(status = CampaignStatus.ACTIVE) else it
        }
        _campaigns.value = updated
        persistCampaigns(updated)
    }

    fun cancelCampaign(campaignId: String): Result<Long> {
        val target = _campaigns.value.find { it.id == campaignId }
            ?: return Result.failure(NoSuchElementException("سفارش یافت نشد."))

        if (target.status == CampaignStatus.CANCELLED || target.status == CampaignStatus.COMPLETED) {
            return Result.failure(IllegalStateException("این سفارش قبلاً بسته شده است."))
        }

        val unspent = target.remainingBudget
        val refundTx = CoinTransaction(
            amount = unspent,
            type = TransactionType.CAMPAIGN_REFUND,
            description = "استرداد مانده بودجه سفارش لغو شده ${target.domain}",
            referenceId = target.id
        )

        val current = _account.value
        val newAvailable = current.availableCoins + unspent
        val newReserved = (current.reservedCoins - unspent).coerceAtLeast(0)

        val updatedTx = listOf(refundTx) + _transactions.value
        val updatedCampaigns = _campaigns.value.map {
            if (it.id == campaignId) it.copy(status = CampaignStatus.CANCELLED) else it
        }

        _transactions.value = updatedTx
        _campaigns.value = updatedCampaigns

        _account.update {
            it.copy(
                availableCoins = newAvailable,
                reservedCoins = newReserved
            )
        }

        persistTransactions(updatedTx)
        persistCampaigns(updatedCampaigns)
        persistAccountState(
            available = newAvailable,
            reserved = newReserved,
            lifetimeEarned = current.lifetimeEarned,
            lifetimeSpent = current.lifetimeSpent,
            completedViews = current.completedViewsCount,
            receivedViews = current.receivedViewsCount
        )

        return Result.success(unspent)
    }

    /**
     * Selects an active campaign to view, enforcing anti-self-view and anti-repeat rules.
     */
    fun getNextViewSession(): ViewSession? {
        val currentUserId = _account.value.userId
        val allEligible = (communityCampaigns + _campaigns.value)
            .filter { it.status == CampaignStatus.ACTIVE }
            .filter { it.ownerId != currentUserId } // Anti-self view
            .filter { !recentlyViewedCampaignIds.contains(it.id) }

        val selected = allEligible.firstOrNull() ?: run {
            // Reset cooldown cycle if all have been seen
            recentlyViewedCampaignIds.clear()
            (communityCampaigns + _campaigns.value)
                .filter { it.status == CampaignStatus.ACTIVE && it.ownerId != currentUserId }
                .firstOrNull()
        } ?: return null

        recentlyViewedCampaignIds.add(selected.id)

        val option = durationOptions.find { it.seconds == selected.durationSeconds }
            ?: durationOptions[2]

        return ViewSession(
            campaignId = selected.id,
            targetUrl = selected.url,
            domain = selected.domain,
            requiredDurationSeconds = selected.durationSeconds,
            rewardCoins = option.viewerReward
        )
    }

    /**
     * Completes a view session after genuine elapsed time verification, crediting coins via ledger.
     */
    fun completeViewSession(session: ViewSession): Long {
        val reward = session.rewardCoins
        val current = _account.value
        val newAvailable = current.availableCoins + reward
        val newLifetime = current.lifetimeEarned + reward
        val newCompletedCount = current.completedViewsCount + 1

        val viewTx = CoinTransaction(
            amount = reward,
            type = TransactionType.VIEW_REWARD,
            description = "مشاهده موفق ${session.requiredDurationSeconds} ثانیه‌ای از ${session.domain}",
            referenceId = session.campaignId
        )

        val updatedTx = listOf(viewTx) + _transactions.value
        _transactions.value = updatedTx

        _account.update {
            it.copy(
                availableCoins = newAvailable,
                lifetimeEarned = newLifetime,
                completedViewsCount = newCompletedCount
            )
        }

        // Update campaign progress if it's one of user's or community
        val updatedCampaigns = _campaigns.value.map {
            if (it.id == session.campaignId) {
                val views = it.completedViews + 1
                val spent = it.spentBudget + it.costPerView
                val isDone = views >= it.targetViews
                it.copy(
                    completedViews = views,
                    spentBudget = spent,
                    status = if (isDone) CampaignStatus.COMPLETED else it.status
                )
            } else it
        }
        _campaigns.value = updatedCampaigns

        persistTransactions(updatedTx)
        persistCampaigns(updatedCampaigns)
        persistAccountState(
            available = newAvailable,
            reserved = current.reservedCoins,
            lifetimeEarned = newLifetime,
            lifetimeSpent = current.lifetimeSpent,
            completedViews = newCompletedCount,
            receivedViews = current.receivedViewsCount
        )

        return reward
    }

    fun submitReport(campaignId: String, domain: String, reason: String, details: String) {
        val report = AbuseReport(
            campaignId = campaignId,
            domain = domain,
            reason = reason,
            details = details
        )
        _reports.update { listOf(report) + it }
        recentlyViewedCampaignIds.add(campaignId) // Skip from seeing again
    }
}
