package com.example

import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.activity.compose.setContent
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.example.core.security.SafeWebView
import org.json.JSONTokener
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Live-device smoke tests for the same SafeWebView composable used by ViewerScreen.
 * These deliberately use ordinary public URLs, not embeds, mocks, or external browser intents.
 */
@RunWith(AndroidJUnit4::class)
class PublicChannelWebViewSmokeTest {

    @Test
    fun eitaaPublicPostRendersTheExpectedMessage() {
        assertPublicPageRendersText(
            url = "https://eitaa.com/s/eitaa/306",
            expectedText = "عرضه نسخه جدید اندروید"
        )
    }

    @Test
    fun balePublicSharePageRendersTheExpectedPost() {
        assertPublicPageRendersText(
            url = "https://ble.ir/s/irannewspaper",
            expectedText = "محسنی اژه‌ای"
        )
    }

    private fun assertPublicPageRendersText(url: String, expectedText: String) {
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        val completed = CountDownLatch(1)
        val renderedText = AtomicReference<String?>()
        val loadError = AtomicReference<String?>()

        try {
            scenario.onActivity { activity ->
                activity.setContent {
                    SafeWebView(
                        url = url,
                        onPageContentReady = {
                            activity.window.decorView.post {
                                val webView = findWebView(activity.window.decorView)
                                if (webView == null) {
                                    loadError.set("SafeWebView did not attach an Android WebView")
                                    completed.countDown()
                                } else {
                                    webView.evaluateJavascript(
                                        "(document.body && document.body.innerText) || ''"
                                    ) { raw ->
                                        renderedText.set(
                                            runCatching {
                                                JSONTokener(raw).nextValue() as? String
                                            }.getOrNull().orEmpty()
                                        )
                                        completed.countDown()
                                    }
                                }
                            }
                        },
                        onErrorOccurred = { message ->
                            loadError.compareAndSet(null, message)
                            completed.countDown()
                        }
                    )
                }
            }

            assertTrue(
                "Timed out waiting for the real SafeWebView page: $url",
                completed.await(55, TimeUnit.SECONDS)
            )
            assertTrue(
                "SafeWebView could not render $url: ${loadError.get().orEmpty()}",
                loadError.get().isNullOrBlank()
            )
            val body = renderedText.get()
            assertNotNull("No visible page body was captured for $url", body)
            assertTrue(
                "Expected post text was not visible in SafeWebView for $url. Body: ${body.orEmpty().take(1200)}",
                body.orEmpty().contains(expectedText, ignoreCase = true)
            )
        } finally {
            scenario.close()
        }
    }

    private fun findWebView(view: View): WebView? {
        if (view is WebView) return view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                findWebView(view.getChildAt(index))?.let { return it }
            }
        }
        return null
    }
}
