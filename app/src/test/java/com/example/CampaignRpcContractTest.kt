package com.example

import com.example.data.backend.buildCreateCampaignRpcBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CampaignRpcContractTest {

    @Test
    fun createCampaign_payloadAlwaysContainsAllSevenNamedArguments() {
        val body = buildCreateCampaignRpcBody(
            url = "https://example.com",
            normalizedUrl = "https://example.com",
            domain = "example.com",
            durationSeconds = 5,
            targetViews = 100,
            keyword = null,
            preflightToken = "preflight-token-123456789012345678901234567890"
        )

        assertTrue(body.containsKey("p_url"))
        assertTrue(body.containsKey("p_normalized_url"))
        assertTrue(body.containsKey("p_domain"))
        assertTrue(body.containsKey("p_duration_seconds"))
        assertTrue(body.containsKey("p_target_views"))
        assertTrue(body.containsKey("p_keyword"))
        assertTrue(body.containsKey("p_preflight_token"))
        assertEquals(null, body["p_keyword"])
        assertEquals(
            "preflight-token-123456789012345678901234567890",
            body["p_preflight_token"]
        )
    }

    @Test
    fun createCampaign_payloadSerializesBlankOptionalValuesAsNull() {
        val body = buildCreateCampaignRpcBody(
            url = "https://example.com",
            normalizedUrl = "https://example.com",
            domain = "example.com",
            durationSeconds = 5,
            targetViews = 100,
            keyword = "   ",
            preflightToken = "   "
        )

        assertEquals(null, body["p_keyword"])
        assertEquals(null, body["p_preflight_token"])
    }
}
