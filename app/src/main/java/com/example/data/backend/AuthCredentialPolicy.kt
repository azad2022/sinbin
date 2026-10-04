package com.example.data.backend

import android.util.Base64
import java.security.MessageDigest

internal object AuthCredentialPolicy {
    /**
     * Produces a deterministic, high-entropy password that is always below
     * Supabase Auth's 72-character maximum.
     */
    fun buildDerivedDevicePassword(deviceSecret: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(deviceSecret.toByteArray(Charsets.UTF_8))
        val encoded = Base64.encodeToString(
            digest,
            Base64.NO_WRAP or Base64.URL_SAFE
        )
        return "SB_$encoded"
    }
}
