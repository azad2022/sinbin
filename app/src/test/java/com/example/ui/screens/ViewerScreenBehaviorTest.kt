package com.example.ui.screens

import com.example.ui.ViewerState

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ViewerScreenBehaviorTest {

    @Test
    fun viewerCountdownUsesEnglishDigitsAndZeroPadding() {
        assertEquals("01:05", formatViewerCountdown(65))
        assertEquals("00:05", formatViewerCountdown(5))
        assertEquals("00:00", formatViewerCountdown(0))
    }

    @Test
    fun viewerCountdownDoesNotFormatNegativeRemainingTime() {
        assertEquals("00:00", formatViewerCountdown(-1))
    }

    @Test
    fun normalPageTimeoutIsLongerThanPreviousAggressiveSixSecondLimit() {
        assertTrue(VIEWER_PAGE_LOAD_TIMEOUT_MS >= 12_000L)
        assertTrue(VIEWER_PUBLIC_CHANNEL_PAGE_LOAD_TIMEOUT_MS > VIEWER_PAGE_LOAD_TIMEOUT_MS)
    }

    @Test
    fun failedViewerStateKeepsItsSessionAvailableForRetryAndSkip() {
        val session = com.example.data.model.ViewSession(
            id = "session-1",
            campaignId = "campaign-1",
            targetUrl = "https://example.com",
            domain = "example.com",
            keyword = null,
            requiredDurationSeconds = 10,
            rewardCoins = 6,
            startedAt = 1L
        )
        val failed = ViewerState.Error("RPC timeout", session, "content_ready", true)
        assertTrue(viewerSessionForState(failed) === session)
    }

    @Test
    fun sslFailureSkipsEachSessionAtMostOnce() {
        assertTrue(shouldAutoSkipAfterSslError("session-1", null))
        assertFalse(shouldAutoSkipAfterSslError("session-1", "session-1"))
        assertTrue(shouldAutoSkipAfterSslError("session-2", "session-1"))
        assertFalse(shouldAutoSkipAfterSslError(null, null))
        assertFalse(shouldAutoSkipAfterSslError("", null))
    }
}
