package com.example.core.security

import android.os.CancellationSignal
import android.webkit.WebView
import androidx.webkit.PrefetchException
import androidx.webkit.PrefetchResult
import androidx.webkit.Profile
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import androidx.webkit.WebViewOutcomeReceiver

/**
 * Level 3 speculative loading for SiteBin.
 *
 * Prefetch downloads only the main HTML response. It never navigates the visible
 * WebView and therefore cannot make a viewing session content-ready by itself.
 */
object SpeculativeWebViewLoader {

    @OptIn(Profile.ExperimentalUrlPrefetch::class)
    fun prefetch(webView: WebView, url: String): CancellationSignal? {
        val allowed = UrlSecurityPolicy.evaluateUrl(url) as? PolicyResult.Allowed ?: return null

        // Prefetch matching is exact. Refuse to speculate unless the authoritative
        // session URL is already in the exact normalized form used for navigation.
        if (allowed.normalizedUrl != url) return null

        if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) return null
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROFILE_URL_PREFETCH)) return null

        val profile = runCatching { WebViewCompat.getProfile(webView) }.getOrNull()
            ?: return null

        val cancellationSignal = CancellationSignal()

        runCatching {
            @Suppress("DEPRECATION")
            profile.prefetchUrlAsync(
                url,
                cancellationSignal,
                null,
                object : WebViewOutcomeReceiver<PrefetchResult, PrefetchException> {
                    override fun onResult(result: PrefetchResult) = Unit
                    override fun onError(error: PrefetchException) = Unit
                }
            )
        }.onFailure {
            cancellationSignal.cancel()
            return null
        }

        return cancellationSignal
    }
}
