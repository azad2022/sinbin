package com.example.core.security

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SafeWebViewSslClassificationTest {

    @Test
    fun exactTopLevelUrlIsClassifiedAsMainFrame() {
        assertTrue(
            isMainFrameSslErrorUrl(
                "https://www.parhana.ir/",
                "https://www.parhana.ir/"
            )
        )
    }

    @Test
    fun fragmentDoesNotChangeTopLevelResourceIdentity() {
        assertTrue(
            isMainFrameSslErrorUrl(
                "https://example.com/path#section",
                "https://example.com/path"
            )
        )
    }

    @Test
    fun defaultHttpsPortEqualsExplicitPort443() {
        assertTrue(
            isMainFrameSslErrorUrl(
                "https://example.com/path",
                "https://example.com:443/path"
            )
        )
    }

    @Test
    fun differentPathOnSameHostIsAResourceFailureNotMainFrameFailure() {
        assertFalse(
            isMainFrameSslErrorUrl(
                "https://example.com/article",
                "https://example.com/assets/site.css"
            )
        )
    }

    @Test
    fun differentHostIsAResourceFailureNotMainFrameFailure() {
        assertFalse(
            isMainFrameSslErrorUrl(
                "https://example.com/",
                "https://cdn.example.net/image.png"
            )
        )
    }

    @Test
    fun queryStringDifferenceIsNotTreatedAsSameMainFrame() {
        assertFalse(
            isMainFrameSslErrorUrl(
                "https://example.com/page?id=1",
                "https://example.com/page?id=2"
            )
        )
    }

    @Test
    fun missingOrMalformedUrlsFailClosed() {
        assertTrue(isMainFrameSslErrorUrl(null, "https://example.com/"))
        assertTrue(isMainFrameSslErrorUrl("https://example.com/", null))
        assertTrue(isMainFrameSslErrorUrl("not a valid url", "https://example.com/"))
    }
    @Test
    fun sameOriginIgnoresPathAndQueryButNormalizesDefaultHttpsPort() {
        assertTrue(
            isSameWebOrigin(
                "https://example.com/start?campaign=1",
                "https://EXAMPLE.com:443/next"
            )
        )
    }

    @Test
    fun differentHostSchemeAndPortAreRejectedAsDifferentOrigins() {
        assertFalse(isSameWebOrigin("https://example.com/", "https://sub.example.com/"))
        assertFalse(isSameWebOrigin("https://example.com/", "http://example.com/"))
        assertFalse(isSameWebOrigin("https://example.com/", "https://example.com:444/"))
    }

    @Test
    fun malformedOrCredentialBearingOriginsFailClosed() {
        assertFalse(isSameWebOrigin("not a url", "https://example.com/"))
        assertFalse(isSameWebOrigin("https://user@example.com/", "https://example.com/"))
        assertFalse(isSameWebOrigin("https://example.com/", null))
    }

    @Test
    fun javascriptStringLiteralEscapesQuotesControlsAndLineSeparators() {
        assertEquals(
            "\"a\\\\b\\\"c\\n\\r\\t\\u2028\\u2029\"",
            javascriptStringLiteral("a\\b\"c\n\r\t\u2028\u2029")
        )
        assertEquals("\"\\u0001\"", javascriptStringLiteral("\u0001"))
    }

    @Test
    fun postFormGuardIsBoundToExpectedOriginAndBlocksCrossOriginSubmissions() {
        val script = buildMainFrameFormOriginGuard("https://example.com/start")

        assertTrue(script.contains("\"https://example.com\""))
        assertTrue(script.contains("HTMLFormElement.prototype"))
        assertTrue(script.contains("event.submitter"))
        assertTrue(script.contains("formAction"))
        assertTrue(script.contains("formTarget"))
        assertTrue(script.contains("preventDefault"))
        assertTrue(script.contains("stopImmediatePropagation"))
        assertTrue(script.contains("nativeSubmit.call(this)"))
    }

}
