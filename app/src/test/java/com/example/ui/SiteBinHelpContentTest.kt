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
        assertTrue(leaderboardText.contains("دوشنبه"))
        assertTrue(leaderboardText.contains("UTC"))
        assertTrue(leaderboardText.contains("پنج نفر اول"))
        assertTrue(leaderboardText.contains("پاداش سکهٔ جداگانه"))
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
