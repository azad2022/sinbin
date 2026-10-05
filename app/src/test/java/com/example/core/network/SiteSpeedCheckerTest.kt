package com.example.core.network

import org.junit.Assert.assertEquals
import org.junit.Test

class SiteSpeedCheckerTest {

    @Test
    fun classify_marksResponsesUpToTwoPointFiveSecondsAsGood() {
        assertEquals(SiteSpeedLevel.GOOD, SiteSpeedChecker.classify(0L))
        assertEquals(SiteSpeedLevel.GOOD, SiteSpeedChecker.classify(2_500L))
    }

    @Test
    fun classify_marksResponsesUpToFiveSecondsAsAcceptable() {
        assertEquals(SiteSpeedLevel.ACCEPTABLE, SiteSpeedChecker.classify(2_501L))
        assertEquals(SiteSpeedLevel.ACCEPTABLE, SiteSpeedChecker.classify(5_000L))
    }

    @Test
    fun classify_marksResponsesAboveFiveSecondsAsSlow() {
        assertEquals(SiteSpeedLevel.SLOW, SiteSpeedChecker.classify(5_001L))
        assertEquals(SiteSpeedLevel.SLOW, SiteSpeedChecker.classify(60_000L))
    }
}
