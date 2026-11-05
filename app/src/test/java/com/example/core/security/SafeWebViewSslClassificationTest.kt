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
    fun differentInternationalizedAuthoritiesRemainDistinct() {
        assertFalse(
            isMainFrameSslErrorUrl(
                "https://مثال.ایران/article",
                "https://نمونه.ایران/article"
            )
        )
    }

    @Test
    fun missingOrMalformedUrlsFailClosed() {
        assertTrue(isMainFrameSslErrorUrl(null, "https://example.com/"))
        assertTrue(isMainFrameSslErrorUrl("https://example.com/", null))
        assertTrue(isMainFrameSslErrorUrl("not a valid url", "https://example.com/"))
    }
}
