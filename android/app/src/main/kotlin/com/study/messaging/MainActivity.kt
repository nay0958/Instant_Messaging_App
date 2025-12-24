package com.study.messaging

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.study.messaging/battery_optimization"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestBatteryOptimizationExemption" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val powerManager = getSystemService(POWER_SERVICE) as PowerManager
                            val packageName = packageName
                            
                            if (!powerManager.isIgnoringBatteryOptimizations(packageName)) {
                                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                    data = Uri.parse("package:$packageName")
                                }
                                startActivity(intent)
                                result.success(true)
                            } else {
                                result.success(true) // Already granted
                            }
                        } else {
                            result.success(true) // Not needed on older Android versions
                        }
                    } catch (e: Exception) {
                        result.error("ERROR", "Failed to request battery optimization exemption: ${e.message}", null)
                    }
                }
                "hasBatteryOptimizationExemption" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val powerManager = getSystemService(POWER_SERVICE) as PowerManager
                            val packageName = packageName
                            val isIgnoring = powerManager.isIgnoringBatteryOptimizations(packageName)
                            result.success(isIgnoring)
                        } else {
                            result.success(true) // Not needed on older Android versions
                        }
                    } catch (e: Exception) {
                        result.error("ERROR", "Failed to check battery optimization exemption: ${e.message}", null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
}
