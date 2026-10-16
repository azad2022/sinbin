package com.example.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingScreenBehaviorTest {
    @Test
    fun onboardingIncludesKeywordAndPublicChannelStepsBeforeLeaderboard() {
        assertEquals(6, siteBinOnboardingSteps.size)

        val keywordSeo = siteBinOnboardingSteps[3]
        assertEquals("وبسایت خود را با جستجوی کلمه کلیدی سئو کنید.", keywordSeo.title)
        assertTrue(keywordSeo.subtitle.contains("کلمهٔ کلیدی مرتبط"))

        val publicChannels = siteBinOnboardingSteps[4]
        assertEquals("افزایش بازدید پست‌های ایتا و بله", publicChannels.title)
        assertTrue(publicChannels.subtitle.contains("پست عمومی ایتا"))
        assertTrue(publicChannels.subtitle.contains("بله"))

        val leaderboard = siteBinOnboardingSteps[5]
        assertEquals("لیدربورد هفتگی", leaderboard.title)
        assertTrue(leaderboard.subtitle.contains("بازدیدهای معتبر بیشتری"))
        assertTrue(leaderboard.subtitle.contains("صفحات ابتدایی مرورگر"))
    }
}
