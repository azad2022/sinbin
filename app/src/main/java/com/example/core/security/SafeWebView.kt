package com.example.core.security

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.net.http.SslError
import android.os.Build
import android.os.CancellationSignal
import android.os.SystemClock
import com.example.BuildConfig
import android.view.ViewGroup
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
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
import androidx.compose.runtime.setValue
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
    speculativeUrl: String? = null,
    modifier: Modifier = Modifier,
    onPageStarted: () -> Unit = {},
    onPageContentReady: () -> Unit = {},
    onUrlBlocked: (String, String) -> Unit = { _, _ -> },
    onErrorOccurred: (String) -> Unit = {}
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    // Keep track of the currently loaded URL requested by Compose
    // to prevent unwanted re-loads on timer ticks / recompositions
    var targetLoadKey by remember { mutableStateOf<String?>(null) }
    var webViewRef: WebView? = remember { null }
    var currentPageStartedAt by remember { mutableStateOf(0L) }
    var contentReadyReported by remember { mutableStateOf(false) }
    var activePrefetchSignal by remember { mutableStateOf<CancellationSignal?>(null) }
    var lastPrefetchedUrl by remember { mutableStateOf<String?>(null) }

    val safeClient = remember {
        object : WebViewClient() {
            private fun reportContentVisible(pageUrl: String?) {
                if (contentReadyReported) return
                if (pageUrl?.startsWith("https://", ignoreCase = true) != true) return

                contentReadyReported = true
                val elapsedMs = if (currentPageStartedAt > 0L) {
                    SystemClock.elapsedRealtime() - currentPageStartedAt
                } else {
                    -1L
                }
                if (BuildConfig.DEBUG) {
                    val host = runCatching {
                        pageUrl.substringAfter("://").substringBefore("/")
                    }.getOrDefault("unknown")
                    android.util.Log.d(
                        "SiteBinPerf",
                        "operation=webview_content_visible host=$host elapsedMs=$elapsedMs"
                    )
                }
                onPageContentReady()
            }

            override fun shouldOverrideUrlLoading(
                view: WebView?,
                request: WebResourceRequest?
            ): Boolean {
                val targetUrl = request?.url?.toString() ?: return true
                val check = UrlSecurityPolicy.evaluateUrl(targetUrl)

                return when (check) {
                    is PolicyResult.Allowed -> {
                        // Allow navigation within the same internal WebView sandbox
                        false
                    }
                    is PolicyResult.Blocked -> {
                        // Block external app escapes (Telegram, Google Play, Market, custom schemes, APKs)
                        onUrlBlocked(targetUrl, check.reason)
                        true
                    }
                    is PolicyResult.Controlled -> {
                        onUrlBlocked(targetUrl, check.reason)
                        true
                    }
                }
            }

            override fun onPageStarted(view: WebView?, pageUrl: String?, favicon: Bitmap?) {
                super.onPageStarted(view, pageUrl, favicon)
                currentPageStartedAt = SystemClock.elapsedRealtime()
                contentReadyReported = false
                onPageStarted()
            }

            override fun onPageCommitVisible(view: WebView?, pageUrl: String?) {
                super.onPageCommitVisible(view, pageUrl)
                // The main frame is visibly committed; do not wait for every subresource.
                reportContentVisible(pageUrl)
            }

            override fun onPageFinished(view: WebView?, pageUrl: String?) {
                super.onPageFinished(view, pageUrl)
                // Compatibility fallback for WebView implementations that do not dispatch
                // onPageCommitVisible reliably.
                reportContentVisible(pageUrl)
            }

            override fun onReceivedSslError(
                view: WebView?,
                handler: SslErrorHandler?,
                error: SslError?
            ) {
                // Strict SSL Enforcement: never proceed with invalid certs
                handler?.cancel()
                onErrorOccurred("گواهی امنیتی این وب‌سایت نامعتبر است (SSL Error).")
            }

            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: WebResourceError?
            ) {
                super.onReceivedError(view, request, error)
                if (request?.isForMainFrame == true) {
                    onErrorOccurred("خطا در بارگذاری وب‌سایت. ممکن است سرور مقصد در دسترس نباشد.")
                }
            }

            override fun onRenderProcessGone(
                view: WebView?,
                detail: RenderProcessGoneDetail?
            ): Boolean {
                view?.let {
                    it.stopLoading()
                    (it.parent as? ViewGroup)?.removeView(it)
                    it.destroy()
                }
                webViewRef = null
                onErrorOccurred("موتور وب‌ویو نیاز به بازیابی دارد. لطفاً دوباره امتحان کنید.")
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
                    activePrefetchSignal?.cancel()
                    activePrefetchSignal = null
                    webViewRef?.stopLoading()
                    webViewRef?.loadUrl("about:blank")
                    webViewRef?.destroy()
                    webViewRef = null
                }
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            activePrefetchSignal?.cancel()
            activePrefetchSignal = null
            webViewRef?.stopLoading()
            webViewRef?.loadUrl("about:blank")
            webViewRef?.destroy()
            webViewRef = null
        }
    }

    // Load new URL only when url prop actually changes
    LaunchedEffect(contentKey, url) {
        if (targetLoadKey != contentKey) {
            targetLoadKey = contentKey
            contentReadyReported = false
            webViewRef?.loadUrl(url)
        }
    }

    AndroidView(
        modifier = modifier.fillMaxSize(),
        factory = { ctx ->
            WebView(ctx).apply {
                webViewRef = this

                // Security Hardening & Performance Configurations
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

                // Anti-Download Policy: block any file download attempt
                setDownloadListener { downloadUrl, _, _, _, _ ->
                    onUrlBlocked(downloadUrl, "دانلود مستقیم فایل در سایت بین مجاز نیست.")
                }

                webViewClient = safeClient
                webChromeClient = safeChromeClient

                targetLoadKey = contentKey

                if (
                    speculativeUrl != null &&
                    speculativeUrl != url &&
                    speculativeUrl != lastPrefetchedUrl
                ) {
                    activePrefetchSignal?.cancel()
                    activePrefetchSignal = SpeculativeWebViewLoader.prefetch(this, speculativeUrl)
                    lastPrefetchedUrl = speculativeUrl
                }

                loadUrl(url)
            }
        },
        update = { webView ->
            webViewRef = webView

            // Level 3: prefetch only the next authoritative session URL. This never
            // navigates the visible WebView and cannot signal content readiness.
            if (
                speculativeUrl != null &&
                speculativeUrl != url &&
                speculativeUrl != lastPrefetchedUrl
            ) {
                activePrefetchSignal?.cancel()
                activePrefetchSignal = SpeculativeWebViewLoader.prefetch(webView, speculativeUrl)
                lastPrefetchedUrl = speculativeUrl
            }

            // Only load if the requested destination has genuinely changed
            if (targetLoadKey != contentKey) {
                targetLoadKey = contentKey
                contentReadyReported = false
                webView.loadUrl(url)
            }
        },
        onReset = { webView ->
            activePrefetchSignal?.cancel()
            activePrefetchSignal = null
            lastPrefetchedUrl = null
            webView.stopLoading()
            targetLoadKey = null
            webView.loadUrl("about:blank")
        }
    )
}
