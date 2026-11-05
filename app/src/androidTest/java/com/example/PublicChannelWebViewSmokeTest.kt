package com.example

import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.activity.compose.setContent
import androidx.compose.runtime.remember
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.example.core.security.SafeWebView
import com.example.data.model.ViewSession
import com.example.ui.ViewerState
import com.example.ui.screens.ViewerScreen
import org.json.JSONTokener
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * Live-device smoke tests for the public-channel WebView path.
 *
 * Eitaa remains a strict content-render test. The Bale permalink is tested through the
 * real ViewerScreen because a third-party page may remain pending without delivering a
 * WebView terminal callback. The production screen's public-channel deadline must then
 * drive Auto View's one-time skip rather than leaving the user stuck indefinitely.
 */
@RunWith(AndroidJUnit4::class)
class PublicChannelWebViewSmokeTest {

    private enum class ViewerOutcome {
        RENDERED_EXPECTED_CONTENT,
        RENDERED_UNEXPECTED_CONTENT,
        AUTO_SKIPPED,
        URL_BLOCKED,
        WEBVIEW_MISSING
    }

    @Test
    fun eitaaPublicChannelRendersTheExpectedMessage() {
        assertPublicPageRendersText(
            url = "https://eitaa.com/eitaa",
            expectedText = "عرضه نسخه جدید اندروید"
        )
    }

    @Test
    fun balePublicPostRendersOrAutoSkipsWhenThePageCannotFinish() {
        val outcome = exerciseViewerUntilRenderedOrSkipped(
            url = "https://ble.ir/info/518255782042081426/1649267389679",
            expectedText = "دایره‌های کوچک"
        )

        when (outcome) {
            ViewerOutcome.RENDERED_EXPECTED_CONTENT -> Unit
            ViewerOutcome.AUTO_SKIPPED -> {
                // The external page did not finish in the allowed period. Auto View
                // correctly advanced instead of hanging the viewing session.
            }
            else -> throw AssertionError("Unexpected Bale Viewer outcome: $outcome")
        }
    }

    @Test
    fun unreachableWebsiteTriggersExactlyOneAutomaticSkip() {
        val outcome = exerciseViewerUntilRenderedOrSkipped(
            url = "https://sitebin-webview-unreachable.invalid/",
            expectedText = null
        )

        assertEquals(
            "An unreachable destination must be rejected and Auto View must advance",
            ViewerOutcome.AUTO_SKIPPED,
            outcome
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

    private fun exerciseViewerUntilRenderedOrSkipped(
        url: String,
        expectedText: String?
    ): ViewerOutcome {
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        val completed = CountDownLatch(1)
        val outcome = AtomicReference<ViewerOutcome?>()
        val skipCount = AtomicInteger(0)

        try {
            scenario.onActivity { activity ->
                activity.setContent {
                    val session = remember(url) {
                        ViewSession(
                            campaignId = "ci-webview-smoke-test",
                            targetUrl = url,
                            domain = url.substringAfter("://").substringBefore("/"),
                            requiredDurationSeconds = 5,
                            rewardCoins = 0L
                        )
                    }

                    ViewerScreen(
                        viewerState = ViewerState.Loading(session),
                        autoViewEnabled = true,
                        onContentReady = {
                            activity.window.decorView.post {
                                val webView = findWebView(activity.window.decorView)
                                if (webView == null) {
                                    outcome.compareAndSet(null, ViewerOutcome.WEBVIEW_MISSING)
                                } else {
                                    webView.evaluateJavascript(
                                        "(document.body && document.body.innerText) || ''"
                                    ) { raw ->
                                        val body = runCatching {
                                            JSONTokener(raw).nextValue() as? String
                                        }.getOrNull().orEmpty()
                                        val rendered = if (
                                            expectedText != null &&
                                            body.contains(expectedText, ignoreCase = true)
                                        ) {
                                            ViewerOutcome.RENDERED_EXPECTED_CONTENT
                                        } else {
                                            ViewerOutcome.RENDERED_UNEXPECTED_CONTENT
                                        }
                                        outcome.compareAndSet(null, rendered)
                                    }
                                }
                                completed.countDown()
                            }
                        },
                        onUrlBlocked = { _, _ ->
                            outcome.compareAndSet(null, ViewerOutcome.URL_BLOCKED)
                            completed.countDown()
                        },
                        onSkip = {
                            skipCount.incrementAndGet()
                            outcome.compareAndSet(null, ViewerOutcome.AUTO_SKIPPED)
                            completed.countDown()
                        },
                        onNextSite = {},
                        onReport = { _, _ -> },
                        onBack = {}
                    )
                }
            }

            assertTrue(
                "ViewerScreen neither rendered nor auto-skipped the destination: $url",
                completed.await(30, TimeUnit.SECONDS)
            )

            // Allow any duplicate asynchronous callbacks to arrive before asserting
            // the one-skip-per-session invariant.
            if (outcome.get() == ViewerOutcome.AUTO_SKIPPED) {
                Thread.sleep(1_200L)
                assertEquals("Auto View skipped the same session more than once", 1, skipCount.get())
            }

            return outcome.get()
                ?: throw AssertionError("ViewerScreen ended without a terminal outcome for $url")
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
