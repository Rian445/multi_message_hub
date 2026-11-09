package com.multimessenger.hub.multi_message_hub

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import androidx.annotation.NonNull
import androidx.core.content.FileProvider
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewFeature
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL_PROFILE_MANAGER = "com.multimessenger.hub/profile_manager"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Protect screen previews in task switcher and prevent external screen recording
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )

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
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url != null) {
                            try {
                                val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(intent)
                                result.success(true)
                            } catch (e: Exception) {
                                e.printStackTrace()
                                result.success(false)
                            }
                        } else {
                            result.success(false)
                        }
                    }
                    "getAppCacheDir" -> {
                        val externalCache = externalCacheDir
                        val targetPath = if (externalCache != null && externalCache.canWrite()) {
                            externalCache.absolutePath
                        } else {
                            cacheDir.absolutePath
                        }
                        result.success(targetPath)
                    }
                    "installApk" -> {
                        val filePath = call.argument<String>("filePath")
                        if (filePath != null) {
                            try {
                                val file = File(filePath)
                                if (!file.exists()) {
                                    result.error("FILE_NOT_FOUND", "APK file does not exist at $filePath", null)
                                    return@setMethodCallHandler
                                }

                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    if (!packageManager.canRequestPackageInstalls()) {
                                        val manageIntent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                            data = Uri.parse("package:$packageName")
                                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                        }
                                        startActivity(manageIntent)
                                        result.error("PERMISSION_DENIED", "Unknown sources permission required. Please enable it and try again.", null)
                                        return@setMethodCallHandler
                                    }
                                }

                                val contentUri = FileProvider.getUriForFile(
                                    this,
                                    "$packageName.fileprovider",
                                    file
                                )
                                val intent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(contentUri, "application/vnd.android.package-archive")
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }

                                val resolveList = packageManager.queryIntentActivities(intent, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)
                                for (resolveInfo in resolveList) {
                                    grantUriPermission(
                                        resolveInfo.activityInfo.packageName,
                                        contentUri,
                                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                                    )
                                }

                                startActivity(intent)
                                result.success(true)
                            } catch (e: Exception) {
                                e.printStackTrace()
                                result.error("INSTALL_ERROR", e.message, null)
                            }
                        } else {
                            result.error("INVALID_PATH", "File path was null", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
