package com.example.data.backend

/**
 * Device evidence is advisory input for server-side fraud/risk evaluation.
 * None of these fields is authoritative on the client.
 *
 * installId is retained for application/session continuity only.
 * Android ID and App Set ID are obtained from platform services.
 * installationKeyFingerprint is derived from an Android Keystore public key.
 */
data class DeviceEvidence(
    val installId: String,
    val androidId: String? = null,
    val appSetId: String? = null,
    val appSetScope: String? = null,
    val installationKeyFingerprint: String? = null
)
