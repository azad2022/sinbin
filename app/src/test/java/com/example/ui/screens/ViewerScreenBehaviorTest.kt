package com.example.ui.screens

import org.junit.Assert.assertEquals
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
}
