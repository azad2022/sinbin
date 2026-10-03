package com.example.core.security

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.net.http.SslError
import android.os.Build
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
    var targetUrlLoaded by remember { mutableStateOf<String?>(null) }
    var webViewRef: WebView? = remember { null }

    val safeClient = remember {
        object : WebViewClient() {
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
                onPageStarted()
            }

            override fun onPageFinished(view: WebView?, pageUrl: String?) {
                super.onPageFinished(view, pageUrl)
                // Content is rendered and visible
                onPageContentReady()
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
            webViewRef?.stopLoading()
            webViewRef?.loadUrl("about:blank")
            webViewRef?.destroy()
            webViewRef = null
        }
    }

    // Load new URL only when url prop actually changes
    LaunchedEffect(url) {
        if (targetUrlLoaded != url) {
            targetUrlLoaded = url
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

                targetUrlLoaded = url
                loadUrl(url)
            }
        },
        update = { webView ->
            webViewRef = webView
            // Only load if the requested destination has genuinely changed
            if (targetUrlLoaded != url) {
                targetUrlLoaded = url
                webView.loadUrl(url)
            }
        },
        onReset = { webView ->
            webView.stopLoading()
            webView.loadUrl("about:blank")
        }
    )
}
