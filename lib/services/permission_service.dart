import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';

class PermissionService {
  static Future<void> requestAllPermissions(BuildContext context) async {
    if (kIsWeb || !Platform.isAndroid) return; // Bypass en Linux/Web/iOS

    try {
      debugPrint("[ALEX_POWERS] Iniciando ráfaga de permisos locales...");
      
      // Pedimos los permisos básicos sin depender de lógica compleja de versión
      // Android es lo suficientemente inteligente para ignorar los que no aplican
      Map<Permission, PermissionStatus> statuses = await [
        Permission.notification,
        Permission.camera,
        Permission.storage,
        Permission.photos,
        Permission.requestInstallPackages, // Permiso crítico para las actualizaciones
        Permission.ignoreBatteryOptimizations,
      ].request();

      statuses.forEach((p, s) => debugPrint("[ALEX_POWERS] $p: $s"));

      if (statuses[Permission.camera]?.isDenied ?? false) {
        if (context.mounted) {
          _showPermissionDialog(context, "Cámara Requerida", "Activa la cámara para poder escanear jugadas.");
        }
      }
    } catch (e) {
      debugPrint("[ALEX_POWERS] Error en ráfaga: $e");
    }
  }

  /// Solicita acceso a cámara y galería para el sistema OCR
  static Future<bool> ensureCameraAndGalleryPermissions(BuildContext context) async {
    PermissionStatus cameraStatus = await Permission.camera.request();
    PermissionStatus storageStatus;

    // En Android 13+ (SDK 33) se usa READ_MEDIA_IMAGES
    if (await Permission.photos.isGranted || await Permission.photos.request().isGranted) {
      storageStatus = PermissionStatus.granted;
    } else {
      storageStatus = await Permission.storage.request();
    }

    if (cameraStatus.isGranted && storageStatus.isGranted) {
      return true;
    }

    if (context.mounted) {
      _showPermissionDialog(
        context,
        "Acceso a Cámara y Galería",
        "Para escanear jugadas por imagen, S-RECORD necesita acceder a tu cámara y a tu galería de fotos."
      );
    }
    return false;
  }

  static void _showPermissionDialog(BuildContext context, String title, String msg) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF475569),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(msg, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              openAppSettings(); // Abre los ajustes de la app para que el usuario los active manualmente
            },
            child: const Text("IR A AJUSTES", style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  /// Expone openAppSettings de forma estática para evitar problemas de scope en pantallas
  static Future<bool> openSettings() async {
    return await openAppSettings();
  }
}
