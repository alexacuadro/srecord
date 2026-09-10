import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:srecord/screens/login_screen.dart';
import 'package:srecord/screens/comunicados_screen.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/permission_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ota_update/ota_update.dart';

class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  bool _isCheckingForUpdate = true;
  bool _isUpdateAvailable = false;
  Map<String, dynamic>? _updateData;
  String _downloadStatus = "";
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _checkForUpdate();
    
    // Escuchar el progreso de descarga desde Alex
    Alex().downloadProgress.addListener(_onDownloadProgressChanged);
  }

  @override
  void dispose() {
    Alex().downloadProgress.removeListener(_onDownloadProgressChanged);
    super.dispose();
  }

  void _onDownloadProgressChanged() {
    final event = Alex().downloadProgress.value;
    if (event == null) return;

    if (mounted) {
      setState(() {
        _progress = double.tryParse(event.value ?? "0") ?? 0;
        
        switch (event.status) {
          case OtaStatus.DOWNLOADING:
            _downloadStatus = "Descargando: ${_progress.toStringAsFixed(0)}%";
            break;
          case OtaStatus.INSTALLING:
            _downloadStatus = "Instalando...";
            // Asegurar que el instalador sea visible
            SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
            break;
          case OtaStatus.ALREADY_RUNNING_ERROR:
            _downloadStatus = "Reintentando...";
            break;
          case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
            _downloadStatus = "ERROR: Requiere permiso de instalación.";
            _showManualPermissionDialog();
            break;
          case OtaStatus.INTERNAL_ERROR:
            _downloadStatus = "Error interno al actualizar.";
            break;
          default:
            _downloadStatus = "Preparando actualización...";
        }
      });
    }
  }

  void _showManualPermissionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFF10B981))),
        title: const Text("ACCIÓN REQUERIDA", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text(
          "Tu teléfono bloqueó la instalación automática.\n\n"
          "Para continuar:\n"
          "1. Haz clic en 'ABRIR AJUSTES'.\n"
          "2. Busca 'srecord' en la lista.\n"
          "3. Activa 'Permitir desde esta fuente'.",
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("CANCELAR", style: TextStyle(color: Colors.white24)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(ctx);
              PermissionService.openSettings(); // Abre los ajustes de la app vía wrapper
            },
            child: const Text("ABRIR AJUSTES"),
          ),
        ],
      ),
    );
  }

  Future<void> _checkForUpdate() async {
    setState(() {
      _isCheckingForUpdate = true;
    });

    try {
      await Alex().checkAppUpdate();
      final updateData = Alex().updateRequired.value;
      
      if (mounted) {
        setState(() {
          _updateData = updateData;
          _isUpdateAvailable = updateData != null;
          _isCheckingForUpdate = false;
          if (_isUpdateAvailable) {
            _downloadStatus = "Iniciando descarga automática...";
          }
        });
        
        if (updateData == null) {
          _navigateToLogin();
        }
      }
    } catch (e) {
      debugPrint("Error checking for update: $e");
      if (mounted) {
        setState(() {
          _isCheckingForUpdate = false;
        });
        _navigateToLogin();
      }
    }
  }

  Future<void> _downloadUpdate() async {
    if (_updateData?['url'] == null) return;
    
    setState(() {
      _downloadStatus = "Iniciando descarga...";
    });
    
    await Alex().downloadAndInstallApk(_updateData!['url']);
  }

  Future<void> _navigateToLogin() async {
    debugPrint("[UPDATE_SCREEN] Iniciando transición a Login...");
    
    await Future.delayed(const Duration(seconds: 1));
    
    final comunicado = await Alex().getPendingComunicado();
    
    if (!mounted) return;
    final navigator = Navigator.of(context);

    if (comunicado != null) {
      final prefs = await SharedPreferences.getInstance();
      final role = prefs.getString("user_role") ?? "NONE";
      
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => ComunicadosScreen(comunicado: comunicado, userRole: role)),
      );
    } else {
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isDownloading = _downloadStatus.startsWith("Descargando");
    final bool isInstalling = _downloadStatus == "Instalando...";

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(40.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
              // 3D NEUMORPHIC LOGO SPHERE (PANTALLA DE CARGA)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF334155), // Bisel claro
                      Color(0xFF0F172A), // Base profunda
                    ],
                  ),
                  boxShadow: [
                    // Sombra de Profundidad 3D Proyectada
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.8),
                      offset: const Offset(0, 16),
                      blurRadius: 30,
                      spreadRadius: 2,
                    ),
                    // Resplandor Esmeralda Neón 3D
                    BoxShadow(
                      color: const Color(0xFF10B981).withValues(alpha: 0.35),
                      offset: const Offset(0, 0),
                      blurRadius: 25,
                      spreadRadius: 3,
                    ),
                    // Reflejo Superior Especular
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.2),
                      offset: const Offset(-4, -4),
                      blurRadius: 10,
                    ),
                  ],
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.2),
                    width: 2,
                  ),
                ),
                child: ClipOval(
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.6),
                          blurRadius: 12,
                          spreadRadius: -2,
                        ),
                      ],
                    ),
                    child: Image.asset(
                      "assets/logo.png",
                      height: 130,
                      width: 130,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 35),
              // TÍTULO ESCULPIDO 3D
              Text(
                "S-RECORD",
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  letterSpacing: 8,
                  shadows: [
                    const Shadow(
                      color: Colors.black87,
                      offset: Offset(0, 6),
                      blurRadius: 10,
                    ),
                    Shadow(
                      color: const Color(0xFF10B981).withValues(alpha: 0.4),
                      offset: const Offset(0, 0),
                      blurRadius: 16,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B).withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      offset: const Offset(0, 3),
                      blurRadius: 6,
                    ),
                  ],
                ),
                child: const Text(
                  "GESTIÓN DE ACTUALIZACIONES",
                  style: TextStyle(color: Colors.white60, fontSize: 10, letterSpacing: 2, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 50),
              if (_isCheckingForUpdate) ...[
                // INDICADOR DE CARGA 3D CON CÁPSULA NEUMÓRFICA
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.5), offset: const Offset(0, 8), blurRadius: 16),
                    ],
                  ),
                  child: Column(
                    children: const [
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(color: Color(0xFF10B981), strokeWidth: 3.5),
                      ),
                      SizedBox(height: 16),
                      Text("Buscando mejoras en el sistema...", style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ] else if (_isUpdateAvailable) ...[
                const Icon(Icons.auto_awesome, color: Color(0xFF10B981), size: 60),
                const SizedBox(height: 20),
                Text(
                  isInstalling ? "LISTO PARA INSTALAR" : (isDownloading ? "DESCARGANDO SISTEMA" : "¡NUEVA VERSIÓN v${_updateData?['required']}!"),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 18),
                ),
                const SizedBox(height: 15),
                
                // BLOQUE DE NOTAS DE LANZAMIENTO (MEJORAS)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.stars, color: Colors.amber.shade400, size: 16),
                          const SizedBox(width: 8),
                          const Text("NOVEDADES Y MEJORAS:", style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _updateData?['message'] ?? "Optimizaciones de sistema y mejoras de seguridad.",
                        textAlign: TextAlign.left,
                        style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
                      ),
                      if (isDownloading) ...[
                        const Divider(height: 25, color: Colors.white10),
                        const Row(
                          children: [
                            Icon(Icons.info_outline, color: Colors.blueAccent, size: 14),
                            SizedBox(width: 8),
                            Expanded(child: Text("Descarga automática activa. Por favor, mantén la app abierta.", style: TextStyle(color: Colors.blueAccent, fontSize: 10, fontWeight: FontWeight.bold))),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 30),
                if (isDownloading || isInstalling) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: LinearProgressIndicator(
                      value: isInstalling ? 1.0 : _progress / 100,
                      minHeight: 10,
                      backgroundColor: Colors.white10,
                      color: const Color(0xFF10B981),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(_downloadStatus, style: const TextStyle(color: Color(0xFF10B981), fontSize: 12, fontWeight: FontWeight.bold)),
                ],
                
                if (!isDownloading) ...[
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 55,
                    child: ElevatedButton.icon(
                      onPressed: _downloadUpdate,
                      icon: Icon(isInstalling ? Icons.refresh : Icons.download_for_offline_rounded),
                      label: Text(isInstalling ? "REINTENTAR INSTALACIÓN" : "ACTUALIZAR AHORA", style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        elevation: 5,
                        shadowColor: const Color(0xFF10B981).withValues(alpha: 0.4),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                      ),
                    ),
                  ),
                ],
              ] else ...[
                 const Icon(Icons.check_circle_outline, color: Color(0xFF10B981), size: 60),
                 const SizedBox(height: 20),
                 const Text("SISTEMA ACTUALIZADO", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                 const SizedBox(height: 40),
                 const CircularProgressIndicator(color: Colors.white24),
              ],
            ],
          ),
        ),
      ),
    ),
  );
  }
}
