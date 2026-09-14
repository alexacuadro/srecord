package com.fusionpro.srecord.local

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.fusionpro.srecord/apk_info"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getApkInfo" -> {
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
                }
                "installApk" -> {
                    val filePath = call.argument<String>("path")
                    if (filePath != null) {
                        val success = installApk(filePath)
                        if (success) {
                            result.success(true)
                        } else {
                            result.error("INSTALL_FAILED", "No se pudo lanzar el instalador nativo", null)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "Ruta de archivo nula", null)
                    }
                }
                "openPlayProtectSettings" -> {
                    openPlayProtectSettings()
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun openPlayProtectSettings() {
        try {
            val intent = Intent("com.google.android.gms.play.protect.ACTION_PLAY_PROTECT_SETTINGS")
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (e: Exception) {
            try {
                val intent = Intent(Settings.ACTION_SECURITY_SETTINGS)
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
            } catch (e2: Exception) {
                // Fallback
            }
        }
    }

    private fun getApkInfo(path: String): Map<String, Any>? {
        return try {
            val pm = packageManager
            val flags = PackageManager.GET_META_DATA
            val info: PackageInfo? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageArchiveInfo(path, PackageManager.PackageInfoFlags.of(flags.toLong()))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageArchiveInfo(path, flags)
            }

            if (info != null) {
                val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    info.longVersionCode
                } else {
                    info.versionCode.toLong()
                }
                mapOf(
                    "versionCode" to versionCode,
                    "versionName" to (info.versionName ?: "0.0.0"),
                    "packageName" to (info.packageName ?: "")
                )
            } else {
                null
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun installApk(filePath: String): Boolean {
        return try {
            val file = File(filePath)
            if (!file.exists()) return false

            val intent = Intent(Intent.ACTION_VIEW)
            val uri: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                FileProvider.getUriForFile(
                    context,
                    "${context.packageName}.ota_update_provider",
                    file
                )
            } else {
                Uri.fromFile(file)
            }

            intent.setDataAndType(uri, "application/vnd.android.package-archive")
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }
}
