package com.example.core.security

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.example.BuildConfig
import android.view.View
import android.view.ViewGroup
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
import android.webkit.WebViewRenderProcessClient
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

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun SafeWebView(
    url: String,
    contentKey: String = url,
    modifier: Modifier = Modifier,
    onPageStarted: () -> Unit = {},
    onPageContentReady: () -> Unit = {},
    onUrlBlocked: (String, String) -> Unit = { _, _ -> },
    onErrorOccurred: (String) -> Unit = {},
    onSslErrorOccurred: (String) -> Unit = onErrorOccurred,
    onMainFrameNavigationBlocked: (String, String) -> Unit = { _, _ -> }
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    // Keep track of the currently loaded URL requested by Compose
    // to prevent unwanted re-loads on timer ticks / recompositions
    var targetLoadKey by remember { mutableStateOf<String?>(null) }
    var webViewRef by remember { mutableStateOf<WebView?>(null) }
    var webViewGeneration by remember { mutableStateOf(0) }
    var rendererTerminated by remember { mutableStateOf(false) }
    var currentPageStartedAt by remember { mutableStateOf(0L) }
    var contentReadyReported by remember { mutableStateOf(false) }
    var pageLoadGeneration by remember { mutableStateOf(0) }
    var mainFrameLoadFailed by remember { mutableStateOf(false) }
    var sslErrorReported by remember { mutableStateOf(false) }

    val currentOnPageStarted by rememberUpdatedState(onPageStarted)
    val currentOnPageContentReady by rememberUpdatedState(onPageContentReady)
    val currentOnUrlBlocked by rememberUpdatedState(onUrlBlocked)
    val currentOnErrorOccurred by rememberUpdatedState(onErrorOccurred)
    val currentOnSslErrorOccurred by rememberUpdatedState(onSslErrorOccurred)
    val currentOnMainFrameNavigationBlocked by rememberUpdatedState(onMainFrameNavigationBlocked)
    val currentExpectedUrl by rememberUpdatedState(url)

    val safeClient = remember {
        object : WebViewClient() {
            private val mainHandler = Handler(Looper.getMainLooper())
            private var pendingPublicChannelReadyCheck: Runnable? = null
            private var mainFrameNavigationUrl: String? = null
            private var visualStateRequestedGeneration: Int = -1

            private fun cancelPublicChannelReadyCheck() {
                pendingPublicChannelReadyCheck?.let(mainHandler::removeCallbacks)
                pendingPublicChannelReadyCheck = null
            }

            private fun reportContentVisible(pageUrl: String?) {
                if (contentReadyReported || mainFrameLoadFailed) return
                val visibleUrl = pageUrl ?: return
                if (!UrlSecurityPolicy.isSameOrigin(visibleUrl, currentExpectedUrl)) return

                contentReadyReported = true
                cancelPublicChannelReadyCheck()
                val elapsedMs = if (currentPageStartedAt > 0L) {
                    SystemClock.elapsedRealtime() - currentPageStartedAt
                } else {
                    -1L
                }
                if (BuildConfig.DEBUG) {
                    val host = runCatching {
                        visibleUrl.substringAfter("://").substringBefore("/")
                    }.getOrDefault("unknown")
                    android.util.Log.d(
                        "SiteBinPerf",
                        "operation=webview_content_visible host=$host elapsedMs=$elapsedMs"
                    )
                }
                currentOnPageContentReady()
            }

            private fun requestVisualState(view: WebView?, pageUrl: String?) {
                val targetView = view ?: return
                val generation = pageLoadGeneration
                if (visualStateRequestedGeneration == generation) return
                if (!UrlSecurityPolicy.isSameOrigin(pageUrl, currentExpectedUrl)) return

                visualStateRequestedGeneration = generation
                targetView.postVisualStateCallback(
                    generation.toLong(),
                    object : WebView.VisualStateCallback() {
                        override fun onComplete(requestId: Long) {
                            if (
                                generation != pageLoadGeneration ||
                                targetView !== webViewRef ||
                                mainFrameLoadFailed
                            ) return
                            reportContentVisible(pageUrl)
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
                                reportContentVisible(pageUrl)
                            } else if (SystemClock.elapsedRealtime() - startedAt >= 20_000L) {
                                pendingPublicChannelReadyCheck = null
                                currentOnErrorOccurred("محتوای عمومی ایتا یا بله در مهلت مجاز نمایش داده نشد.")
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
                val webRequest = request ?: return true
                val targetUrl = webRequest.url.toString()
                val isMainFrame = webRequest.isForMainFrame
                val check = UrlSecurityPolicy.evaluateUrl(targetUrl)

                if (check is PolicyResult.Allowed) {
                    if (
                        isMainFrame &&
                        !UrlSecurityPolicy.isSameOrigin(targetUrl, currentExpectedUrl)
                    ) {
                        currentOnMainFrameNavigationBlocked(
                            targetUrl,
                            "تغییر مقصد سند اصلی به دامنه‌ای خارج از نشست مجاز نیست."
                        )
                        return true
                    }

                    // Third-party HTTPS subframes may use different origins. The session
                    // origin restriction applies only to top-level navigation.
                    return false
                }

                val reason = when (check) {
                    is PolicyResult.Blocked -> check.reason
                    is PolicyResult.Controlled -> check.reason
                    is PolicyResult.Allowed -> ""
                }
                if (isMainFrame) {
                    currentOnMainFrameNavigationBlocked(targetUrl, reason)
                } else {
                    currentOnUrlBlocked(targetUrl, reason)
                }
                return true
            }

            override fun onPageStarted(view: WebView?, pageUrl: String?, favicon: Bitmap?) {
                super.onPageStarted(view, pageUrl, favicon)

                if (pageUrl.equals("about:blank", ignoreCase = true)) {
                    mainFrameNavigationUrl = null
                    return
                }

                // This callback covers top-level POST navigations that are not guaranteed
                // to pass through shouldOverrideUrlLoading.
                if (!UrlSecurityPolicy.isSameOrigin(pageUrl, currentExpectedUrl)) {
                    mainFrameLoadFailed = true
                    cancelPublicChannelReadyCheck()
                    view?.stopLoading()
                    currentOnMainFrameNavigationBlocked(
                        pageUrl.orEmpty(),
                        "مقصد سند اصلی با دامنهٔ مجاز این نشست تطبیق ندارد."
                    )
                    return
                }

                mainFrameNavigationUrl = pageUrl
                pageLoadGeneration += 1
                visualStateRequestedGeneration = -1
                cancelPublicChannelReadyCheck()
                mainFrameLoadFailed = false
                sslErrorReported = false
                currentPageStartedAt = SystemClock.elapsedRealtime()
                contentReadyReported = false
                currentOnPageStarted()
            }

            override fun onPageCommitVisible(view: WebView?, pageUrl: String?) {
                super.onPageCommitVisible(view, pageUrl)
                // Social channel pages may still be an empty JavaScript shell at this point.
                if (UrlSecurityPolicy.publicChannelPlatform(pageUrl) != null) return
                // Wait until the committed frame is ready for the next draw.
                requestVisualState(view, pageUrl)
            }

            override fun onPageFinished(view: WebView?, pageUrl: String?) {
                super.onPageFinished(view, pageUrl)
                if (UrlSecurityPolicy.publicChannelPlatform(pageUrl) != null) {
                    waitForPublicChannelContent(view, pageUrl)
                } else {
                    // Compatibility fallback for implementations that do not dispatch
                    // onPageCommitVisible; visual readiness is still verified.
                    requestVisualState(view, pageUrl)
                }
            }

            override fun onReceivedHttpError(
                view: WebView?,
                request: WebResourceRequest?,
                errorResponse: WebResourceResponse?
            ) {
                super.onReceivedHttpError(view, request, errorResponse)
                if (
                    request?.isForMainFrame == true &&
                    !mainFrameLoadFailed &&
                    (errorResponse?.statusCode ?: 0) >= 400
                ) {
                    mainFrameLoadFailed = true
                    contentReadyReported = false
                    cancelPublicChannelReadyCheck()
                    currentOnErrorOccurred("صفحه مقصد با خطای HTTP " + (errorResponse?.statusCode ?: 0) + " پاسخ داد.")
                }
            }

            override fun onReceivedSslError(
                view: WebView?,
                handler: SslErrorHandler?,
                error: SslError?
            ) {
                // Determine the document scope before cancelling, then mark a main-frame
                // failure before cancel() can enqueue a generic onReceivedError callback.
                val failedUrl = error?.url
                val isMainFrameFailure =
                    UrlSecurityPolicy.isSameDocumentUrl(failedUrl, mainFrameNavigationUrl) ||
                    UrlSecurityPolicy.isSameDocumentUrl(failedUrl, currentExpectedUrl) ||
                    UrlSecurityPolicy.isSameDocumentUrl(failedUrl, view?.url)

                val failedHost = failedUrl?.let { value ->
                    runCatching { Uri.parse(value).host }.getOrNull()
                } ?: "unknown"
                val primaryError = error?.primaryError ?: -1

                if (BuildConfig.DEBUG) {
                    val scope = if (isMainFrameFailure) "main_frame" else "subresource"
                    android.util.Log.w(
                        "SiteBinWebView",
                        "ssl_error scope=$scope host=$failedHost primaryError=$primaryError"
                    )
                }

                val shouldReportMainFrameFailure = isMainFrameFailure && !sslErrorReported
                if (shouldReportMainFrameFailure) {
                    sslErrorReported = true
                    mainFrameLoadFailed = true
                    contentReadyReported = false
                    cancelPublicChannelReadyCheck()
                }

                // Certificate validation is never bypassed, including for a subresource.
                handler?.cancel()

                // A failed image, font, script or iframe is isolated to that request.
                // It must not invalidate an otherwise healthy top-level website.
                if (!shouldReportMainFrameFailure) return
                currentOnSslErrorOccurred("گواهی TLS سند اصلی وب‌سایت معتبر نیست.")
            }

            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: WebResourceError?
            ) {
                super.onReceivedError(view, request, error)
                if (request?.isForMainFrame == true && !mainFrameLoadFailed) {
                    mainFrameLoadFailed = true
                    contentReadyReported = false
                    cancelPublicChannelReadyCheck()
                    currentOnErrorOccurred("خطا در بارگذاری وب‌سایت. ممکن است سرور مقصد در دسترس نباشد.")
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
            webViewRef = null
        }
    }

    // Load new URL only when url prop actually changes
    LaunchedEffect(contentKey, url) {
        if (targetLoadKey != contentKey) {
            targetLoadKey = contentKey
            contentReadyReported = false
            if (rendererTerminated) {
                // Changing the AndroidView key forces factory() to create a new instance.
                rendererTerminated = false
                webViewGeneration += 1
            } else {
                webViewRef?.loadUrl(url)
            }
        }
    }

    key(webViewGeneration) {
        AndroidView(
            modifier = modifier.fillMaxSize(),
            factory = { ctx ->
                WebView(ctx).apply {
                    webViewRef = this

                    // Preserve the provider's default hardware-accelerated rendering.
                    // Do not force a software layer based only on provider version: GPU
                    // regressions are device-specific and software drawing can harm performance.
                    val webViewProviderVersion = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        WebView.getCurrentWebViewPackage()?.versionName ?: "unknown"
                    } else {
                        "system-default"
                    }
                    if (BuildConfig.DEBUG) {
                        android.util.Log.d(
                            "SiteBinWebView",
                            "provider=$webViewProviderVersion renderer=platform_default"
                        )
                    }

                    // Security Hardening & Performance Configurations.
                    settings.apply {
                        javaScriptEnabled = true
                        // Third-party cookies remain at the WebView default (disabled)
                        // until a documented compatibility case justifies a scoped policy.
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

                    webViewClient = safeClient
                    webChromeClient = safeChromeClient

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        val rendererHandler = Handler(Looper.getMainLooper())
                        setWebViewRenderProcessClient(object : WebViewRenderProcessClient() {
                            private var terminationRunnable: Runnable? = null

                            override fun onRenderProcessUnresponsive(
                                view: WebView,
                                renderer: android.webkit.WebViewRenderProcess?
                            ) {
                                terminationRunnable?.let(rendererHandler::removeCallbacks)
                                val pendingTermination = Runnable {
                                    if (webViewRef === view) {
                                        if (BuildConfig.DEBUG) {
                                            android.util.Log.e(
                                                "SiteBinWebView",
                                                "Renderer remained unresponsive for 5s; terminating it."
                                            )
                                        }
                                        renderer?.terminate()
                                    }
                                }
                                terminationRunnable = pendingTermination
                                rendererHandler.postDelayed(pendingTermination, 5_000L)
                            }

                            override fun onRenderProcessResponsive(
                                view: WebView,
                                renderer: android.webkit.WebViewRenderProcess?
                            ) {
                                terminationRunnable?.let(rendererHandler::removeCallbacks)
                                terminationRunnable = null
                                if (BuildConfig.DEBUG) {
                                    android.util.Log.d("SiteBinWebView", "Renderer became responsive again.")
                                }
                            }
                        })
                    }

                    targetLoadKey = contentKey
                    loadUrl(url)
                }
            },
            update = { webView ->
                webViewRef = webView
                // Only load if the requested destination has genuinely changed.
                if (targetLoadKey != contentKey) {
                    targetLoadKey = contentKey
                    contentReadyReported = false
                    webView.loadUrl(url)
                }
            },
            onReset = { webView ->
                webView.stopLoading()
                targetLoadKey = null
                webView.loadUrl("about:blank")
            }
        )
    }
}
