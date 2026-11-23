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
    fun directAndSubmitterOverriddenCrossOriginPostFormsAreBlocked() {
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
                                "document.body.getAttribute('data-direct-submit-blocked') + '|' + " +
                                "document.body.getAttribute('data-submitter-override-blocked')"
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
                        const directForm = document.createElement('form');
                        directForm.method = 'POST';
                        directForm.action = 'https://attacker.invalid/direct';
                        document.body.appendChild(directForm);
                        directForm.submit();
                        document.body.setAttribute('data-direct-submit-blocked', String(location.origin === 'https://sitebin.test'));

                        const submitterForm = document.createElement('form');
                        submitterForm.method = 'POST';
                        submitterForm.action = 'https://sitebin.test/same-origin-default';
                        const submitter = document.createElement('button');
                        submitter.type = 'submit';
                        submitter.setAttribute('formaction', 'https://attacker.invalid/submitter-override');
                        submitterForm.appendChild(submitter);
                        document.body.appendChild(submitterForm);

                        let submitEventReachedPage = false;
                        document.addEventListener('submit', function () {
                            submitEventReachedPage = true;
                        }, false);
                        submitterForm.requestSubmit(submitter);
                        document.body.setAttribute('data-submitter-override-blocked', String(!submitEventReachedPage));
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
            assertTrue(
                "WebView did not finish the local test page.",
                completed.await(10, TimeUnit.SECONDS)
            )
            assertEquals(
                "\\"https://sitebin.test|true|true\\"",
                result.get()
            )
        } finally {
            instrumentation.runOnMainSync {
                webView.stopLoading()
                webView.destroy()
            }
        }
    }
}
