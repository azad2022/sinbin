package com.example.core.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UrlSecurityPolicyTest {

    @Test
    fun allowsPublicHttpsUrl() {
        val result = UrlSecurityPolicy.evaluateUrl("https://example.com/path?q=1")
        assertTrue(result is PolicyResult.Allowed)
        result as PolicyResult.Allowed
        assertEquals("example.com", result.domain)
        assertEquals("https://example.com/path?q=1", result.normalizedUrl)
    }

    @Test
    fun blocksHttpUrl() {
        val result = UrlSecurityPolicy.evaluateUrl("http://example.com")
        assertTrue(result is PolicyResult.Blocked)
    }

    @Test
    fun blocksPrivateIpv4() {
        assertTrue(UrlSecurityPolicy.evaluateUrl("https://127.0.0.1").isBlocked())
        assertTrue(UrlSecurityPolicy.evaluateUrl("https://192.168.1.10").isBlocked())
        assertTrue(UrlSecurityPolicy.evaluateUrl("https://10.0.0.1").isBlocked())
    }

    @Test
    fun blocksNonStandardNumericIpForms() {
        assertTrue(UrlSecurityPolicy.evaluateUrl("https://2130706433").isBlocked())
        assertTrue(UrlSecurityPolicy.evaluateUrl("https://127.1").isBlocked())
        assertTrue(UrlSecurityPolicy.evaluateUrl("https://0x7f000001").isBlocked())
    }

    @Test
    fun blocksExternalAppSchemes() {
        assertTrue(UrlSecurityPolicy.evaluateUrl("tg://resolve?domain=test").isBlocked())
        assertTrue(UrlSecurityPolicy.evaluateUrl("intent://example.com/#Intent;scheme=https;end").isBlocked())
        assertTrue(UrlSecurityPolicy.evaluateUrl("market://details?id=test").isBlocked())
    }

    @Test
    fun blocksDownloads() {
        assertTrue(UrlSecurityPolicy.evaluateUrl("https://example.com/app.apk").isBlocked())
        assertTrue(UrlSecurityPolicy.evaluateUrl("https://example.com/archive.zip").isBlocked())
    }

    @Test
    fun blocksUserInfoAndIpv6Literals() {
        assertTrue(UrlSecurityPolicy.evaluateUrl("https://user:pass@example.com").isBlocked())
        assertTrue(UrlSecurityPolicy.evaluateUrl("https://[::1]").isBlocked())
    }

    private fun PolicyResult.isBlocked(): Boolean = this is PolicyResult.Blocked
}
