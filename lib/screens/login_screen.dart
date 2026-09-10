import 'dart:async' as async;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/screens/lista_screen.dart';
import 'package:srecord/screens/banco_screen.dart';
import 'package:srecord/screens/programador_screen.dart';
import 'package:srecord/screens/comunicados_screen.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/database_helper.dart';
import 'package:srecord/services/permission_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _passController = TextEditingController();
  final ValueNotifier<bool> _isLoading = ValueNotifier<bool>(false);
  String _appVersion = "";
  async.Timer? _requestCheckTimer;
  bool _isFinalizeDialogOpen = false;

  // Paleta de Colores Soberana (FullEnganche Pro)
  static const Color primaryNavy = Color(0xFF0F172A); // Fondo Profundo
  static const Color accentEmerald = Color(0xFF10B981); // Verde Éxito

  @override
  void initState() {
    super.initState();
    _loadVersion();
    Alex().isUserVerified.value = true; // Asegurar que el login sea siempre visible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkInitialNotificaciones();
      _startRequestChecking();
      PermissionService.requestAllPermissions(context);
    });
  }

  void _startRequestChecking() {
    _checkBankRequestStatus(); // Ejecución inicial
    _requestCheckTimer = async.Timer.periodic(const Duration(seconds: 10), (timer) {
      if (mounted && !_isFinalizeDialogOpen) {
        _checkBankRequestStatus();
      }
    });
  }

  @override
  void dispose() {
    _requestCheckTimer?.cancel();
    _passController.dispose();
    _isLoading.dispose();
    super.dispose();
  }

  Future<void> _loadVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _appVersion = "v${packageInfo.version}+${packageInfo.buildNumber}";
      });
    }
  }

  Future<void> _checkBankRequestStatus() async {
    final res = await Alex().checkBankRequestStatus();
    if (res['status'] == 'APPROVED' && mounted) {
      _showFinalizeDialog(res['request_id']);
    }
  }

  void _showFinalizeDialog(String requestId) {
    final nameController = TextEditingController();
    final passController = TextEditingController();
    final ValueNotifier<bool> dialogLoading = ValueNotifier(false);
    _isFinalizeDialogOpen = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: primaryNavy,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: accentEmerald)),
          title: const Text("SOLICITUD APROBADA", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Tu banco ha sido autorizado. Configura tu identidad ahora:", style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 20),
              TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white),
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  hintText: "NOMBRE DEL BANCO",
                  hintStyle: TextStyle(color: Colors.white24),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white10)),
                ),
              ),
              TextField(
                controller: passController,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: "NUEVO PIN DE ACCESO",
                  hintStyle: TextStyle(color: Colors.white24),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white10)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                _isFinalizeDialogOpen = false;
                Navigator.pop(ctx);
              },
              child: const Text("LUEGO", style: TextStyle(color: Colors.white24)),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: dialogLoading,
              builder: (context, loading, _) => ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: accentEmerald, foregroundColor: Colors.white),
                onPressed: loading ? null : () async {
                  final name = nameController.text.trim();
                  final pass = passController.text.trim();
                  if (name.isEmpty || pass.isEmpty) {
                    _showError("CAMPOS OBLIGATORIOS");
                    return;
                  }

                  dialogLoading.value = true;
                  final res = await Alex().finalizeBankCreation(requestId, pass, name);
                  dialogLoading.value = false;

                  if (res['success'] == true) {
                    _isFinalizeDialogOpen = false;
                    if (ctx.mounted) Navigator.pop(ctx);
                    _showSuccess("BANCO CONFIGURADO. INGRESA CON TU NUEVO PIN.");
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.remove("pending_bank_request_id");
                  } else {
                    _showError(res['error'] ?? "FALLO AL CONFIGURAR");
                  }
                },
                child: loading 
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Text("FINALIZAR"),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkInitialNotificaciones() async {
    final notificaciones = await DatabaseHelper().getNotificaciones();
    final pendientes = notificaciones.where((n) => n['visto'] == 0).toList();

    if (pendientes.isNotEmpty && mounted) {
      final n = pendientes.first;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(n['titulo'], style: const TextStyle(color: primaryNavy, fontWeight: FontWeight.bold)),
          content: Text(n['mensaje']),
          actions: [
            TextButton(
              onPressed: () async {
                await DatabaseHelper().marcarNotificacionVista(n['id']);
                if (context.mounted) Navigator.pop(ctx);
                _checkInitialNotificaciones();
              },
              child: const Text("ENTENDIDO", style: TextStyle(color: accentEmerald, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    }
  }

  void _showResetDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: primaryNavy,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Colors.redAccent)),
        title: const Text("RESET DE IDENTIDAD", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text("¿Deseas desvincular este dispositivo de cualquier banco previo? Esto permitirá un inicio limpio.",
          style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR", style: TextStyle(color: Colors.white24))),
          TextButton(
            onPressed: () async {
              await Alex().logout(fullReset: true);
              if (ctx.mounted) Navigator.pop(ctx);
              _showSuccess("DISPOSITIVO LIBERADO. PUEDES INGRESAR NUEVOS PINS.");
            },
            child: const Text("SÍ, REINICIAR", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))
          ),
        ],
      ),
    );
  }

  void _handleLogin() async {
    final password = _passController.text.trim();
    if (password.isEmpty) return;
    
    _isLoading.value = true;
    final result = await Alex().handleLogin(password);
    _isLoading.value = false;

    if (!mounted) return;

    if (result['success'] == true) {
      if (result['is_request'] == true) {
        _showSuccess(result['message']);
        return;
      }
      
      // Comprobar comunicados ANTES de navegar al panel
      final comunicado = await Alex().getPendingComunicado();
      if (!mounted) return;

      if (comunicado != null) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => ComunicadosScreen(comunicado: comunicado, userRole: result['role']))
        );
      } else {
        _navigateByRole(result['role']);
      }
    } else {
      _showError(result['error'] ?? "Error de acceso");
    }
  }

  void _navigateByRole(String? role) {
    Widget target;
    switch (role) {
      case "PROGRAMADOR": target = const ProgramadorScreen(); break;
      case "BANCO": target = const BancoScreen(); break;
      default: target = const ListaScreen();
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => target));
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      backgroundColor: Colors.redAccent,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  void _showSuccess(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      backgroundColor: accentEmerald,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: primaryNavy,
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.4),
            radius: 1.3,
            colors: [
              const Color(0xFF1E293B), // Slate 800
              primaryNavy,
              const Color(0xFF020617), // Slate 950
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 36),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 1. LOGO CENTRAL CON EFECTO 3D REAL (ESFERA CON BISEL Y SOMBRAS PROFUNDAS)
                  GestureDetector(
                    onLongPress: _showResetDialog,
                    child: Hero(
                      tag: "app_logo",
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Color(0xFF334155), // Bisel Claro Superior
                              Color(0xFF0F172A), // Base Oscura
                            ],
                          ),
                          boxShadow: [
                            // Sombra Profunda 3D Inferior
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.7),
                              offset: const Offset(0, 16),
                              blurRadius: 28,
                              spreadRadius: 2,
                            ),
                            // Luces Reflejadas Superiores
                            BoxShadow(
                              color: Colors.white.withValues(alpha: 0.15),
                              offset: const Offset(-4, -4),
                              blurRadius: 12,
                            ),
                          ],
                          border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 1.5),
                        ),
                        child: ClipOval(
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.5),
                                  blurRadius: 10,
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
                    ),
                  ),
                  const SizedBox(height: 35),
                  
                  // 2. TÍTULO CON EFECTO DE TEXTO ESCULPIDO 3D
                  Text(
                    "S-RECORD",
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: 8,
                      shadows: [
                        // Sombra Proyectada 3D Inferior
                        const Shadow(
                          color: Colors.black87,
                          offset: Offset(0, 6),
                          blurRadius: 10,
                        ),
                        // Resplandor de Elevación
                        Shadow(
                          color: accentEmerald.withValues(alpha: 0.3),
                          offset: const Offset(0, 0),
                          blurRadius: 15,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
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
                      "SISTEMA DE GESTIÓN SOBERANA",
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.white54,
                        letterSpacing: 2,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 50),
                  
                  // 3. CAMPO DE ENTRADA CON EFECTO 3D BAJORRELIEVE (NEUMORFISMO INSET)
                  Container(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFF020617), // Tono Hundido
                          Color(0xFF0F172A),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: const Color(0xFF334155).withValues(alpha: 0.5),
                        width: 1.5,
                      ),
                      boxShadow: [
                        // Sombra de Profundidad Interna Proyectada
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.8),
                          offset: const Offset(0, 8),
                          blurRadius: 16,
                        ),
                        // Borde de Brillo Superior
                        BoxShadow(
                          color: Colors.white.withValues(alpha: 0.05),
                          offset: const Offset(0, -2),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: _passController,
                      obscureText: true,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 28,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 10,
                      ),
                      cursorColor: accentEmerald,
                      decoration: const InputDecoration(
                        hintText: "PIN ACCESO",
                        hintStyle: TextStyle(color: Colors.white24, fontSize: 14, letterSpacing: 3),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 20),
                      ),
                      onSubmitted: (_) => _handleLogin(),
                    ),
                  ),
                  const SizedBox(height: 35),
                  
                  // 4. BOTÓN 3D FÍSICO CON VOLUMEN Y RELEVE (TACTILE 3D BUTTON)
                  ValueListenableBuilder<bool>(
                    valueListenable: _isLoading,
                    builder: (context, loading, _) {
                      return Column(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              gradient: const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Color(0xFF34D399), // Verde Brillante Superior
                                  Color(0xFF059669), // Verde Oscuro Inferior
                                ],
                              ),
                              boxShadow: [
                                // Sombra de Elevación 3D Inferior
                                BoxShadow(
                                  color: accentEmerald.withValues(alpha: 0.4),
                                  offset: const Offset(0, 10),
                                  blurRadius: 20,
                                ),
                                // Bisel Físico 3D Inferior
                                BoxShadow(
                                  color: const Color(0xFF047857),
                                  offset: const Offset(0, 5),
                                  blurRadius: 0,
                                ),
                              ],
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(20),
                                onTap: loading ? null : _handleLogin,
                                child: Container(
                                  width: double.infinity,
                                  height: 62,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.3),
                                      width: 1,
                                    ),
                                  ),
                                  child: loading
                                      ? const SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                                        )
                                      : const Text(
                                          "INGRESAR AL SISTEMA",
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: 1.5,
                                            shadows: [
                                              Shadow(
                                                color: Colors.black38,
                                                offset: Offset(0, 2),
                                                blurRadius: 4,
                                              ),
                                            ],
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 40),
                  
                  // 5. PIE DE PÁGINA EN RELIEVE
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                    ),
                    child: Text(
                      "FullEnganche Pro © 2024${_appVersion.isNotEmpty ? ' • $_appVersion' : ''}",
                      style: const TextStyle(color: Colors.white30, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
