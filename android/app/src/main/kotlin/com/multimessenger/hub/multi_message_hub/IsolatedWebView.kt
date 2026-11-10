package com.multimessenger.hub.multi_message_hub

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
import android.os.Build
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView

class IsolatedWebView(
    private val context: Context,
    private val id: Int,
    private val creationParams: Map<String, Any?>?,
    private val messenger: BinaryMessenger
) : PlatformView, MethodChannel.MethodCallHandler {

    private val webView: WebView = WebView(context)
    private val channel: MethodChannel
    private val profileUuid: String = creationParams?.get("uuid") as? String ?: "default"
    private val initialUrl: String = creationParams?.get("url") as? String ?: "https://messages.google.com/web"
    private var isMobileMode: Boolean = creationParams?.get("mobileMode") as? Boolean ?: true

    private val defaultSystemUa: String by lazy {
        webView.settings.userAgentString
    }

    private val cleanMobileUa: String by lazy {
        defaultSystemUa.replace("; wv", "").replace(Regex("Version/\\d+\\.\\d+\\s?"), "")
    }

    private val cleanDesktopUa: String by lazy {
        cleanMobileUa.replace("Mobile ", "")
    }

    companion object {
        const val JS_BRIDGE_NAME = "FlutterNotifBridge"

        const val NOTIFICATION_INSPECTOR_JS = """
            (function() {
                try {
                    window.open = function(url) {
                        if (url) {
                            window.location.href = url;
                        }
                        return window;
                    };
                    Object.defineProperty(navigator, 'webdriver', { get: () => false });
                    if (!window.chrome) {
                        window.chrome = { runtime: {} };
                    }
                } catch (e) {}

                if (window.__flutter_notif_hooked) return;
                window.__flutter_notif_hooked = true;

                class FlutterNotification {
                    constructor(title, options) {
                        this.title = title || "Unknown";
                        this.options = options || {};
                        try {
                            if (window.FlutterNotifBridge && window.FlutterNotifBridge.postMessage) {
                                window.FlutterNotifBridge.postMessage(JSON.stringify({
                                    sender: this.title,
                                    body: (this.options && this.options.body) ? this.options.body : "New message",
                                    timestamp: Date.now()
                                }));
                            }
                        } catch (e) {
                            console.error("FlutterNotifBridge error:", e);
                        }
                    }
                    static requestPermission(cb) {
                        if (cb) cb("granted");
                        return Promise.resolve("granted");
                    }
                    static get permission() {
                        return "granted";
                    }
                    close() {}
                    addEventListener() {}
                    removeEventListener() {}
                    dispatchEvent() { return false; }
                }
                FlutterNotification.permission = "granted";
                window.Notification = FlutterNotification;
            })();
        """

        const val AUTO_QR_SWITCH_JS = """
            (function() {
                if (window.__auto_qr_hooked) return;
                window.__auto_qr_hooked = true;
                let attempts = 0;

                function findAndClickQr() {
                    attempts++;
                    try {
                        const candidates = document.querySelectorAll("button, a, [role='button'], span");
                        for (let el of candidates) {
                            const txt = (el.innerText || el.textContent || "").toLowerCase().trim();
                            if (txt === "switch to qr pairing" || 
                                txt === "switch to qr code pairing" ||
                                txt === "pair with qr code" || 
                                txt === "use qr code" || 
                                txt === "qr code pairing") {
                                const target = el.closest("button, a, [role='button']") || el;
                                target.click();
                                if (window.__qrInterval) clearInterval(window.__qrInterval);
                                return;
                            }
                        }
                    } catch (e) {}

                    if (attempts >= 10 && window.__qrInterval) {
                        clearInterval(window.__qrInterval);
                    }
                }

                window.__qrInterval = setInterval(findAndClickQr, 1000);
                findAndClickQr();
            })();
        """

        const val REMEMBER_COMPUTER_JS = """
            (function() {
                if (window.__remember_hooked) return;
                window.__remember_hooked = true;
                let attempts = 0;

                function checkRememberToggle() {
                    attempts++;
                    try {
                        if (window.location.hostname.includes("accounts.google.com")) {
                            if (window.__remInterval) clearInterval(window.__remInterval);
                            return;
                        }

                        const toggles = document.querySelectorAll("mat-slide-toggle, [role='switch'], input[type='checkbox']");
                        for (let el of toggles) {
                            const ariaLabel = (el.getAttribute("aria-label") || "").toLowerCase();
                            const innerTxt = (el.innerText || el.textContent || "").toLowerCase();
                            const formControl = el.getAttribute("formcontrolname") || "";
                            
                            if (ariaLabel.includes("remember") || 
                                innerTxt.includes("remember this computer") || 
                                formControl === "rememberComputer") {
                                const isChecked = el.classList.contains("mat-checked") ||
                                                  el.getAttribute("aria-checked") === "true" ||
                                                  el.checked === true;
                                if (!isChecked) {
                                    el.click();
                                }
                                if (window.__remInterval) clearInterval(window.__remInterval);
                                return;
                            }
                        }
                    } catch (err) {}

                    if (attempts >= 12 && window.__remInterval) {
                        clearInterval(window.__remInterval);
                    }
                }

                window.__remInterval = setInterval(checkRememberToggle, 1500);
                checkRememberToggle();
            })();
        """

        const val MOBILE_VIEW_CSS = """
            (function() {
                const styleId = "flutter-mobile-viewport-style";
                let style = document.getElementById(styleId);
                if (!style) {
                    style = document.createElement("style");
                    style.id = styleId;
                    style.innerHTML = `
                        @media screen and (max-width: 1000px) {
                            mw-main-nav { display: none !important; }
                            mw-main-container { width: 100vw !important; min-width: 100vw !important; }
                            .conversation-list-container, mw-conversation-list {
                                width: 100vw !important;
                                max-width: 100vw !important;
                                min-width: 100vw !important;
                            }
                            mw-conversation-container {
                                width: 100vw !important;
                                max-width: 100vw !important;
                            }
                        }
                    `;
                    document.head.appendChild(style);
                }
                let meta = document.querySelector("meta[name='viewport']");
                if (!meta) {
                    meta = document.createElement("meta");
                    meta.name = "viewport";
                    document.head.appendChild(meta);
                }
                meta.content = "width=device-width, initial-scale=1.0, maximum-scale=3.0, user-scalable=yes";
            })();
        """

        const val REMOVE_MOBILE_VIEW_CSS = """
            (function() {
                const style = document.getElementById("flutter-mobile-viewport-style");
                if (style) {
                    style.remove();
                }
                let meta = document.querySelector("meta[name='viewport']");
                if (meta) {
                    meta.content = "width=1280, initial-scale=0.75, user-scalable=yes";
                }
            })();
        """

        const val CONNECTIVITY_MONITOR_JS = """
            (function() {
                if (window.__conn_monitor_hooked) return;
                window.__conn_monitor_hooked = true;

                function notifyStatus(online, reason) {
                    try {
                        if (window.FlutterNotifBridge && window.FlutterNotifBridge.onConnectionStatus) {
                            window.FlutterNotifBridge.onConnectionStatus(online, reason || "");
                        }
                    } catch(e) {}
                }

                window.addEventListener("offline", function() {
                    notifyStatus(false, "Device is offline");
                });

                window.addEventListener("online", function() {
                    notifyStatus(true, "Device is online");
                });

                if (navigator.onLine === false) {
                    notifyStatus(false, "Device is offline");
                }
            })();
        """
    }

    init {
        channel = MethodChannel(messenger, "com.multimessenger.hub/webview_$id")
        channel.setMethodCallHandler(this)

        setupIsolationProfile()
        setupWebViewSettings()
        setupJavaScriptBridge()

        webView.loadUrl(initialUrl)
    }

    private fun setupIsolationProfile() {
        if (profileUuid.isNotEmpty() && profileUuid != "default") {
            try {
                if (WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
                    val profileStore = ProfileStore.getInstance()
                    profileStore.getOrCreateProfile(profileUuid)
                    WebViewCompat.setProfile(webView, profileUuid)
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun setupWebViewSettings() {
        val settings = webView.settings
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.databaseEnabled = true
        settings.cacheMode = WebSettings.LOAD_DEFAULT
        settings.setSupportZoom(true)
        settings.builtInZoomControls = true
        settings.displayZoomControls = false
        settings.loadWithOverviewMode = true
        settings.useWideViewPort = true
        // Strict security sandboxing
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        settings.allowFileAccessFromFileURLs = false
        settings.allowUniversalAccessFromFileURLs = false
        settings.mediaPlaybackRequiresUserGesture = false
        settings.javaScriptCanOpenWindowsAutomatically = true
        settings.setSupportMultipleWindows(false)

        // Enable cookies and third-party cookies for Google Account login across domains
        val cookieManager = android.webkit.CookieManager.getInstance()
        cookieManager.setAcceptCookie(true)
        cookieManager.setAcceptThirdPartyCookies(webView, true)

        // Strip X-Requested-With header to prevent Google from detecting Android WebView
        try {
            if (WebViewFeature.isFeatureSupported(WebViewFeature.REQUESTED_WITH_HEADER_ALLOW_LIST)) {
                androidx.webkit.WebSettingsCompat.setRequestedWithHeaderOriginAllowList(settings, emptySet())
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }

        // Start with clean desktop User-Agent
        settings.userAgentString = cleanDesktopUa

        // Keep active timers
        webView.onResume()
        webView.resumeTimers()

        webView.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest?) {
                if (request == null) return
                // Whitelist only safe resources: audio capture for voice messages
                // Deny video capture, midi, and protected media id
                val requested = request.resources
                val granted = mutableListOf<String>()
                for (res in requested) {
                    if (res == PermissionRequest.RESOURCE_AUDIO_CAPTURE) {
                        granted.add(res)
                    }
                }
                if (granted.isNotEmpty()) {
                    request.grant(granted.toTypedArray())
                } else {
                    request.deny()
                }
            }
        }

        webView.webViewClient = object : WebViewClient() {
            override fun onReceivedSslError(view: WebView?, handler: SslErrorHandler?, error: SslError?) {
                // Strictly deny SSL/TLS errors to protect against MITM attacks
                handler?.cancel()
                channel.invokeMethod("onReceivedError", mapOf(
                    "errorCode" to -1,
                    "description" to "SSL Security Error",
                    "failingUrl" to (error?.url ?: "")
                ))
            }

            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                val uri = request?.url ?: return false
                return handleNavigation(view, uri)
            }

            @Suppress("DEPRECATION")
            @Deprecated("Deprecated in Java")
            override fun shouldOverrideUrlLoading(view: WebView?, url: String?): Boolean {
                if (url == null) return false
                val uri = try { Uri.parse(url) } catch (e: Exception) { return false }
                return handleNavigation(view, uri)
            }

            override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                super.onPageStarted(view, url, favicon)
                if (url != null) {
                    updateUserAgentForUrl(url)
                }
                injectEarlyScripts()
                channel.invokeMethod("onPageStarted", mapOf("url" to (url ?: "")))
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                injectPageScripts()
                channel.invokeMethod("onPageFinished", mapOf("url" to (url ?: "")))
            }

            override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                super.onReceivedError(view, request, error)
                if (request?.isForMainFrame == true) {
                    val errorCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        error?.errorCode ?: -1
                    } else {
                        -1
                    }
                    val description = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        error?.description?.toString() ?: "Connection failed"
                    } else {
                        "Connection failed"
                    }
                    channel.invokeMethod("onReceivedError", mapOf(
                        "errorCode" to errorCode,
                        "description" to description,
                        "failingUrl" to (request.url?.toString() ?: "")
                    ))
                }
            }

            @Suppress("DEPRECATION")
            @Deprecated("Deprecated in Java")
            override fun onReceivedError(view: WebView?, errorCode: Int, description: String?, failingUrl: String?) {
                super.onReceivedError(view, errorCode, description, failingUrl)
                channel.invokeMethod("onReceivedError", mapOf(
                    "errorCode" to errorCode,
                    "description" to (description ?: "Connection failed"),
                    "failingUrl" to (failingUrl ?: "")
                ))
            }

            override fun onReceivedHttpError(view: WebView?, request: WebResourceRequest?, errorResponse: WebResourceResponse?) {
                super.onReceivedHttpError(view, request, errorResponse)
                if (request?.isForMainFrame == true) {
                    val statusCode = errorResponse?.statusCode ?: 200
                    if (statusCode >= 400) {
                        channel.invokeMethod("onReceivedError", mapOf(
                            "errorCode" to statusCode,
                            "description" to "Server error ($statusCode)",
                            "failingUrl" to (request.url?.toString() ?: "")
                        ))
                    }
                }
            }
        }
    }

    private fun isAllowedDomain(url: String): Boolean {
        val uri = try {
            Uri.parse(url)
        } catch (e: Exception) {
            return false
        }
        val scheme = uri.scheme?.lowercase() ?: return false
        if (scheme != "https") {
            return false // Strictly require HTTPS (block http:, file:, javascript:, content:)
        }
        val host = uri.host?.lowercase() ?: return false

        // Disallow domains that host arbitrary user-created files/content
        if (host.endsWith(".googleusercontent.com") ||
            host == "sites.google.com" ||
            host == "docs.google.com" ||
            host == "drive.google.com" ||
            host == "forms.google.com" ||
            host == "script.google.com") {
            return false
        }

        // Allowed domains for Google Messages & Google Account Authentication
        return host == "messages.google.com" ||
               host == "accounts.google.com" ||
               host == "myaccount.google.com" ||
               host == "apis.google.com" ||
               host == "ssl.gstatic.com" ||
               host == "www.gstatic.com" ||
               (host.endsWith(".google.com") && !host.contains("usercontent"))
    }

    private fun handleNavigation(view: WebView?, uri: Uri): Boolean {
        val url = uri.toString()
        if (isAllowedDomain(url)) {
            updateUserAgentForUrl(url)
            view?.loadUrl(url)
            return true
        } else {
            // External link: open safely in external system browser, NEVER inside isolated WebView
            try {
                val intent = Intent(Intent.ACTION_VIEW, uri)
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
            } catch (e: Exception) {
                e.printStackTrace()
            }
            return true // Navigation handled externally; isolated WebView is protected
        }
    }

    private fun updateUserAgentForUrl(url: String) {
        if (url.contains("accounts.google.com")) {
            if (webView.settings.userAgentString != cleanMobileUa) {
                webView.settings.userAgentString = cleanMobileUa
            }
        } else {
            if (webView.settings.userAgentString != cleanDesktopUa) {
                webView.settings.userAgentString = cleanDesktopUa
            }
        }
    }

    private fun setupJavaScriptBridge() {
        class Bridge {
            @JavascriptInterface
            fun postMessage(jsonString: String) {
                // Post to main Flutter thread via MethodChannel
                webView.post {
                    channel.invokeMethod("onNotificationReceived", mapOf(
                        "uuid" to profileUuid,
                        "payload" to jsonString
                    ))
                }
            }

            @JavascriptInterface
            fun onConnectionStatus(isOnline: Boolean, reason: String) {
                webView.post {
                    channel.invokeMethod("onConnectionStatus", mapOf(
                        "isOnline" to isOnline,
                        "reason" to reason
                    ))
                }
            }
        }

        webView.addJavascriptInterface(Bridge(), JS_BRIDGE_NAME)

        // If Document Start Script is supported by androidx.webkit, inject it early
        try {
            if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                WebViewCompat.addDocumentStartJavaScript(
                    webView,
                    NOTIFICATION_INSPECTOR_JS,
                    setOf("https://messages.google.com")
                )
                WebViewCompat.addDocumentStartJavaScript(
                    webView,
                    CONNECTIVITY_MONITOR_JS,
                    setOf("https://messages.google.com")
                )
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun injectEarlyScripts() {
        webView.evaluateJavascript(NOTIFICATION_INSPECTOR_JS, null)
        webView.evaluateJavascript(CONNECTIVITY_MONITOR_JS, null)
    }

    private fun injectPageScripts() {
        webView.evaluateJavascript(NOTIFICATION_INSPECTOR_JS, null)
        webView.evaluateJavascript(CONNECTIVITY_MONITOR_JS, null)
        webView.evaluateJavascript(REMEMBER_COMPUTER_JS, null)
        webView.evaluateJavascript(AUTO_QR_SWITCH_JS, null)
        if (isMobileMode) {
            webView.evaluateJavascript(MOBILE_VIEW_CSS, null)
        }
    }

    override fun getView(): View {
        return webView
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "reload" -> {
                val currentUrl = webView.url
                if (currentUrl.isNullOrEmpty() || currentUrl.startsWith("data:") || currentUrl == "about:blank") {
                    webView.loadUrl(initialUrl)
                } else {
                    webView.reload()
                }
                result.success(null)
            }
            "loadUrl" -> {
                val url = call.argument<String>("url") ?: "https://messages.google.com/web"
                if (isAllowedDomain(url)) {
                    webView.loadUrl(url)
                    result.success(null)
                } else {
                    result.error("BLOCKED_URL", "Navigation to unauthorized domain blocked: $url", null)
                }
            }
            "setMobileMode" -> {
                val enable = call.argument<Boolean>("enable") ?: true
                isMobileMode = enable
                if (enable) {
                    webView.evaluateJavascript(MOBILE_VIEW_CSS, null)
                } else {
                    webView.evaluateJavascript(REMOVE_MOBILE_VIEW_CSS, null)
                }
                result.success(null)
            }
            "zoomIn" -> {
                webView.zoomIn()
                result.success(null)
            }
            "zoomOut" -> {
                webView.zoomOut()
                result.success(null)
            }
            "resume" -> {
                webView.onResume()
                webView.resumeTimers()
                result.success(null)
            }
            "pause" -> {
                // We keep timers running as per PRD for background WebSockets
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun dispose() {
        channel.setMethodCallHandler(null)
        webView.stopLoading()
        webView.destroy()
    }
}
