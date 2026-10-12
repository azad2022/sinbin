package com.example.ui.screens

import com.example.data.model.DailyBonusResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeScreenBehaviorTest {

    @Test
    fun welcomeBonusBanner_isVisibleOnlyWithinTwoHours() {
        val grantedAt = 1_000_000L

        assertTrue(
            isWelcomeBonusBannerVisible(
                grantedAtMillis = grantedAt,
                nowMillis = grantedAt + WELCOME_BONUS_BANNER_DURATION_MS - 1L
            )
        )
        assertFalse(
            isWelcomeBonusBannerVisible(
                grantedAtMillis = grantedAt,
                nowMillis = grantedAt + WELCOME_BONUS_BANNER_DURATION_MS
            )
        )
        assertFalse(
            isWelcomeBonusBannerVisible(
                grantedAtMillis = grantedAt,
                nowMillis = grantedAt - 1L
            )
        )
    }

    @Test
    fun alreadyClaimedDailyBonusBannerIsHiddenWithoutChangingGrantLogic() {
        assertFalse(
            shouldShowDailyBonusBanner(
                DailyBonusResult(
                    granted = false,
                    amount = 0L,
                    grantDate = "2026-10-09",
                    reason = "ALREADY_CLAIMED"
                )
            )
        )
    }

    @Test
    fun dailyBonusBannerRemainsForActionableAndNewlyGrantedStates() {
        assertTrue(
            shouldShowDailyBonusBanner(
                DailyBonusResult(false, 50L, "2026-10-09", "WELCOME_DAY")
            )
        )
        assertTrue(
            shouldShowDailyBonusBanner(
                DailyBonusResult(false, 50L, "2026-10-09", "VISIT_REQUIRED")
            )
        )
        assertTrue(
            shouldShowDailyBonusBanner(
                DailyBonusResult(true, 50L, "2026-10-09", null)
            )
        )
    }

    @Test
    fun homeActionCardsRotateRequestedSubtitlesWithoutRemovingOriginalCopy() {
        assertEquals(
            listOf(
                "با مشاهده وب‌سایت‌های دیگران سکه رایگان دریافت کن و به موجودی خودت اضافه کن.",
                "هر چقدر بیشتر بازدید کنی امکان اینکه نفر اول لیدربورد بشی بیشتر میشه",
                "نفرات برتر لیدربورد لینک های آنها در صفحات ابتدایی مرورگر به ترتیب نمایش داده میشه"
            ),
            HOME_VIEWING_CARD_SUBTITLES
        )
        assertEquals(
            listOf(
                "با سکه‌های خود برای وب‌سایتت بازدید واقعی، هدفمند و بر اساس ثانیه دلخواه دریافت کن.",
                "زمان بیشتر و بازدید بیشتر و مداوم از وبسایتت تاثیر سئوی آن بیشتر خواهد بود",
                "سکه های بیشتر بگیر بازدید بیشتر دریافت کن و با تداوم باعث سئوی سایتت شو"
            ),
            HOME_ADVERTISING_CARD_SUBTITLES
        )
    }

    @Test
    fun dailyBonusBannerIsHiddenWhenServerDateIsMissing() {
        assertFalse(
            shouldShowDailyBonusBanner(
                DailyBonusResult(false, 50L, "", "VISIT_REQUIRED")
            )
        )
    }
}
