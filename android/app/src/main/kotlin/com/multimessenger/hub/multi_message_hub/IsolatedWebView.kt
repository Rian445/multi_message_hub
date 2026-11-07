package com.multimessenger.hub.multi_message_hub

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
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

                function findAndClickQr() {
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
                                break;
                            }
                        }
                    } catch (e) {}
                }

                setInterval(findAndClickQr, 1000);
                findAndClickQr();
            })();
        """

        const val REMEMBER_COMPUTER_JS = """
            (function() {
                if (window.__remember_hooked) return;
                window.__remember_hooked = true;

                function checkRememberToggle() {
                    try {
                        // Do not touch Google account login pages
                        if (window.location.hostname.includes("accounts.google.com")) {
                            return;
                        }

                        // Specifically look for the "Remember this computer" slide toggle or checkbox
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
                            }
                        }
                    } catch (err) {}
                }

                setInterval(checkRememberToggle, 2000);
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
            override fun onPermissionRequest(request: android.webkit.PermissionRequest?) {
                // Auto-grant permissions requested by Google Messages (e.g. notifications)
                request?.grant(request.resources)
            }
        }

        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                val uri = request?.url ?: return false
                return handleNavigation(view, uri)
            }

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
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                injectPageScripts()
                channel.invokeMethod("onPageFinished", mapOf("url" to (url ?: "")))
            }
        }
    }

    private fun isAllowedDomain(url: String): Boolean {
        val uri = try {
            Uri.parse(url)
        } catch (e: Exception) {
            return false
        }
        val host = uri.host?.lowercase() ?: return false

        // Allowed domains for Google Messages & Google Account Authentication
        return host == "messages.google.com" ||
               host == "accounts.google.com" ||
               host == "myaccount.google.com" ||
               host.endsWith(".google.com") ||
               host.endsWith(".google") ||
               host.endsWith(".gstatic.com") ||
               host.endsWith(".googleusercontent.com")
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
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun injectEarlyScripts() {
        webView.evaluateJavascript(NOTIFICATION_INSPECTOR_JS, null)
    }

    private fun injectPageScripts() {
        webView.evaluateJavascript(NOTIFICATION_INSPECTOR_JS, null)
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
                webView.reload()
                result.success(null)
            }
            "loadUrl" -> {
                val url = call.argument<String>("url") ?: "https://messages.google.com/web"
                webView.loadUrl(url)
                result.success(null)
            }
            "evaluateJavascript" -> {
                val script = call.argument<String>("script") ?: ""
                webView.evaluateJavascript(script) { value ->
                    result.success(value)
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
