package com.example

import com.example.core.security.PolicyResult
import com.example.core.security.UrlSecurityPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UrlSecurityPolicyTest {

    @Test
    fun testValidHttpsWebsiteIsAllowed() {
        val result = UrlSecurityPolicy.evaluateUrl("https://example.com/blog")
        assertTrue(result is PolicyResult.Allowed)
        val allowed = result as PolicyResult.Allowed
        assertEquals("example.com", allowed.domain)
    }

    @Test
    fun testTelegramSchemesAndDomainsAreBlocked() {
        val tgScheme = UrlSecurityPolicy.evaluateUrl("tg://resolve?domain=test")
        assertTrue(tgScheme is PolicyResult.Blocked)

        val tmeDomain = UrlSecurityPolicy.evaluateUrl("https://t.me/some_channel")
        assertTrue(tmeDomain is PolicyResult.Blocked)

        val telegramOrg = UrlSecurityPolicy.evaluateUrl("https://telegram.org/dl")
        assertTrue(telegramOrg is PolicyResult.Blocked)
    }

    @Test
    fun testGooglePlayAndMarketsAreBlocked() {
        val marketScheme = UrlSecurityPolicy.evaluateUrl("market://details?id=com.app")
        assertTrue(marketScheme is PolicyResult.Blocked)

        val playStoreUrl = UrlSecurityPolicy.evaluateUrl("https://play.google.com/store/apps/details?id=com.app")
        assertTrue(playStoreUrl is PolicyResult.Blocked)
    }

    @Test
    fun testCustomIntentSchemesAreBlocked() {
        val intentScheme = UrlSecurityPolicy.evaluateUrl("intent://scan/#Intent;scheme=zxing;package=com.google.zxing.client.android;end")
        assertTrue(intentScheme is PolicyResult.Blocked)

        val whatsappScheme = UrlSecurityPolicy.evaluateUrl("whatsapp://send?text=hello")
        assertTrue(whatsappScheme is PolicyResult.Blocked)

        val telScheme = UrlSecurityPolicy.evaluateUrl("tel:09123456789")
        assertTrue(telScheme is PolicyResult.Blocked)

        val instagramScheme = UrlSecurityPolicy.evaluateUrl("instagram://user?username=test")
        assertTrue(instagramScheme is PolicyResult.Blocked)
    }

    @Test
    fun testSsrfAndLocalhostAreBlocked() {
        val localhost = UrlSecurityPolicy.evaluateUrl("http://localhost:8080")
        assertTrue(localhost is PolicyResult.Blocked)

        val loopback = UrlSecurityPolicy.evaluateUrl("http://127.0.0.1:3000")
        assertTrue(loopback is PolicyResult.Blocked)

        val privateIp = UrlSecurityPolicy.evaluateUrl("http://192.168.1.1/admin")
        assertTrue(privateIp is PolicyResult.Blocked)

        val linkLocal = UrlSecurityPolicy.evaluateUrl("http://169.254.169.254/latest/meta-data/")
        assertTrue(linkLocal is PolicyResult.Blocked)

        val hexIp = UrlSecurityPolicy.evaluateUrl("http://0x7f000001")
        assertTrue(hexIp is PolicyResult.Blocked)

        val decimalIp = UrlSecurityPolicy.evaluateUrl("http://2130706433")
        assertTrue(decimalIp is PolicyResult.Blocked)

        val ipv6Loopback = UrlSecurityPolicy.evaluateUrl("http://[::1]:8080")
        assertTrue(ipv6Loopback is PolicyResult.Blocked)
    }

    @Test
    fun testApkDownloadsAreBlocked() {
        val apkUrl = UrlSecurityPolicy.evaluateUrl("https://example.com/download/app_v1.apk")
        assertTrue(apkUrl is PolicyResult.Blocked)

        val zipUrl = UrlSecurityPolicy.evaluateUrl("https://example.com/file.zip")
        assertTrue(zipUrl is PolicyResult.Blocked)
    }
}
