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
            "4EBB5F9A6365311B9F7B3D34D4D9BFD15BD69C4CA1D9015A301ED831103061ED",
            digest
        )
    }
}
