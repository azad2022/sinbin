package com.example.core.security

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.net.http.SslError
import android.os.Build
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

    // Keep track of the currently loaded URL requested by Compose
    // to prevent unwanted re-loads on timer ticks / recompositions
    var targetLoadKey by remember { mutableStateOf<String?>(null) }
    var webViewRef by remember { mutableStateOf<WebView?>(null) }
    var webViewGeneration by remember { mutableStateOf(0) }
    var rendererTerminated by remember { mutableStateOf(false) }
    var currentPageStartedAt by remember { mutableStateOf(0L) }
    var contentReadyReported by remember { mutableStateOf(false) }

    val currentOnPageStarted by rememberUpdatedState(onPageStarted)
    val currentOnPageContentReady by rememberUpdatedState(onPageContentReady)
    val currentOnUrlBlocked by rememberUpdatedState(onUrlBlocked)
    val currentOnErrorOccurred by rememberUpdatedState(onErrorOccurred)

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
                currentOnPageContentReady()
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
                currentPageStartedAt = SystemClock.elapsedRealtime()
                contentReadyReported = false
                currentOnPageStarted()
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
                currentOnErrorOccurred("گواهی امنیتی این وب‌سایت نامعتبر است (SSL Error).")
            }

            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: WebResourceError?
            ) {
                super.onReceivedError(view, request, error)
                if (request?.isForMainFrame == true) {
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
                    currentOnUrlBlocked(downloadUrl, "دانلود مستقیم فایل در سایت بین مجاز نیست.")
                }

                webViewClient = safeClient
                webChromeClient = safeChromeClient

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
