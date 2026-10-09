package com.example.ui.screens

import com.example.data.model.DailyBonusResult
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
    fun dailyBonusBannerIsHiddenWhenServerDateIsMissing() {
        assertFalse(
            shouldShowDailyBonusBanner(
                DailyBonusResult(false, 50L, "", "VISIT_REQUIRED")
            )
        )
    }
}
