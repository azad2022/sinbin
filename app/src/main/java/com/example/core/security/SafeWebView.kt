package com.example.core.security

import android.annotation.SuppressLint
import android.graphics.Bitmap
import java.net.URI
import android.net.http.SslError
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.example.BuildConfig
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.webkit.ScriptHandler
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature

/**
 * Classifies an SSL callback as belonging to the top-level document only when its
 * URL matches the WebView's current document URL. Missing/malformed values fail
 * closed so the caller reports the failure rather than risking an untrusted page.
 */
internal fun isMainFrameSslErrorUrl(currentUrl: String?, failingUrl: String?): Boolean {
    if (currentUrl.isNullOrBlank() || failingUrl.isNullOrBlank()) return true

    return runCatching {
        val current = URI(currentUrl).normalize()
        val failing = URI(failingUrl).normalize()

        fun effectivePort(uri: URI): Int = when {
            uri.port >= 0 -> uri.port
            uri.scheme.equals("https", ignoreCase = true) -> 443
            uri.scheme.equals("http", ignoreCase = true) -> 80
            else -> -1
        }

        val currentHost = current.host
        val failingHost = failing.host
        val sameHost = when {
            currentHost != null && failingHost != null ->
                currentHost.equals(failingHost, ignoreCase = true)
            currentHost == null && failingHost == null &&
                !current.rawAuthority.isNullOrBlank() && !failing.rawAuthority.isNullOrBlank() ->
                current.rawAuthority.equals(failing.rawAuthority, ignoreCase = true)
            else -> false
        }

        current.isAbsolute &&
            failing.isAbsolute &&
            current.scheme.equals(failing.scheme, ignoreCase = true) &&
            sameHost &&
            effectivePort(current) == effectivePort(failing) &&
            current.rawPath.orEmpty().trimEnd('/') == failing.rawPath.orEmpty().trimEnd('/') &&
            current.rawQuery == failing.rawQuery &&
            current.rawUserInfo == failing.rawUserInfo
    }.getOrDefault(true)
}


internal data class WebOrigin(
    val scheme: String,
    val host: String,
    val port: Int
) {
    val serialized: String
        get() = "$scheme://$host" + if (port == 443) "" else ":$port"

    fun matches(candidateUrl: String?): Boolean =
        parse(candidateUrl) == this

    companion object {
        fun parse(rawUrl: String?): WebOrigin? = runCatching {
            require(!rawUrl.isNullOrBlank())
            val uri = URI(rawUrl)
            require(uri.isAbsolute)
            require(uri.scheme.equals("https", ignoreCase = true))
            require(uri.rawUserInfo == null)
            val host = uri.host?.trim()?.lowercase()
            require(!host.isNullOrBlank())
            val port = if (uri.port == -1) 443 else uri.port
            require(port in 1..65535)
            WebOrigin("https", host, port)
        }.getOrNull()
    }
}

internal fun isSameWebOrigin(expectedUrl: String?, candidateUrl: String?): Boolean =
    WebOrigin.parse(expectedUrl)?.matches(candidateUrl) == true

/**
 * Runs at document-start in every frame. Cross-origin form submissions that could
 * navigate the top-level browsing context are blocked before page scripts execute.
 * WebViewClient.shouldOverrideUrlLoading is not invoked for POST navigations.
 */
internal fun buildMainFrameFormOriginGuard(expectedOriginUrl: String): String {
    val origin = requireNotNull(WebOrigin.parse(expectedOriginUrl)) {
        "A valid HTTPS origin is required for the WebView navigation guard."
    }
    // WebOrigin is already strictly parsed as an HTTPS origin. Escape it as a
    // JavaScript single-quoted string without depending on Android's JSONObject
    // implementation (which is stubbed in local JVM unit tests).
    val encodedOrigin = "'" + origin.serialized
        .replace("\\", "\\\\")
        .replace("'", "\\'")
        .replace("\r", "\\r")
        .replace("\n", "\\n") + "'"
    return """
        (function () {
            'use strict';
            const expectedOrigin = $encodedOrigin;
            const isSubmitControl = function (submitter) {
                return submitter instanceof HTMLButtonElement ||
                    submitter instanceof HTMLInputElement;
            };
            const effectiveTarget = function (form, submitter) {
                if (isSubmitControl(submitter) && submitter.hasAttribute('formtarget')) {
                    return String(submitter.formTarget || '_self').toLowerCase();
                }
                return String(form.target || '_self').toLowerCase();
            };
            const effectiveAction = function (form, submitter) {
                if (isSubmitControl(submitter) && submitter.hasAttribute('formaction')) {
                    return submitter.formAction;
                }
                return form.action;
            };
            const isTopNavigationTarget = function (form, submitter) {
                const target = effectiveTarget(form, submitter);
                return window.top === window ||
                    target === '_top' ||
                    target === '_parent' ||
                    target !== '_self';
            };
            const isAllowedAction = function (action) {
                try {
                    return new URL(action || window.location.href, window.location.href).origin === expectedOrigin;
                } catch (_) {
                    return false;
                }
            };
            const mustBlock = function (form, submitter) {
                return isTopNavigationTarget(form, submitter) &&
                    !isAllowedAction(effectiveAction(form, submitter));
            };
            document.addEventListener('submit', function (event) {
                const form = event.target;
                if (form instanceof HTMLFormElement && mustBlock(form, event.submitter)) {
                    event.preventDefault();
                    event.stopImmediatePropagation();
                }
            }, true);
            const prototype = HTMLFormElement.prototype;
            const nativeSubmit = prototype.submit;
            Object.defineProperty(prototype, 'submit', {
                configurable: false,
                enumerable: false,
                writable: false,
                value: function () {
                    if (mustBlock(this, null)) return;
                    return nativeSubmit.call(this);
                }
            });
        })();
    """.trimIndent()
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun SafeWebView(
    url: String,
    contentKey: String = url,
    modifier: Modifier = Modifier,
    onPageStarted: () -> Unit = {},
    onPageContentReady: () -> Unit = {},
    onUrlBlocked: (String, String) -> Unit = { _, _ -> },
    onErrorOccurred: (String) -> Unit = {}
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    val expectedOrigin = remember(url) { WebOrigin.parse(url) }
    var webViewRef by remember { mutableStateOf<WebView?>(null) }
    var webViewGeneration by remember { mutableStateOf(0) }
    var rendererTerminated by remember { mutableStateOf(false) }
    var currentPageStartedAt by remember { mutableStateOf(0L) }
    var contentReadyReported by remember { mutableStateOf(false) }
    var contentReadyPending by remember { mutableStateOf(false) }
    var documentStartScriptHandler by remember { mutableStateOf<ScriptHandler?>(null) }
    var pageLoadGeneration by remember { mutableStateOf(0) }
    var mainFrameLoadFailed by remember { mutableStateOf(false) }

    val currentOnPageStarted by rememberUpdatedState(onPageStarted)
    val currentOnPageContentReady by rememberUpdatedState(onPageContentReady)
    val currentOnUrlBlocked by rememberUpdatedState(onUrlBlocked)
    val currentOnErrorOccurred by rememberUpdatedState(onErrorOccurred)

    val safeClient = remember(expectedOrigin) {
        object : WebViewClient() {
            private val mainHandler = Handler(Looper.getMainLooper())
            private var pendingPublicChannelReadyCheck: Runnable? = null
            private var visualStateRequestId = 0L

            private fun cancelPublicChannelReadyCheck() {
                pendingPublicChannelReadyCheck?.let(mainHandler::removeCallbacks)
                pendingPublicChannelReadyCheck = null
            }

            /**
             * SSL callbacks are resource-scoped: Android may invoke this for an image,
             * iframe, stylesheet, or the main document. Only a failure for the current
             * top-level URL should fail the complete viewing session.
             */
            private fun isMainFrameSslError(view: WebView?, error: SslError?): Boolean =
                isMainFrameSslErrorUrl(view?.url, error?.url)

            private fun reportMainFrameFailure(message: String) {
                if (mainFrameLoadFailed) return
                mainFrameLoadFailed = true
                contentReadyReported = false
                contentReadyPending = false
                cancelPublicChannelReadyCheck()
                currentOnErrorOccurred(message)
            }

            private fun reportContentVisible(view: WebView?, pageUrl: String?) {
                val targetView = view ?: return
                if (contentReadyReported || contentReadyPending || mainFrameLoadFailed) return
                if (expectedOrigin?.matches(pageUrl) != true) {
                    reportMainFrameFailure("مقصد وب‌سایت در طول سشن تغییر کرد؛ بارگذاری متوقف شد.")
                    return
                }

                val generation = pageLoadGeneration
                contentReadyPending = true
                val requestId = ++visualStateRequestId
                targetView.postVisualStateCallback(
                    requestId,
                    object : WebView.VisualStateCallback() {
                        override fun onComplete(requestId: Long) {
                            if (generation != pageLoadGeneration || targetView !== webViewRef) {
                                return
                            }
                            contentReadyPending = false
                            if (mainFrameLoadFailed) return
                            if (expectedOrigin?.matches(targetView.url) != true) {
                                reportMainFrameFailure("مقصد وب‌سایت پیش از نمایش نهایی تغییر کرد.")
                                return
                            }

                            contentReadyReported = true
                            cancelPublicChannelReadyCheck()
                            val elapsedMs = if (currentPageStartedAt > 0L) {
                                SystemClock.elapsedRealtime() - currentPageStartedAt
                            } else {
                                -1L
                            }
                            if (BuildConfig.DEBUG) {
                                val host = expectedOrigin.host
                                android.util.Log.d(
                                    "SiteBinPerf",
                                    "operation=webview_visual_state_ready host=$host elapsedMs=$elapsedMs"
                                )
                            }
                            currentOnPageContentReady()
                        }
                    }
                )
            }

            /**
             * Public channel pages can commit an empty JavaScript shell before the actual
             * message is rendered. For supported Eitaa/Bale URLs, wait briefly for meaningful
             * body text or visible media before starting the existing viewing timer. The WebView
             * layout and navigation surface are unchanged.
             */
            private fun waitForPublicChannelContent(view: WebView?, pageUrl: String?) {
                val targetView = view ?: return
                cancelPublicChannelReadyCheck()
                val generation = pageLoadGeneration
                val startedAt = SystemClock.elapsedRealtime()
                val readinessScript = """(function() {
                    var body = document.body;
                    if (!body) return false;
                    var text = (body.innerText || '').replace(/\s+/g, ' ').trim();
                    var onlyLoading = /^(loading|please wait|در حال بارگذاری|لطفاً منتظر بمانید)[.!… ]*$/i.test(text);
                    var media = Array.prototype.some.call(body.querySelectorAll('img,video,canvas'), function(el) {
                        var rect = el.getBoundingClientRect();
                        if (rect.width < 8 || rect.height < 8) return false;
                        if (el.tagName === 'IMG') return el.complete && el.naturalWidth > 0;
                        return true;
                    });
                    return !onlyLoading && (text.length >= 20 || media);
                })()""".trimIndent()

                lateinit var check: Runnable
                check = object : Runnable {
                    override fun run() {
                        if (generation != pageLoadGeneration || contentReadyReported ||
                            mainFrameLoadFailed || targetView !== webViewRef
                        ) {
                            if (pendingPublicChannelReadyCheck === this) pendingPublicChannelReadyCheck = null
                            return
                        }
                        targetView.evaluateJavascript(readinessScript) { rawResult ->
                            if (generation != pageLoadGeneration || contentReadyReported ||
                                mainFrameLoadFailed || targetView !== webViewRef
                            ) return@evaluateJavascript

                            if (rawResult?.trim() == "true") {
                                pendingPublicChannelReadyCheck = null
                                reportContentVisible(targetView, pageUrl)
                            } else if (SystemClock.elapsedRealtime() - startedAt >= 12_000L) {
                                pendingPublicChannelReadyCheck = null
                                reportMainFrameFailure("محتوای عمومی ایتا یا بله در مهلت مجاز نمایش داده نشد.")
                            } else {
                                mainHandler.postDelayed(check, 350L)
                            }
                        }
                    }
                }
                pendingPublicChannelReadyCheck = check
                mainHandler.post(check)
            }

            override fun shouldOverrideUrlLoading(
                view: WebView?,
                request: WebResourceRequest?
            ): Boolean {
                val targetUrl = request?.url?.toString() ?: return true
                if (request.isForMainFrame && expectedOrigin?.matches(targetUrl) != true) {
                    currentOnUrlBlocked(
                        targetUrl,
                        "ناوبری اصلی به مبدأیی غیر از مبدأ سشن مسدود شد."
                    )
                    reportMainFrameFailure("تغییر مبدأ وب‌سایت در طول سشن مجاز نیست.")
                    return true
                }

                val check = UrlSecurityPolicy.evaluateUrl(targetUrl)
                return when (check) {
                    is PolicyResult.Allowed -> false
                    is PolicyResult.Blocked -> {
                        currentOnUrlBlocked(targetUrl, check.reason)
                        true
                    }
                    is PolicyResult.Controlled -> {
                        currentOnUrlBlocked(targetUrl, check.reason)
                        true
                    }
                }
            }

            override fun onPageStarted(view: WebView?, pageUrl: String?, favicon: Bitmap?) {
                super.onPageStarted(view, pageUrl, favicon)
                pageLoadGeneration += 1
                cancelPublicChannelReadyCheck()
                mainFrameLoadFailed = false
                contentReadyPending = false
                currentPageStartedAt = SystemClock.elapsedRealtime()
                contentReadyReported = false

                if (expectedOrigin?.matches(pageUrl) != true) {
                    view?.stopLoading()
                    reportMainFrameFailure("مقصد وب‌سایت به مبدأ دیگری تغییر کرد؛ سشن متوقف شد.")
                    return
                }
                currentOnPageStarted()
            }

            override fun onPageCommitVisible(view: WebView?, pageUrl: String?) {
                super.onPageCommitVisible(view, pageUrl)
                if (UrlSecurityPolicy.publicChannelPlatform(pageUrl) != null) return
                reportContentVisible(view, pageUrl)
            }

            override fun onPageFinished(view: WebView?, pageUrl: String?) {
                super.onPageFinished(view, pageUrl)
                if (UrlSecurityPolicy.publicChannelPlatform(pageUrl) != null) {
                    waitForPublicChannelContent(view, pageUrl)
                } else {
                    reportContentVisible(view, pageUrl)
                }
            }

            override fun onReceivedHttpError(
                view: WebView?,
                request: WebResourceRequest?,
                errorResponse: WebResourceResponse?
            ) {
                super.onReceivedHttpError(view, request, errorResponse)
                if (request?.isForMainFrame == true && (errorResponse?.statusCode ?: 0) >= 400) {
                    reportMainFrameFailure(
                        "صفحه مقصد با خطای HTTP " + (errorResponse?.statusCode ?: 0) + " پاسخ داد."
                    )
                }
            }

            override fun onReceivedSslError(
                view: WebView?,
                handler: SslErrorHandler?,
                error: SslError?
            ) {
                // Security invariant: never proceed past an invalid certificate.
                // The callback may refer to a subresource, not the main document.
                handler?.cancel()

                if (!isMainFrameSslError(view, error)) {
                    if (BuildConfig.DEBUG) {
                        val resourceHost = runCatching {
                            URI(error?.url.orEmpty()).host ?: "unknown"
                        }.getOrDefault("unknown")
                        android.util.Log.w(
                            "SiteBinWebView",
                            "Rejected SSL subresource without failing page; host=$resourceHost"
                        )
                    }
                    return
                }

                reportMainFrameFailure("گواهی امنیتی صفحه اصلی این وب‌سایت نامعتبر است (SSL Error).")
            }

            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: WebResourceError?
            ) {
                super.onReceivedError(view, request, error)
                if (request?.isForMainFrame == true) {
                    reportMainFrameFailure(
                        "خطا در بارگذاری وب‌سایت. ممکن است سرور مقصد در دسترس نباشد."
                    )
                }
            }

            override fun onRenderProcessGone(
                view: WebView?,
                detail: RenderProcessGoneDetail?
            ): Boolean {
                view?.let { terminatedView ->
                    terminatedView.stopLoading()
                    (terminatedView.parent as? ViewGroup)?.removeView(terminatedView)
                    if (webViewRef === terminatedView) {
                        webViewRef = null
                    }
                    terminatedView.destroy()
                }
                rendererTerminated = true
                mainFrameLoadFailed = true
                cancelPublicChannelReadyCheck()
                contentReadyReported = false
                contentReadyPending = false
                if (BuildConfig.DEBUG) {
                    android.util.Log.w(
                        "SiteBinWebView",
                        "Renderer terminated; didCrash=${detail?.didCrash() == true}. " +
                            "The destroyed WebView will not be reused."
                    )
                }
                currentOnErrorOccurred("موتور نمایش وب‌سایت متوقف شد. برای ساخت مجدد مرورگر، تلاش مجدد را بزنید.")
                return true
            }
        }
    }

    val safeChromeClient = remember {
        object : WebChromeClient() {
            // Anti-Popup & Anti-Escape Guard
            override fun onCreateWindow(
                view: WebView?,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: android.os.Message?
            ): Boolean {
                // Deny creation of new tabs or external browser windows
                return false
            }

            // Deny sensor/hardware access
            override fun onPermissionRequest(request: PermissionRequest?) {
                request?.deny()
            }
        }
    }

    // Lifecycle observer to pause scripts & audio when backgrounded and release memory when destroyed
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_PAUSE -> {
                    webViewRef?.onPause()
                    webViewRef?.pauseTimers()
                }
                Lifecycle.Event.ON_RESUME -> {
                    webViewRef?.onResume()
                    webViewRef?.resumeTimers()
                }
                Lifecycle.Event.ON_DESTROY -> {
                    webViewRef?.let { webView ->
                        webView.stopLoading()
                        (webView.parent as? ViewGroup)?.removeView(webView)
                        webView.destroy()
                    }
                    documentStartScriptHandler?.remove()
                    documentStartScriptHandler = null
                    webViewRef = null
                }
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            webViewRef?.let { webView ->
                webView.stopLoading()
                (webView.parent as? ViewGroup)?.removeView(webView)
                webView.destroy()
            }
            documentStartScriptHandler?.remove()
            documentStartScriptHandler = null
            webViewRef = null
        }
    }

    // Each session/URL gets a fresh WebView instance. This binds the document-start
    // form guard to one immutable server-issued origin and avoids stale async callbacks.
    LaunchedEffect(contentKey, url, rendererTerminated) {
        contentReadyReported = false
        contentReadyPending = false
        if (rendererTerminated) {
            rendererTerminated = false
            webViewGeneration += 1
        }
    }

    key(webViewGeneration, contentKey, url) {
        AndroidView(
            modifier = modifier.fillMaxSize(),
            factory = { ctx ->
                WebView(ctx).apply {
                    webViewRef = this

                    val origin = expectedOrigin
                    if (origin == null) {
                        mainFrameLoadFailed = true
                        currentOnErrorOccurred("نشانی مقصد فاقد مبدأ HTTPS معتبر است؛ بارگذاری متوقف شد.")
                        return@apply
                    }
                    if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                        mainFrameLoadFailed = true
                        currentOnErrorOccurred(
                            "نسخهٔ موتور WebView از کنترل امن فرم‌های POST پشتیبانی نمی‌کند؛ برای حفظ امنیت بارگذاری متوقف شد."
                        )
                        return@apply
                    }
                    try {
                        documentStartScriptHandler = WebViewCompat.addDocumentStartJavaScript(
                            this,
                            buildMainFrameFormOriginGuard(origin.serialized),
                            setOf("*")
                        )
                    } catch (error: Exception) {
                        mainFrameLoadFailed = true
                        currentOnErrorOccurred(
                            "راه‌اندازی کنترل امن ناوبری ناموفق بود؛ برای حفظ امنیت بارگذاری متوقف شد."
                        )
                        if (BuildConfig.DEBUG) {
                            android.util.Log.e("SiteBinWebView", "Document-start guard registration failed.", error)
                        }
                        return@apply
                    }

                    // WebView 153/154 have a documented, device/GPU-specific black-rendering
                    // regression. Apply software drawing only to those affected release families;
                    // keep hardware drawing for other versions to preserve video/WebGL performance.
                    val webViewMajorVersion = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        WebView.getCurrentWebViewPackage()
                            ?.versionName
                            ?.substringBefore('.')
                            ?.toIntOrNull()
                    } else {
                        null
                    }
                    if (webViewMajorVersion != null && webViewMajorVersion in 153..154) {
                        setLayerType(View.LAYER_TYPE_SOFTWARE, null)
                        if (BuildConfig.DEBUG) {
                            android.util.Log.w(
                                "SiteBinWebView",
                                "Using software drawing for known WebView $webViewMajorVersion rendering regression."
                            )
                        }
                    }

                    // Security Hardening & Performance Configurations.
                    settings.apply {
                        javaScriptEnabled = true
                        domStorageEnabled = true
                        allowFileAccess = false
                        allowContentAccess = false
                        setSupportMultipleWindows(false)
                        javaScriptCanOpenWindowsAutomatically = false
                        mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                        useWideViewPort = true
                        loadWithOverviewMode = true
                        builtInZoomControls = true
                        displayZoomControls = false

                        cacheMode = WebSettings.LOAD_DEFAULT
                        mediaPlaybackRequiresUserGesture = true
                        setGeolocationEnabled(false)
                        databaseEnabled = false
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            safeBrowsingEnabled = true
                        }
                    }

                    // Anti-Download Policy: block any file download attempt.
                    setDownloadListener { downloadUrl, _, _, _, _ ->
                        currentOnUrlBlocked(downloadUrl, "دانلود مستقیم فایل در سایت بین مجاز نیست.")
                    }

                    CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)

                    webViewClient = safeClient
                    webChromeClient = safeChromeClient

                    loadUrl(url)
                }
            },
            update = { webView ->
                webViewRef = webView
            }

        )
    }
}
