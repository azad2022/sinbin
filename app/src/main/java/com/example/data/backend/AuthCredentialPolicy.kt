package com.example.data.backend

import java.security.MessageDigest

internal object AuthCredentialPolicy {
    /**
     * Produces a deterministic, high-entropy password that is always below
     * Supabase Auth's 72-character maximum and does not depend on Android APIs.
     */
    fun buildDerivedDevicePassword(deviceSecret: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(deviceSecret.toByteArray(Charsets.UTF_8))
        val hex = digest.joinToString(separator = "") {
            "%02x".format(it.toInt() and 0xFF)
        }
        return "SB_$hex"
    }
}
