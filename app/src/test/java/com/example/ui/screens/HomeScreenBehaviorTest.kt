package com.example.ui.screens

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
}
