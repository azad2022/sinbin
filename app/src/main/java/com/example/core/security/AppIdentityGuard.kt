package com.example.core.security

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.example.BuildConfig
import java.security.MessageDigest
import java.util.Locale

/**
 * Release-install identity gate.
 *
 * This is a local anti-clone / anti-repackaging control, not a substitute for
 * server authentication. Release code must run only with SiteBin's expected
 * application ID and production signing certificate.
 */
object AppIdentityGuard {
    const val EXPECTED_PACKAGE_NAME = "sitebin.azerakhsh.ir"

    // Public certificate fingerprint; never a secret.
    // Source: SiteBin production release signing certificate.
    const val EXPECTED_RELEASE_CERT_SHA256 =
        "6F259D3C4557BA4B4E4C9489F38BCD85E7EC9F4641C87346F9578BD0F4FF2900"

    fun isTrustedInstallation(context: Context): Boolean {
        if (BuildConfig.DEBUG) {
            return true
        }

        val packageName = context.packageName
        if (packageName != EXPECTED_PACKAGE_NAME) {
            return false
        }

        if (BuildConfig.APPLICATION_ID != EXPECTED_PACKAGE_NAME) {
            return false
        }

        return runCatching {
            val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                context.packageManager.getPackageInfo(
                    packageName,
                    PackageManager.GET_SIGNING_CERTIFICATES
                )
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getPackageInfo(
                    packageName,
                    PackageManager.GET_SIGNATURES
                )
            }

            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageInfo.signingInfo?.apkContentsSigners.orEmpty()
            } else {
                @Suppress("DEPRECATION")
                packageInfo.signatures.orEmpty()
            }

            signatures.any { signature ->
                sha256Hex(signature.toByteArray()) == EXPECTED_RELEASE_CERT_SHA256
            }
        }.getOrDefault(false)
    }

    internal fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { byte ->
                "%02X".format(Locale.ROOT, byte)
            }
}
