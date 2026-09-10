import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:srecord/screens/login_screen.dart';
import 'package:srecord/screens/update_screen.dart';
import 'package:srecord/services/background_service.dart';
import 'package:srecord/services/core_network.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/notification_service.dart';
import 'package:srecord/services/sovereign_shield.dart';
import 'package:srecord/services/responsive_ui_service.dart';
import 'package:ota_update/ota_update.dart';

void main() async {
  // Protocolo de Protección FullEnganche Pro: Inicialización de Núcleo Crítico
  WidgetsFlutterBinding.ensureInitialized();
  
  // Forzar Pantalla Completa
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // Inicializar Supabase ANTES de lanzar la UI para evitar colapsos de Alex
  try {
    await Supabase.initialize(
      url: 'https://vonuhrbjchufqzqygqgt.supabase.co',
      publishableKey: SovereignShield.getMasterKey(),
    );
  } catch (e) {
    debugPrint("[S-RECORD] Fallo de núcleo Supabase: $e");
  }
  
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  MyApp.navigatorKey = navigatorKey;

  runApp(MyApp(navigatorKeyInstance: navigatorKey));

  // Inicialización de servicios secundarios en segundo plano
  _initializeSystem(navigatorKey);
}

Future<void> _initializeSystem(GlobalKey<NavigatorState> navigatorKey) async {
  runZonedGuarded(() async {
    // 2. Levantar el Túnel Previo
    final coreNetwork = CoreNetwork();
    await coreNetwork.initializeTunnel();
    coreNetwork.secureWebSocketConnection();

    // 5. Inicializar Cerebro Alex y Notificaciones
    Alex();
    await NotificationService().init();

    // 7. Servicios de fondo
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      Future.delayed(const Duration(seconds: 2), () => BackgroundService.initializeService());
    }
    
  }, (error, stack) {
    debugPrint("[S-RECORD ERROR CRÍTICO] $error");
  });
}

class MyApp extends StatelessWidget {
  static late GlobalKey<NavigatorState> navigatorKey;
  final GlobalKey<NavigatorState> navigatorKeyInstance;
  const MyApp({super.key, required this.navigatorKeyInstance});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKeyInstance,
      title: 'S-RECORD',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A237E), 
          primary: const Color(0xFF1A237E),
          secondary: const Color(0xFF00B0FF), 
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: const Color(0xFFE3F2FD),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1A237E),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        useMaterial3: true,
      ),
      builder: (context, child) {
        return ConnectivityFrame(child: child ?? const SizedBox.shrink());
      },
      home: const UpdateScreen(),
    );
  }
}

class ConnectivityFrame extends StatefulWidget {
  final Widget child;
  const ConnectivityFrame({super.key, required this.child});

  @override
  State<ConnectivityFrame> createState() => _ConnectivityFrameState();
}

class _ConnectivityFrameState extends State<ConnectivityFrame> with SingleTickerProviderStateMixin {
  bool _isOnline = CoreNetwork().isConnected;
  bool _isVerified = Alex().isUserVerified.value;
  Map<String, dynamic>? _updateData = Alex().updateRequired.value;
  String? _violationMessage;
  String _downloadStatus = "";
  double _progress = 0;
  late StreamSubscription<bool> _subscription;
  late StreamSubscription<String> _securitySubscription;
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    
    // Re-asegurar pantalla completa al iniciar el marco
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _isOnline ? 2000 : 500),
    )..repeat(reverse: true);
    
    _animation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    _subscription = CoreNetwork().onConnectionChanged.listen((online) {
      if (mounted) {
        setState(() { 
          _isOnline = online; 
          _controller.duration = Duration(milliseconds: _isOnline ? 2000 : 500);
          _controller.repeat(reverse: true);
        });
        if (online) Alex().checkAppUpdate();
      }
    });

    Alex().isUserVerified.addListener(_onVerificationChanged);
    Alex().updateRequired.addListener(_onUpdateChanged);

    // Verificación inicial de actualización al arrancar
    if (_isOnline) Alex().checkAppUpdate();

    Alex().downloadProgress.addListener(_onDownloadProgressChanged);

    _securitySubscription = Alex().onSecurityViolation.listen((message) {
      if (mounted) {
        setState(() { _violationMessage = message; });
      }
    });
  }

  void _onVerificationChanged() {
    if (mounted) setState(() { _isVerified = Alex().isUserVerified.value; });
  }

  void _onUpdateChanged() {
    if (mounted) {
      final newData = Alex().updateRequired.value;
      setState(() { _updateData = newData; });
      
      // AUTO-DISPARO INMEDIATO: Si hay actualización, descargar ya.
      if (newData != null && _downloadStatus.isEmpty) {
        final url = newData['url'];
        if (url != null && url.isNotEmpty) {
          debugPrint("[S-RECORD] Iniciando descarga forzosa de actualización...");
          Alex().downloadAndInstallApk(url);
        }
      }
    }
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
            break;
          case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
            _downloadStatus = "Error: Permiso denegado.";
            _showPermissionDialog();
            break;
          case OtaStatus.INTERNAL_ERROR:
            _downloadStatus = "Reintentando por conexión inestable...";
            break;
          case OtaStatus.DOWNLOAD_ERROR:
            _downloadStatus = "Fallo de red. Reintentando...";
            break;
          case OtaStatus.ALREADY_RUNNING_ERROR:
            _downloadStatus = "Descarga en curso...";
            break;
          default:
            _downloadStatus = "";
        }
      });
    }
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text("PERMISO REQUERIDO", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text(
          "Para instalar la actualización, debes permitir que S-RECORD instale aplicaciones.\n\n"
          "1. Ve a Ajustes.\n2. Activa 'Permitir desde esta fuente'.",
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CERRAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.greenAccent.shade700),
            onPressed: () {
              Navigator.pop(ctx);
              Alex().openSettings(); // Wrapper para abrir ajustes
            },
            child: const Text("ABRIR AJUSTES", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _subscription.cancel();
    _securitySubscription.cancel();
    Alex().isUserVerified.removeListener(_onVerificationChanged);
    Alex().updateRequired.removeListener(_onUpdateChanged);
    Alex().downloadProgress.removeListener(_onDownloadProgressChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        ResponsiveUiService().scanDeviceScreen(context);
        final baseColor = _isOnline ? Colors.green.shade800 : Colors.red.shade900;
        final frameColor = baseColor.withValues(alpha: _animation.value);
        
        // Prioridad: Actualización > Seguridad
        final bool showUpdateMask = _updateData != null;
        final bool showSecurityMask = _isOnline && !_isVerified && !showUpdateMask;
        
        // Si hay una violación, el login debe ser accesible
        final bool isViolation = _violationMessage != null;

        return Container(
          color: frameColor,
          child: SafeArea(
            top: false,
            bottom: false,
            child: Column(
              children: [
                // Barra Superior de Estado
                Container(
                  height: 20,
                  width: double.infinity,
                  color: frameColor,
                  child: Center(
                    child: Material(
                      color: Colors.transparent,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _isOnline ? Icons.wifi : Icons.signal_wifi_off, 
                            color: Colors.white70, 
                            size: 10
                          ),
                          const SizedBox(width: 6),
                          Text(
                            showUpdateMask 
                                ? "ACTUALIZACIÓN REQUERIDA"
                                : (showSecurityMask 
                                    ? "VALIDANDO SEGURIDAD..." 
                                    : (_isOnline ? "SISTEMA CONECTADO" : "SISTEMA OFFLINE - MODO LOCAL")),
                            style: const TextStyle(
                              color: Colors.white, 
                              fontSize: 8, 
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.1
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // El contenido de la App con bordes laterales e inferior
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(8),
                          bottomRight: Radius.circular(8),
                        ),
                      ),
                      child: Stack(
                        children: [
                          widget.child,
                          if (showUpdateMask)
                            _buildUpdateMask(),
                          if (showSecurityMask && !showUpdateMask)
                            Container(
                              color: const Color(0xFF0F172A).withValues(alpha: 0.95),
                              width: double.infinity,
                              height: double.infinity,
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(30.0),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (!isViolation)
                                        Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            gradient: const LinearGradient(
                                              begin: Alignment.topLeft,
                                              end: Alignment.bottomRight,
                                              colors: [Color(0xFF334155), Color(0xFF0F172A)],
                                            ),
                                            boxShadow: [
                                              BoxShadow(color: Colors.black.withValues(alpha: 0.8), offset: const Offset(0, 12), blurRadius: 24),
                                              BoxShadow(color: Colors.cyanAccent.withValues(alpha: 0.3), offset: const Offset(0, 0), blurRadius: 20),
                                            ],
                                            border: Border.all(color: Colors.white24, width: 1.5),
                                          ),
                                          child: ClipOval(
                                            child: Image.asset("assets/logo.png", height: 90, width: 90, fit: BoxFit.cover),
                                          ),
                                        )
                                      else
                                        const Icon(Icons.gpp_maybe, color: Colors.redAccent, size: 60),
                                      const SizedBox(height: 25),
                                      if (!isViolation)
                                        const SizedBox(
                                          width: 30,
                                          height: 30,
                                          child: CircularProgressIndicator(color: Colors.cyanAccent, strokeWidth: 3),
                                        )
                                      else
                                        const Icon(Icons.security, color: Colors.white54, size: 40),
                                      const SizedBox(height: 15),
                                      Text(
                                        isViolation ? _violationMessage! : "AUDITORÍA DE SEGURIDAD EN CURSO",
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 1),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        isViolation ? "Tu acceso ha sido revocado" : "Verificando estado del listero...",
                                        style: const TextStyle(color: Colors.white38, fontSize: 10),
                                      ),
                                      if (isViolation) ...[
                                        const SizedBox(height: 40),
                                        ElevatedButton.icon(
                                          onPressed: () {
                                            setState(() { _violationMessage = null; });
                                            Alex().isUserVerified.value = true;
                                            Navigator.of(MyApp.navigatorKey.currentContext!).pushAndRemoveUntil(
                                              MaterialPageRoute(builder: (_) => const LoginScreen()),
                                              (route) => false
                                            );
                                          },
                                          icon: const Icon(Icons.logout),
                                          label: const Text("VOLVER AL LOGIN"),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.redAccent,
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                          ),
                                        )
                                      ]
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildUpdateMask() {
    final bool isDownloading = _downloadStatus.startsWith("Descargando") || _downloadStatus == "Descarga en curso...";
    final bool isInstalling = _downloadStatus == "Instalando...";
    final bool hasError = _downloadStatus.contains("Error");

    return Container(
      color: Colors.blue.shade900.withValues(alpha: 1.0),
      width: double.infinity,
      height: double.infinity,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(30.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hasError ? Icons.error_outline : Icons.auto_awesome, 
                color: hasError ? Colors.orangeAccent : Colors.greenAccent, 
                size: 70
              ),
              const SizedBox(height: 20),
              Text(
                isInstalling ? "LISTO PARA INSTALAR" : (hasError ? "ATENCIÓN REQUERIDA" : "MEJORA v${_updateData?['required']} LISTA"),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 18, letterSpacing: 1),
              ),
              const SizedBox(height: 20),
              
              // PANEL DE NOTAS DE CAMBIO
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("CAMBIOS EN ESTA VERSIÓN:", style: TextStyle(color: Colors.greenAccent, fontSize: 10, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    Text(
                      _updateData?['message'] ?? "Optimizaciones de sistema y mejoras de seguridad.",
                      style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                    ),
                    if (isDownloading) ...[
                      const Divider(height: 20, color: Colors.white10),
                      const Text("Mantén la aplicación abierta. Si hay cortes, el sistema reintentará solo.", style: TextStyle(color: Colors.white38, fontSize: 10)),
                    ],
                  ],
                ),
              ),

              if (hasError)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    "Ocurrió un detalle: $_downloadStatus\nIntenta presionar el botón de abajo.",
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
              
              const SizedBox(height: 30),
              if (isDownloading || isInstalling) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: LinearProgressIndicator(
                    value: isInstalling ? 1.0 : _progress / 100,
                    minHeight: 8,
                    backgroundColor: Colors.white10,
                    color: Colors.greenAccent,
                  ),
                ),
                const SizedBox(height: 12),
                Text(_downloadStatus, style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                if (isInstalling) ...[
                  const SizedBox(height: 30),
                  const Text(
                    "Si no ves el instalador de Android,\npresiona el botón de REINTENTAR.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ],
              
              if (!isDownloading) ...[
                if (!isInstalling && !hasError)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(10)),
                    child: Text(
                      "INSTALADA: ${_updateData?['current']}  →  NUEVA: ${_updateData?['required']}",
                      style: const TextStyle(color: Colors.white38, fontSize: 9, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                    ),
                  ),
                const SizedBox(height: 30),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      final url = _updateData?['url'];
                      if (url != null && url.isNotEmpty) {
                        Alex().downloadAndInstallApk(url);
                      }
                    },
                    icon: Icon(isInstalling || hasError ? Icons.refresh : Icons.bolt_rounded),
                    label: Text(isInstalling ? "REINTENTAR INSTALACIÓN" : (hasError ? "VOLVER A INTENTAR" : "ACTUALIZAR AHORA"), style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: hasError ? Colors.orange.shade800 : Colors.greenAccent.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      elevation: 8,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
