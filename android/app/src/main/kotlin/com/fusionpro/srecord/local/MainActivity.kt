package com.fusionpro.srecord.local

import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.fusionpro.srecord/apk_info"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getApkInfo") {
                val filePath = call.argument<String>("path")
                if (filePath != null) {
                    val info = getApkInfo(filePath)
                    if (info != null) {
                        result.success(info)
                    } else {
                        result.error("UNAVAILABLE", "No se pudo leer la info del APK", null)
                    }
                } else {
                    result.error("INVALID_ARGUMENT", "Ruta de archivo nula", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun getApkInfo(path: String): Map<String, Any>? {
        return try {
            val pm = packageManager
            val info: PackageInfo? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageArchiveInfo(path, PackageManager.PackageInfoFlags.of(0))
            } else {
                pm.getPackageArchiveInfo(path, 0)
            }

            if (info != null) {
                val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    info.longVersionCode
                } else {
                    info.versionCode.toLong()
                }
                mapOf(
                    "versionCode" to versionCode,
                    "versionName" to (info.versionName ?: "0.0.0")
                )
            } else {
                null
            }
        } catch (e: Exception) {
            null
        }
    }
}
