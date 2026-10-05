package com.example

import com.example.data.backend.ServerEmulatedEngine
import com.example.data.backend.WebsiteViewerCompatibility
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WebsitePreflightContractTest {

    @Test
    fun preflightResult_containsServerStyleCompatibilityAndExpiry() = runTest {
        val engine = ServerEmulatedEngine()
        val result = engine.preflightCampaignUrl("https://example.com/path")

        assertTrue(result.isSuccess)
        val preflight = result.getOrThrow()
        assertEquals(WebsiteViewerCompatibility.COMPATIBLE, preflight.viewerCompatibility)
        assertTrue(preflight.qualityScore in 0..100)
        assertTrue(preflight.preflightToken.isNotBlank())
        assertTrue(preflight.expiresAtEpochMs > System.currentTimeMillis())
    }

    @Test
    fun emulatorRejectsNonHttpsPreflight() = runTest {
        val engine = ServerEmulatedEngine()
        val result = engine.preflightCampaignUrl("http://example.com")

        assertTrue(result.isFailure)
    }
}
