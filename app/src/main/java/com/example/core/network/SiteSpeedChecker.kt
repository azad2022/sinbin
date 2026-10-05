package com.example.core.network

import com.example.core.security.PolicyResult
import com.example.core.security.UrlSecurityPolicy
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume

data class SiteSpeedResult(
    val elapsedMs: Long
)

enum class SiteSpeedLevel {
    GOOD,
    ACCEPTABLE,
    SLOW
}

object SiteSpeedChecker {

    private const val ACCEPTABLE_THRESHOLD_MS = 2_500L
    private const val SLOW_THRESHOLD_MS = 5_000L

    private val client = OkHttpClient.Builder()
        .connectTimeout(3, TimeUnit.SECONDS)
        .readTimeout(5, TimeUnit.SECONDS)
        .writeTimeout(5, TimeUnit.SECONDS)
        .callTimeout(7, TimeUnit.SECONDS)
        .followRedirects(true)
        .followSslRedirects(true)
        .retryOnConnectionFailure(false)
        .build()

    suspend fun check(rawUrl: String): Result<SiteSpeedResult> {
        val validation = UrlSecurityPolicy.evaluateUrl(rawUrl)
        val allowed = validation as? PolicyResult.Allowed
            ?: return Result.failure(
                IllegalArgumentException(
                    (validation as? PolicyResult.Blocked)?.reason
                        ?: "آدرس وب‌سایت قابل بررسی نیست."
                )
            )

        val request = Request.Builder()
            .url(allowed.normalizedUrl)
            .get()
            .header("Accept", "text/html,application/xhtml+xml,*/*;q=0.8")
            .header("Cache-Control", "no-cache")
            .header("User-Agent", "SiteBin-SpeedCheck/1.0")
            .header("Range", "bytes=0-2048")
            .build()

        return suspendCancellableCoroutine { continuation ->
            val startedAtNanos = System.nanoTime()
            val call = client.newCall(request)

            continuation.invokeOnCancellation {
                call.cancel()
            }

            call.enqueue(object : okhttp3.Callback {
                override fun onFailure(call: okhttp3.Call, e: IOException) {
                    if (continuation.isActive) {
                        continuation.resume(Result.failure(e))
                    }
                }

                override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
                    response.use {
                        val elapsedMs = ((System.nanoTime() - startedAtNanos) / 1_000_000L).coerceAtLeast(0L)
                        val finalUrl = response.request.url.toString()

                        if (UrlSecurityPolicy.evaluateUrl(finalUrl) is PolicyResult.Blocked) {
                            if (continuation.isActive) {
                                continuation.resume(
                                    Result.failure(
                                        IllegalStateException("سایت به یک آدرس ناامن هدایت شد.")
                                    )
                                )
                            }
                            return
                        }

                        if (!response.isSuccessful && response.code !in 300..399) {
                            if (continuation.isActive) {
                                continuation.resume(
                                    Result.failure(
                                        IOException("Site speed check returned HTTP " + response.code)
                                    )
                                )
                            }
                            return
                        }

                        if (continuation.isActive) {
                            continuation.resume(Result.success(SiteSpeedResult(elapsedMs)))
                        }
                    }
                }
            })
        }
    }

    fun classify(elapsedMs: Long): SiteSpeedLevel = when {
        elapsedMs <= ACCEPTABLE_THRESHOLD_MS -> SiteSpeedLevel.GOOD
        elapsedMs <= SLOW_THRESHOLD_MS -> SiteSpeedLevel.ACCEPTABLE
        else -> SiteSpeedLevel.SLOW
    }
}
