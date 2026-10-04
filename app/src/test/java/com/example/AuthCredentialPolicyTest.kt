package com.example

import com.example.data.backend.AuthCredentialPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AuthCredentialPolicyTest {

    @Test
    fun derivedPasswordIsDeterministicAndWithinSupabaseLimit() {
        val secret = "device-secret-with-256-bit-origin"
        val first = AuthCredentialPolicy.buildDerivedDevicePassword(secret)
        val second = AuthCredentialPolicy.buildDerivedDevicePassword(secret)

        assertEquals(first, second)
        assertTrue(first.startsWith("SB_"))
        assertTrue(first.length <= 72)
        assertEquals(46, first.length)
    }
}
