package com.example.data.security

import android.content.Context
import android.os.Build
import android.provider.Settings
import com.example.data.backend.DeviceEvidence
import com.google.android.gms.appset.AppSet
import com.google.android.gms.appset.AppSetIdInfo
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.spec.ECGenParameterSpec
import java.util.Locale
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties

/**
 * Collects platform/device continuity evidence without requesting user input
 * or permissions. Failures are intentionally converted to missing evidence;
 * the application remains usable, while the welcome bonus can fail closed.
 */
class AndroidDeviceEvidenceProvider(
    private val context: Context
) {
    companion object {
        private const val INSTALLATION_KEY_ALIAS = "sitebin_welcome_installation_v1"
    }

    suspend fun collect(installId: String): DeviceEvidence {
        val androidId = readAndroidId()
        val appSet = readAppSetId()
        val installationKeyFingerprint = runCatching {
            ensureInstallationKeyAndGetFingerprint()
        }.getOrNull()

        return DeviceEvidence(
            installId = installId,
            androidId = androidId,
            appSetId = appSet?.id,
            appSetScope = appSet?.scopeName,
            installationKeyFingerprint = installationKeyFingerprint
        )
    }

    private fun readAndroidId(): String? {
        // Android 8+ gives the useful signing-key/user/device scoped signal
        // that SiteBin relies on for uninstall/reinstall continuity.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        return runCatching {
            Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ANDROID_ID
            )?.trim()?.takeIf { it.isNotEmpty() }
        }.getOrNull()
    }

    private data class AppSetEvidence(
        val id: String,
        val scopeName: String
    )

    private suspend fun readAppSetId(): AppSetEvidence? =
        suspendCancellableCoroutine { continuation ->
            runCatching {
                val client = AppSet.getClient(context)
                val task = client.appSetIdInfo
                task.addOnSuccessListener { info ->
                    if (continuation.isActive) {
                        val scope = when (info.scope) {
                            AppSetIdInfo.SCOPE_DEVELOPER -> "DEVELOPER"
                            AppSetIdInfo.SCOPE_APP -> "APP"
                            else -> "UNKNOWN"
                        }
                        continuation.resume(
                            AppSetEvidence(
                                id = info.id,
                                scopeName = scope
                            )
                        )
                    }
                }
                task.addOnFailureListener {
                    if (continuation.isActive) continuation.resume(null)
                }
            }.onFailure {
                if (continuation.isActive) continuation.resume(null)
            }

            continuation.invokeOnCancellation { /* Google Play Tasks has no required cancellation path here. */ }
        }

    private fun ensureInstallationKeyAndGetFingerprint(): String {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

        if (!keyStore.containsAlias(INSTALLATION_KEY_ALIAS)) {
            val keyPairGenerator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_EC,
                "AndroidKeyStore"
            )
            keyPairGenerator.initialize(
                KeyGenParameterSpec.Builder(
                    INSTALLATION_KEY_ALIAS,
                    KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
                )
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .setUserAuthenticationRequired(false)
                    .build()
            )
            keyPairGenerator.generateKeyPair()
        }

        val certificate = keyStore.getCertificate(INSTALLATION_KEY_ALIAS)
            ?: error("Installation key certificate is unavailable")

        val digest = MessageDigest.getInstance("SHA-256")
            .digest(certificate.publicKey.encoded)

        return digest.joinToString("") { "%02x".format(Locale.ROOT, it) }
    }
}
