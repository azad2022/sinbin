package com.example

import com.example.data.model.DurationOption
import org.junit.Assert.assertEquals
import org.junit.Test

class CampaignPricingTest {
    @Test
    fun directVisitUsesNormalAdvertiserCost() {
        val pricing = DurationOption(5, 5, 3, keywordAdvertiserCost = 15)
        assertEquals(5L, pricing.advertiserCostForKeyword(null))
        assertEquals(5L, pricing.advertiserCostForKeyword(""))
        assertEquals(5L, pricing.advertiserCostForKeyword("   "))
    }

    @Test
    fun keywordVisitUsesPremiumAdvertiserCost() {
        val pricing = DurationOption(10, 9, 6, keywordAdvertiserCost = 27)
        assertEquals(27L, pricing.advertiserCostForKeyword("سولانا"))
    }

    @Test
    fun premiumPricingMatchesCurrentPublishedMatrix() {
        val matrix = listOf(
            DurationOption(5, 5, 3, keywordAdvertiserCost = 15),
            DurationOption(10, 9, 6, keywordAdvertiserCost = 27),
            DurationOption(15, 14, 10, keywordAdvertiserCost = 42),
            DurationOption(30, 26, 19, keywordAdvertiserCost = 78),
            DurationOption(60, 50, 38, keywordAdvertiserCost = 150)
        )
        val expected = mapOf(5 to 15L, 10 to 27L, 15 to 42L, 30 to 78L, 60 to 150L)
        matrix.forEach { option ->
            assertEquals(expected.getValue(option.seconds), option.keywordAdvertiserCost)
        }
    }
}
