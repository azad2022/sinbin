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
            "wallet_transfer",
            "auto_view",
            "settings_security",
            "troubleshooting"
        )

        assertEquals(required, ids)
        assertTrue(siteBinHelpSections.all { it.title.isNotBlank() && it.subtitle.isNotBlank() })
        assertFalse(siteBinHelpSections.any { it.paragraphs.any(String::isBlank) })
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
