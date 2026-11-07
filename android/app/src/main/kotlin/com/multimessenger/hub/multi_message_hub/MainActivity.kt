package com.multimessenger.hub.multi_message_hub

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.annotation.NonNull
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewFeature
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL_PROFILE_MANAGER = "com.multimessenger.hub/profile_manager"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register custom PlatformView factory for Isolated WebView
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "isolated_web_view",
            IsolatedWebViewFactory(flutterEngine.dartExecutor.binaryMessenger)
        )

        // MethodChannel for managing isolated multi-profiles and system optimizations
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_PROFILE_MANAGER)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isMultiProfileSupported" -> {
                        val supported = WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)
                        result.success(supported)
                    }
                    "deleteProfile" -> {
                        val profileUuid = call.argument<String>("uuid")
                        if (profileUuid != null && WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
                            try {
                                val profileStore = ProfileStore.getInstance()
                                val deleted = profileStore.deleteProfile(profileUuid)
                                result.success(deleted)
                            } catch (e: Exception) {
                                e.printStackTrace()
                                result.error("DELETE_FAILED", e.message, null)
                            }
                        } else {
                            result.success(false)
                        }
                    }
                    "getAllProfiles" -> {
                        if (WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
                            try {
                                val profileStore = ProfileStore.getInstance()
                                val profiles = profileStore.allProfileNames
                                result.success(profiles.toList())
                            } catch (e: Exception) {
                                result.error("GET_PROFILES_FAILED", e.message, null)
                            }
                        } else {
                            result.success(emptyList<String>())
                        }
                    }
                    "isBatteryOptimizationIgnored" -> {
                        val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
                        val isIgnoring = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && powerManager != null) {
                            powerManager.isIgnoringBatteryOptimizations(packageName)
                        } else {
                            true
                        }
                        result.success(isIgnoring)
                    }
                    "requestIgnoreBatteryOptimization" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
                            if (powerManager != null && !powerManager.isIgnoringBatteryOptimizations(packageName)) {
                                try {
                                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                        data = Uri.parse("package:$packageName")
                                    }
                                    startActivity(intent)
                                } catch (e: Exception) {
                                    // Fallback to battery saver settings if direct request fails
                                    val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                                    startActivity(intent)
                                }
                            }
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
