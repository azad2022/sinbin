package com.example.ui.screens

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
    fun sslFailureSkipsEachSessionAtMostOnce() {
        assertTrue(shouldAutoSkipAfterSslError("session-1", null))
        assertFalse(shouldAutoSkipAfterSslError("session-1", "session-1"))
        assertTrue(shouldAutoSkipAfterSslError("session-2", "session-1"))
        assertFalse(shouldAutoSkipAfterSslError(null, null))
        assertFalse(shouldAutoSkipAfterSslError("", null))
    }
}
