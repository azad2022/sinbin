package com.example.ui

import com.example.ui.screens.siteBinHelpPricing
import com.example.ui.screens.siteBinHelpSections
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SiteBinHelpContentTest {
    @Test
    fun guideContainsAllCoreProductAreas() {
        val ids = siteBinHelpSections.map { it.id }.toSet()
        val required = setOf(
            "referrals",
            "getting_started",
            "coins",
            "viewing",
            "website",
            "keyword",
            "pricing",
            "campaigns",
            "leaderboard",
            "wallet_transfer",
            "auto_view",
            "settings_security",
            "troubleshooting"
        )

        assertEquals(required, ids)
        assertTrue(siteBinHelpSections.all { it.title.isNotBlank() && it.subtitle.isNotBlank() })
        assertFalse(siteBinHelpSections.any { it.paragraphs.any(String::isBlank) })
        val leaderboard = siteBinHelpSections.first { it.id == "leaderboard" }
        val leaderboardText = leaderboard.paragraphs.joinToString(" ")
        assertTrue(leaderboardText.contains("۳۰ روز کامل و شناور اخیر"))
        assertTrue(leaderboardText.contains("پنجرهٔ ۳۰ روزه"))
        assertTrue(leaderboardText.contains("پنج رتبهٔ نخست"))
        assertTrue(leaderboardText.contains("رتبه‌بندی روزانهٔ UTC"))
        assertTrue(leaderboardText.contains("رتبهٔ ششم و بالاتر"))
        assertTrue(leaderboardText.contains("به رتبه‌های قبلی برنمی‌گردد"))
        assertTrue(leaderboardText.contains("به‌صورت اتمیک"))
        assertTrue(leaderboardText.contains("سشن لغوشده یا منقضی‌شده ظرفیت رزروشده را آزاد می‌کند"))
        val keywordText = siteBinHelpSections.first { it.id == "keyword" }.paragraphs.joinToString(" ")
        assertFalse(keywordText.contains("این قابلیت به معنی ارسال خودکار جست‌وجو یا کلیک در Google یا موتور جست‌وجوی دیگری نیست"))

        val referralText = siteBinHelpSections.first { it.id == "referrals" }.paragraphs.joinToString(" ")
        assertTrue(referralText.contains("۱۰۰ بازدید معتبر"))
        assertTrue(referralText.contains("۵۰۰ وب‌سایت متفاوت"))
        assertTrue(referralText.contains("۲۰٬۰۰۰ سکه"))
        assertTrue(referralText.contains("یک‌سطحی"))
        assertTrue(referralText.contains("قابل تغییر نیست"))
        assertTrue(referralText.contains("دامنهٔ ثبت‌پذیر"))
        assertTrue(referralText.contains("۲۰٬۵۰۰ سکه"))
        assertTrue(referralText.contains("وضعیت حساب کاربری"))


        val coinsText = siteBinHelpSections.first { it.id == "coins" }.paragraphs.joinToString(" ")
        assertTrue(coinsText.contains("حداقل یک بازدید"))
        assertTrue(coinsText.contains("اولین بازدید موفق"))
    }

    @Test
    fun pricingMatrixMatchesCurrentServerPublishedValues() {
        val expected = listOf(
            listOf(5, 3, 5, 15),
            listOf(10, 6, 9, 27),
            listOf(15, 10, 14, 42),
            listOf(30, 19, 26, 78),
            listOf(60, 38, 50, 150)
        )

        assertEquals(
            expected,
            siteBinHelpPricing.map {
                listOf(it.seconds, it.viewerReward, it.directCost, it.keywordCost)
            }
        )
    }
}
