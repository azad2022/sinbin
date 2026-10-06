package com.example

import com.example.data.backend.buildCreateCampaignRpcBody
import org.json.JSONObject
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

        assertTrue(body.has("p_url"))
        assertTrue(body.has("p_normalized_url"))
        assertTrue(body.has("p_domain"))
        assertTrue(body.has("p_duration_seconds"))
        assertTrue(body.has("p_target_views"))
        assertTrue(body.has("p_keyword"))
        assertTrue(body.has("p_preflight_token"))
        assertTrue(body.isNull("p_keyword"))
        assertEquals(
            "preflight-token-123456789012345678901234567890",
            body.getString("p_preflight_token")
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

        assertTrue(body.isNull("p_keyword"))
        assertTrue(body.isNull("p_preflight_token"))
        assertEquals(JSONObject.NULL, body.opt("p_keyword"))
        assertEquals(JSONObject.NULL, body.opt("p_preflight_token"))
    }
}
