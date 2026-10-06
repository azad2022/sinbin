package com.example.core.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AppIdentityGuardTest {

    @Test
    fun expectedReleaseCertificateFingerprintIsWellFormed() {
        assertEquals(64, AppIdentityGuard.EXPECTED_RELEASE_CERT_SHA256.length)
        assertTrue(
            AppIdentityGuard.EXPECTED_RELEASE_CERT_SHA256.matches(Regex("[0-9A-F]{64}"))
        )
    }

    @Test
    fun sha256HexUsesCanonicalUppercaseFormat() {
        val digest = AppIdentityGuard.sha256Hex("SiteBin".toByteArray())
        assertEquals(
            "E6D1E8ACB5A5AA5F3C006B0B7A5EAFA67E3C7E7EB7D58E1E95D3DCD00B9A1A97",
            digest
        )
    }
}
