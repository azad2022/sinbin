package com.example

import android.webkit.JavascriptInterface
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
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
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class SafeWebViewPostOriginGuardTest {

    @Test
    fun crossOriginPostFormsAreBlockedInMainFrameAndSrcdocFrames() {
        assumeTrue(
            "The emulator WebView must support document-start JavaScript.",
            WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)
        )

        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val completed = CountDownLatch(1)
        val result = AtomicReference<String?>(null)
        val failure = AtomicReference<String?>(null)
        val stages = CopyOnWriteArrayList<String>()
        val bridge = object {
            @JavascriptInterface
            fun report(value: String) {
                stages += value
                when {
                    value.startsWith("complete|") -> {
                        result.set(value)
                        completed.countDown()
                    }
                    value.startsWith("failed|") -> {
                        failure.compareAndSet(null, value)
                        completed.countDown()
                    }
                }
            }
        }
        lateinit var webView: WebView

        instrumentation.runOnMainSync {
            webView = WebView(context).apply {
                settings.javaScriptEnabled = true
                addJavascriptInterface(bridge, "SiteBinGuardTestBridge")
                WebViewCompat.addDocumentStartJavaScript(
                    this,
                    buildMainFrameFormOriginGuard("https://sitebin.test/"),
                    setOf("*")
                )
                webViewClient = object : WebViewClient() {
                    override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                        super.onPageStarted(view, url, favicon)
                        if (!url.isNullOrBlank() && !url.startsWith("https://sitebin.test/")) {
                            val message = "Unexpected main-frame navigation: " + url
                            failure.compareAndSet(null, message)
                            completed.countDown()
                        }
                    }

                    override fun onReceivedError(
                        view: WebView?,
                        request: WebResourceRequest?,
                        error: WebResourceError?
                    ) {
                        super.onReceivedError(view, request, error)
                        if (request?.isForMainFrame == true) {
                            val message = "Main-frame load failed at " + request.url + ": " + error?.description
                            failure.compareAndSet(null, message)
                            completed.countDown()
                        }
                    }

                    override fun onReceivedHttpError(
                        view: WebView?,
                        request: WebResourceRequest?,
                        errorResponse: WebResourceResponse?
                    ) {
                        super.onReceivedHttpError(view, request, errorResponse)
                        if (request?.isForMainFrame == true) {
                            val message = "Main-frame HTTP " + errorResponse?.statusCode + " at " + request.url
                            failure.compareAndSet(null, message)
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
                        (function () {
                            const expectedOrigin = 'https://sitebin.test';
                            const report = function (value) {
                                window.SiteBinGuardTestBridge.report(value);
                            };
                            report('parent-script-started|' + location.href);

                            // A direct programmatic POST does not dispatch a submit event.
                            const directForm = document.createElement('form');
                            directForm.method = 'POST';
                            directForm.action = 'https://attacker.invalid/direct-submit';
                            document.body.appendChild(directForm);
                            directForm.submit();
                            const directSubmitBlocked = location.origin === expectedOrigin;

                            // A submitter's formaction must not override the validated form action.
                            const submitterForm = document.createElement('form');
                            submitterForm.method = 'POST';
                            submitterForm.action = expectedOrigin + '/same-origin-default';
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
                            const submitterOverrideBlocked = !submitEventReachedPage;

                            const runSrcdocCase = function (useAttribute, done) {
                                const frame = document.createElement('iframe');
                                frame.addEventListener('load', function () {
                                    try {
                                        const childWindow = frame.contentWindow;
                                        const childDocument = frame.contentDocument;
                                        if (!childWindow || !childDocument ||
                                            childWindow.location.href === 'about:blank') {
                                            return;
                                        }

                                        const body = childDocument.body;
                                        if (!body) {
                                            report('failed|srcdoc body missing');
                                            return;
                                        }

                                        const attempted = body.getAttribute('data-post-attempted') === 'true';
                                        const guardInstalled = body.getAttribute('data-guard-installed') === 'true';
                                        const afterSubmitReturned = body.getAttribute('data-after-submit-returned') === 'true';
                                        const parentAccess = body.getAttribute('data-parent-access') === 'true';
                                        const actionOrigin = body.getAttribute('data-action-origin');
                                        const target = body.getAttribute('data-effective-target');
                                        if (!attempted) {
                                            report('failed|srcdoc inline form script did not execute');
                                            return;
                                        }

                                        done({
                                            attempted: attempted,
                                            guardInstalled: guardInstalled,
                                            afterSubmitReturned: afterSubmitReturned,
                                            parentAccess: parentAccess,
                                            actionOrigin: actionOrigin,
                                            target: target,
                                            frameUrl: childWindow.location.href
                                        });
                                        frame.remove();
                                    } catch (error) {
                                        report('failed|srcdoc inspection failed: ' + String(error));
                                    }
                                });

                                const childMarkup =
                                    '<!doctype html><html><head><base target="_top"></head><body>' +
                                    '<script>' +
                                    'document.body.setAttribute("data-post-attempted", "true");' +
                                    'const guardInstalled = Object.prototype.hasOwnProperty.call(' +
                                    'HTMLFormElement.prototype, "__sitebinFormOriginGuardInstalled");' +
                                    'let parentAccess = false;' +
                                    'try { parentAccess = window.parent.document.body !== null; } catch (_) {}' +
                                    'document.body.setAttribute("data-effective-target", ' +
                                    'document.querySelector("base").target);' +
                                    'const childForm = document.createElement("form");' +
                                    'childForm.method = "POST";' +
                                    'childForm.action = "https://attacker.invalid/srcdoc-post";' +
                                    'document.body.appendChild(childForm);' +
                                    'document.body.setAttribute("data-action-origin", new URL(childForm.action).origin);' +
                                    'childForm.submit();' +
                                    'document.body.setAttribute("data-after-submit-returned", "true");' +
                                    'document.body.setAttribute("data-guard-installed", String(guardInstalled));' +
                                    'document.body.setAttribute("data-parent-access", String(parentAccess));' +
                                    '</' + 'script></body></html>';

                                if (useAttribute) {
                                    frame.setAttribute('srcdoc', childMarkup);
                                } else {
                                    frame.srcdoc = childMarkup;
                                }
                                document.body.appendChild(frame);
                            };

                            report('parent-forms-checked|' +
                                directSubmitBlocked + '|' + submitterOverrideBlocked);

                            runSrcdocCase(false, function (propertyResult) {
                                runSrcdocCase(true, function (attributeResult) {
                                    report(
                                        'complete|' +
                                        directSubmitBlocked + '|' +
                                        submitterOverrideBlocked + '|' +
                                        propertyResult.attempted + '|' +
                                        propertyResult.guardInstalled + '|' +
                                        propertyResult.afterSubmitReturned + '|' +
                                        propertyResult.parentAccess + '|' +
                                        propertyResult.actionOrigin + '|' +
                                        propertyResult.target + '|' +
                                        attributeResult.attempted + '|' +
                                        attributeResult.guardInstalled + '|' +
                                        attributeResult.afterSubmitReturned + '|' +
                                        attributeResult.parentAccess + '|' +
                                        attributeResult.actionOrigin + '|' +
                                        attributeResult.target + '|' +
                                        location.origin
                                    );
                                });
                            });
                        })();
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
            val finishedInTime = completed.await(10, TimeUnit.SECONDS)
            if (!finishedInTime) {
                val diagnostics = AtomicReference<String?>(null)
                instrumentation.runOnMainSync {
                    diagnostics.set(
                        "url=" + webView.url +
                            ", progress=" + webView.progress +
                            ", contentHeight=" + webView.contentHeight
                    )
                }
                failure.compareAndSet(
                    null,
                    "Timed out; " + diagnostics.get() + "; bridge stages=" + stages.joinToString(" -> ")
                )
            }

            assertTrue(
                "WebView POST-origin regression did not complete: " + failure.get(),
                finishedInTime
            )
            failure.get()?.let { throw AssertionError(it) }
            assertEquals(
                "complete|true|true|true|true|true|https://attacker.invalid|_top|true|true|true|true|https://attacker.invalid|_top|https://sitebin.test",
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
