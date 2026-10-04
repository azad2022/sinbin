package com.example.data.model

import java.util.UUID

enum class CampaignStatus(val labelFarsi: String) {
    ACTIVE("در حال اجرا"),
    PAUSED("متوقف شده"),
    COMPLETED("تکمیل شده"),
    CANCELLED("لغو شده")
}

data class Campaign(
    val id: String = UUID.randomUUID().toString(),
    val ownerId: String,
    val url: String,
    val domain: String,
    val keyword: String? = null,
    val durationSeconds: Int,
    val targetViews: Int,
    val completedViews: Int = 0,
    val costPerView: Long,
    val totalBudget: Long,
    val spentBudget: Long = 0,
    val status: CampaignStatus = CampaignStatus.ACTIVE,
    val createdAt: Long = System.currentTimeMillis()
) {
    val progressPercentage: Float
        get() = if (targetViews > 0) (completedViews.toFloat() / targetViews).coerceIn(0f, 1f) else 0f

    val remainingViews: Int
        get() = (targetViews - completedViews).coerceAtLeast(0)

    val remainingBudget: Long
        get() = (totalBudget - spentBudget).coerceAtLeast(0)
}

enum class TransactionType(val labelFarsi: String, val isPositive: Boolean) {
    WELCOME_REWARD("پاداش خوش‌آمدگویی", true),
    VIEW_REWARD("پاداش مشاهده معتبر", true),
    CAMPAIGN_RESERVATION("رزرو سکه سفارش بازدید", false),
    CAMPAIGN_SPEND("مصرف بودجه بازدید", false),
    CAMPAIGN_REFUND("استرداد بودجه باقیمانده", true),
    REFERRAL_REWARD("پاداش معرفی دوستان", true),
    PLATFORM_GRANT("اعتبار پلتفرمی", true)
}

data class CoinTransaction(
    val id: String = UUID.randomUUID().toString(),
    val amount: Long,
    val type: TransactionType,
    val description: String,
    val timestamp: Long = System.currentTimeMillis(),
    val referenceId: String? = null
)

data class UserAccount(
    val userId: String,
    val appInstallId: String,
    val availableCoins: Long,
    val reservedCoins: Long = 0,
    val lifetimeEarned: Long = 0,
    val lifetimeSpent: Long = 0,
    val trustScore: Float = 100f,
    val completedViewsCount: Int = 0,
    val receivedViewsCount: Int = 0
) {
    val totalCoins: Long
        get() = availableCoins + reservedCoins
}

data class DurationOption(
    val seconds: Int,
    val advertiserCost: Long,
    val viewerReward: Long,
    val isPopular: Boolean = false,
    val keywordAdvertiserCost: Long = advertiserCost * 3L
) {
    fun advertiserCostForKeyword(keyword: String?): Long =
        if (keyword.isNullOrBlank()) advertiserCost else keywordAdvertiserCost
}

data class ViewSession(
    val id: String = UUID.randomUUID().toString(),
    val campaignId: String,
    val targetUrl: String,
    val domain: String,
    val keyword: String? = null,
    val requiredDurationSeconds: Int,
    val rewardCoins: Long,
    val startedAt: Long = System.currentTimeMillis()
)

data class AbuseReport(
    val id: String = UUID.randomUUID().toString(),
    val campaignId: String,
    val domain: String,
    val reason: String,
    val details: String = "",
    val timestamp: Long = System.currentTimeMillis()
)
