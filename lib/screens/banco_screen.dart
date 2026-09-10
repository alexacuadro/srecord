import 'dart:async' as async;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/screens/colecturia_screen.dart';
import 'package:srecord/screens/crear_listas_screen.dart';
import 'package:srecord/screens/gestion_screen.dart';
import 'package:srecord/screens/numeros_mas_jugados_screen.dart';
import 'package:srecord/screens/numeros_a_limitar_screen.dart';
import 'package:srecord/screens/partes_listeros_screen.dart';
import 'package:srecord/screens/planes_screen.dart';
import 'package:srecord/screens/tiro_oficial_screen.dart';
import 'package:srecord/screens/login_screen.dart';
import 'package:srecord/screens/loteria_videos_screen.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/database_helper.dart';
import 'package:srecord/screens/info_listeros_screen.dart';
import 'package:srecord/widgets/connection_icon.dart';
import 'package:srecord/widgets/loteria_icon.dart';

class BancoScreen extends StatefulWidget {
  const BancoScreen({super.key});

  @override
  State<BancoScreen> createState() => _BancoScreenState();
}

class _BancoScreenState extends State<BancoScreen> {
  int _selectedIndex = 0;
  async.Timer? _timer;
  DateTime _currentTime = DateTime.now();
  String _bancoId = "...";
  String _bancoName = "";
  Color _regentColor = Colors.lightBlue.shade800;
  String _activeLoteria = "FLORIDA";

  @override
  void initState() {
    super.initState();
    _loadSession();
    _timer = async.Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) setState(() { _currentTime = DateTime.now(); });
    });
    _initLocalData();
    _startBankActivityBeacons();
    DatabaseHelper().onSyncUpdate = _syncUpdateListener;
  }

  void _syncUpdateListener(int id) {
    // Si id == -999, el cambio vino de la nube. 
    // Solo recargamos la UI, NO disparamos otro sync para evitar bucles infinitos.
    if (mounted) {
      if (id == -999) {
        _loadSessionData();
      } else {
        _loadSession();
      }
    }
  }

  void _startBankActivityBeacons() {
    // Beacon inicial
    Alex().notifyBankActive();
    
    // Beacon recurrente cada 60 segundos (Optimizado para reducir tráfico Supabase)
    _timerActivity = async.Timer.periodic(const Duration(seconds: 60), (timer) {
      if (mounted) Alex().notifyBankActive();
    });
  }

  async.Timer? _timerActivity;

  Future<void> _loadSession() async {
    await _loadSessionData();
    // Omnipresencia: Sincronizar al entrar o por cambios locales
    Alex().syncDataToCloud(isDeepSync: true);
  }

  Future<void> _loadSessionData() async {
    final id = await Alex().getActiveBancoId();
    final color = await Alex().getRegentColorObj();
    final prefs = await SharedPreferences.getInstance();
    
    String bankName = "";
    if (id != null) {
      bankName = await Alex().getBankName(id);
      final bankLoterias = await Alex().getBankLoterias(id);
      if (bankLoterias == "FLORIDA") {
        await prefs.setString("sync_loteria", "FLORIDA");
      } else if (bankLoterias == "GEORGIA") {
        await prefs.setString("sync_loteria", "GEORGIA");
      }
    }
    final activeLot = prefs.getString("sync_loteria") ?? "FLORIDA";
    if (mounted) {
      setState(() { 
        _bancoId = id ?? "UNKNOWN"; 
        _bancoName = bankName;
        _regentColor = color;
        _activeLoteria = activeLot;
      });
      _checkPendingAnnouncements();
    }
  }

  Future<void> _checkPendingAnnouncements() async {
    // Los comunicados son únicamente para los listeros, no para el banco.
    return;
  }

  Future<void> _initLocalData() async {
    final bancoId = await Alex().getActiveBancoId();
    final prefs = await SharedPreferences.getInstance();
    await DatabaseHelper().migrateFromPrefs(prefs, bancoId ?? "UNKNOWN");
  }

  @override
  void dispose() {
    DatabaseHelper().removeSyncUpdate(_syncUpdateListener);
    _timer?.cancel();
    _timerActivity?.cancel();
    super.dispose();
  }

  String _formatClock(DateTime now) {
    int hour = now.hour % 12;
    if (hour == 0) hour = 12;
    String period = now.hour < 12 ? "AM" : "PM";
    return "${hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')} $period";
  }

  final List<Map<String, dynamic>> _menuItems = [
    {'title': 'LISTA GENERAL', 'icon': Icons.list_alt, 'view': const ColecturiaScreen()},
    {'title': 'GESTIÓN LISTAS', 'icon': Icons.people_alt, 'view': const CrearListasScreen()},
    {'title': 'PLANES PAGOS', 'icon': Icons.assignment, 'view': const PlanesScreen()},
    {'title': 'LIMITACIONES', 'icon': Icons.block_flipped, 'view': const NumerosALimitarScreen()},
    {'title': 'TIRO OFICIAL', 'icon': Icons.verified_user, 'view': const TiroOficialScreen()},
    {'title': 'MÁS JUGADOS', 'icon': Icons.trending_up, 'view': const NumerosMasJugadosScreen()},
    {'title': 'PARTES', 'icon': Icons.history_edu, 'view': const PartesListerosScreen()},
    {'title': 'COMUNICADOS', 'icon': Icons.campaign, 'view': const InfoListerosScreen()},
    {'title': 'VÍDEOS LOTERÍA', 'icon': Icons.play_circle_fill, 'view': const LoteriaVideosScreen()},
    {'title': 'SISTEMA', 'icon': Icons.settings, 'view': const GestionScreen()},
  ];

  @override
  Widget build(BuildContext context) {
    print("[BANCO_DEBUG] Dibujando interfaz. Vista activa: ${_menuItems[_selectedIndex]['title']}");
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                _regentColor.withValues(alpha: 0.95),
                _regentColor,
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                offset: const Offset(0, 4),
                blurRadius: 10,
              ),
            ],
          ),
          child: AppBar(
            titleSpacing: 0,
            title: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LoteriaIcon(loteria: _activeLoteria, size: 34, width: 48, borderRadius: 8),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _bancoName.isNotEmpty ? _bancoName : "BANCO: $_bancoId", 
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                            shadows: [
                              Shadow(color: Colors.black45, offset: Offset(0, 2), blurRadius: 4),
                            ],
                          ),
                        ),
                        Text(
                          _menuItems[_selectedIndex]['title'], 
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.5,
                            color: Colors.white.withValues(alpha: 0.9),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            backgroundColor: Colors.transparent,
            foregroundColor: Colors.white,
            elevation: 0,
            actions: [
              const ConnectionIcon(),
              // Botón 3D Sincronizar
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.3), offset: const Offset(0, 2), blurRadius: 4),
                  ],
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.sync, color: Colors.white, size: 18),
                  onPressed: () async {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Sincronizando Banco..."), duration: Duration(seconds: 1)));
                    await Alex().syncDataToCloud(isDeepSync: true);
                    await _loadSession();
                  },
                ),
              ),
              // Reloj 3D Neumórfico
              Container(
                margin: const EdgeInsets.only(right: 12, top: 8, bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.black.withValues(alpha: 0.4),
                      Colors.black.withValues(alpha: 0.2),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.2), width: 1),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.4), offset: const Offset(0, 3), blurRadius: 6),
                    BoxShadow(color: Colors.white.withValues(alpha: 0.1), offset: const Offset(-1, -1), blurRadius: 2),
                  ],
                ),
                alignment: Alignment.center,
                child: Text(
                  _formatClock(_currentTime), 
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, fontFamily: 'monospace', color: Colors.amberAccent),
                ),
              ),
            ],
          ),
        ),
      ),
      drawer: _buildDrawer(),
      body: Column(
        children: [
          _buildSubHeader(),
          Expanded(
            child: _menuItems[_selectedIndex]['view'],
          ),
        ],
      ),
    );
  }

  Widget _buildSubHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _regentColor.withValues(alpha: 0.85),
            _regentColor,
          ],
        ),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.2), offset: const Offset(0, 2), blurRadius: 4),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Row(
              children: const [
                Icon(Icons.security, size: 14, color: Colors.white70), 
                SizedBox(width: 6), 
                Flexible(
                  child: Text(
                    "ACCESO ADMINISTRATIVO", 
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10, letterSpacing: 0.5), 
                    overflow: TextOverflow.ellipsis,
                  ),
                ), 
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Badge 3D S-RECORD PRO
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3), 
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF334155), Color(0xFF0F172A)],
              ),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white24, width: 0.8),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.4), offset: const Offset(0, 2), blurRadius: 4),
              ],
            ), 
            child: const Text("S-RECORD PRO", style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.w900, fontSize: 9, letterSpacing: 1))
          ),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: Container(
        color: const Color(0xFFF8FAFC),
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            // DrawerHeader 3D con Esfera y Bisel
            DrawerHeader(
              margin: EdgeInsets.zero,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [_regentColor, _regentColor.withValues(alpha: 0.85), const Color(0xFF0F172A)],
                ),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.4), offset: const Offset(0, 4), blurRadius: 10),
                ],
              ),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Hero(
                        tag: "app_logo",
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Colors.white24, Colors.black26],
                            ),
                            border: Border.all(color: Colors.white30, width: 1.5),
                            boxShadow: [
                              BoxShadow(color: Colors.black.withValues(alpha: 0.5), offset: const Offset(0, 6), blurRadius: 12),
                            ],
                          ),
                          child: ClipOval(
                            child: Image.asset('assets/logo.png', height: 62, width: 62, fit: BoxFit.cover),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        "CENTRO DE CONTROL", 
                        style: TextStyle(
                          color: Colors.white, 
                          fontSize: 18, 
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1,
                          shadows: [Shadow(color: Colors.black54, offset: Offset(0, 2), blurRadius: 4)],
                        ),
                      ),
                      Text("ID BANCO: $_bancoId", style: const TextStyle(color: Colors.amberAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            ...List.generate(_menuItems.length, (index) {
              bool isSel = _selectedIndex == index;
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: isSel 
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [_regentColor.withValues(alpha: 0.15), Colors.white],
                      )
                    : null,
                  color: isSel ? null : Colors.transparent,
                  border: isSel ? Border.all(color: _regentColor.withValues(alpha: 0.4), width: 1.5) : null,
                  boxShadow: isSel ? [
                    BoxShadow(color: _regentColor.withValues(alpha: 0.15), offset: const Offset(0, 4), blurRadius: 8),
                  ] : null,
                ),
                child: ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  leading: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: isSel ? _regentColor : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: isSel ? [
                        BoxShadow(color: _regentColor.withValues(alpha: 0.4), offset: const Offset(0, 2), blurRadius: 4),
                      ] : null,
                    ),
                    child: Icon(_menuItems[index]['icon'], color: isSel ? Colors.white : Colors.grey.shade700, size: 20),
                  ),
                  title: Text(
                    _menuItems[index]['title'], 
                    style: TextStyle(
                      color: isSel ? _regentColor : const Color(0xFF1E293B), 
                      fontWeight: isSel ? FontWeight.w900 : FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  selected: isSel,
                  onTap: () {
                    print("[BANCO_MENU] Seleccionado: ${_menuItems[index]['title']}");
                    setState(() => _selectedIndex = index);
                    Navigator.pop(context);
                  },
                ),
              );
            }),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Divider(),
            ),
            // Botón 3D Cerrar Sesión
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFFEE2E2), Color(0xFFFECDD3)],
                ),
                border: Border.all(color: Colors.red.shade200),
                boxShadow: [
                  BoxShadow(color: Colors.red.shade100, offset: const Offset(0, 3), blurRadius: 6),
                ],
              ),
              child: ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                leading: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: Colors.red.shade600, borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.logout, color: Colors.white, size: 18),
                ),
                title: Text('CERRAR SESIÓN', style: TextStyle(color: Colors.red.shade800, fontWeight: FontWeight.w900, fontSize: 13)),
                onTap: () => _confirmExit(context),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  void _confirmExit(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: Colors.red.shade300, width: 1.5),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.red.shade50, shape: BoxShape.circle),
              child: Icon(Icons.logout, color: Colors.red.shade700, size: 22),
            ),
            const SizedBox(width: 10),
            const Text("FINALIZAR SESIÓN", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
          ],
        ),
        content: const Text("¿Seguro que desea salir del centro de control?", style: TextStyle(color: Colors.black87, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx), 
            child: const Text("CANCELAR", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade700, 
              foregroundColor: Colors.white,
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const LoginScreen()), (route) => false),
            child: const Text("SALIR", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
