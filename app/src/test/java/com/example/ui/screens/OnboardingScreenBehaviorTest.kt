package com.example.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingScreenBehaviorTest {
    @Test
    fun onboardingIncludesLeaderboardAsTheFourthAnimatedStep() {
        assertEquals(4, siteBinOnboardingSteps.size)
        val leaderboard = siteBinOnboardingSteps[3]
        assertEquals("لیدربورد هفتگی", leaderboard.title)
        assertTrue(leaderboard.subtitle.contains("بازدیدهای معتبر بیشتری"))
        assertTrue(leaderboard.subtitle.contains("صفحات ابتدایی مرورگر"))
    }
}
