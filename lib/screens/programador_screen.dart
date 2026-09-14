import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:async' as async;
import 'package:file_picker/file_picker.dart';
import 'package:srecord/services/database_helper.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/screens/login_screen.dart';
import 'package:srecord/screens/rent_config_screen.dart';
import 'package:srecord/services/notification_service.dart';
import 'package:srecord/services/rent_service.dart';
import 'package:srecord/widgets/connection_icon.dart';
import 'package:srecord/widgets/loteria_icon.dart';

class ProgramadorScreen extends StatefulWidget {
  const ProgramadorScreen({super.key});

  @override
  State<ProgramadorScreen> createState() => _ProgramadorScreenState();
}

class _ProgramadorScreenState extends State<ProgramadorScreen> with SingleTickerProviderStateMixin {
  final DatabaseHelper _db = DatabaseHelper();
  final Alex _alex = Alex();
  
  List<String> _banks = [];
  List<String> _usedColors = [];
  List<Map<String, dynamic>> _pendingRequests = [];
  bool _isLoading = true;
  bool _isUploading = false;
  late TabController _tabController;
  async.StreamSubscription? _syncSubscription;

  final TextEditingController _versionCodeController = TextEditingController();
  final TextEditingController _versionNameController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _iosUrlController = TextEditingController(text: "https://github.com/alexacuadro/srecord/actions");
  bool _isTriggeringIos = false;
  File? _selectedApk;
  static const _apkChannel = MethodChannel("com.fusionpro.srecord/apk_info");

  final List<Color> _availableColors = [
    Colors.blue, Colors.red, Colors.green, Colors.orange, Colors.purple,
    Colors.teal, Colors.indigo, Colors.pink, Colors.amber, Colors.brown,
    Colors.cyan, Colors.deepOrange, Colors.deepPurple, Colors.lightBlue,
    Colors.lightGreen, Colors.lime, Colors.yellow, Colors.grey, Colors.blueGrey,
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadData();
    _db.onSyncUpdate = _onDbSyncUpdate;
    _syncSubscription = _alex.onLiveBetReceived.listen((payload) {
      if (mounted) _loadData();
    });
  }

  void _onDbSyncUpdate(int id) {
    if (mounted) _loadData();
  }

  @override
  void dispose() {
    _db.removeSyncUpdate(_onDbSyncUpdate);
    _syncSubscription?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final banks = await _alex.getCloudBanks();
    final used = await _db.getUsedColors();
    final requests = await _alex.getPendingBankRequests();
    
    // Notificación nativa para Programador si hay rentas pendientes/próximas
    for (var bId in banks) {
      final shouldRemind = await RentService().shouldShowPaymentReminder(bancoId: bId);
      if (shouldRemind) {
        final monto = await RentService().getMonto(bancoId: bId);
        final isSat = await RentService().isSaturdayBeforePaymentDay(bancoId: bId);
        final String dayLabel = isSat ? "MAÑANA DOMINGO" : "HOY DOMINGO";
        
        NotificationService().showNotification(
          id: (bId.hashCode).abs() % 10000 + 900,
          title: "🔔 RENTA PENDIENTE: BANCO $bId",
          body: "El Banco $bId tiene cobro de renta pactado para $dayLabel (\$${monto.round()} USD).",
          payloadKey: "rent_prog_$bId",
        );
      }
    }

    setState(() {
      _banks = banks;
      _usedColors = used;
      _pendingRequests = requests;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("CONSOLA SUPREMA", style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, letterSpacing: 2)),
        backgroundColor: Colors.black,
        foregroundColor: const Color(0xFF38BDF8),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF38BDF8),
          labelColor: const Color(0xFF38BDF8),
          unselectedLabelColor: Colors.white24,
          tabs: [
            Tab(text: "SOLICITUDES (${_pendingRequests.length})"),
            Tab(text: "BANCOS ACTIVOS (${_banks.length} / 9)"),
            const Tab(text: "ACTUALIZACIONES"),
          ],
        ),
        actions: [
          const ConnectionIcon(color: Color(0xFF38BDF8)),
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFF38BDF8)),
            onPressed: _loadData,
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.redAccent),
            onPressed: () async {
              await Alex().logout();
              if (!context.mounted) return;
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const LoginScreen()),
                (route) => false,
              );
            },
          ),
        ],
      ),
      backgroundColor: const Color(0xFF020617),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF38BDF8)))
          : TabBarView(
              controller: _tabController,
              children: [
                _buildRequestsList(),
                _buildBanksList(),
                _buildUpdatesManager(),
              ],
            ),
    );
  }

  Widget _buildRequestsList() {
    if (_pendingRequests.isEmpty) {
      return const Center(
        child: Text("NO HAY SOLICITUDES PENDIENTES", style: TextStyle(color: Colors.white10, fontFamily: 'monospace')),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _pendingRequests.length,
      itemBuilder: (context, index) {
        final req = _pendingRequests[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.4), width: 1.2),
            boxShadow: [
              BoxShadow(color: const Color(0xFF38BDF8).withValues(alpha: 0.15), offset: const Offset(0, 4), blurRadius: 10),
              BoxShadow(color: Colors.black.withValues(alpha: 0.6), offset: const Offset(0, 6), blurRadius: 12),
            ],
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.3)),
              ),
              child: const Icon(Icons.account_balance_wallet_outlined, color: Color(0xFF38BDF8)),
            ),
            title: Text("ID: ${req['request_id']}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12, fontFamily: 'monospace')),
            subtitle: Text("FECHA: ${req['timestamp']}", style: const TextStyle(color: Colors.white38, fontSize: 10)),
            trailing: Container(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF38BDF8), Color(0xFF0284C7)],
                ),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white38, width: 1),
                boxShadow: [
                  BoxShadow(color: const Color(0xFF0284C7).withValues(alpha: 0.5), offset: const Offset(0, 3), blurRadius: 6),
                ],
              ),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                onPressed: () => _showApproveDialog(req),
                child: const Text("APROBAR", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11)),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBanksList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _banks.length,
      itemBuilder: (context, index) {
        final bankId = _banks[index];
        return FutureBuilder<List<dynamic>>(
          future: Future.wait([
            _db.getBankColor(bankId),
            _db.getBankLoterias(bankId),
            _alex.getBankName(bankId),
          ]),
          builder: (context, snapshot) {
            final colorHex = snapshot.data?[0] as String?;
            final loterias = snapshot.data?[1] as String? ?? "AMBAS";
            final bankName = snapshot.data?[2] as String? ?? "";
            Color? bankColor;
            
            if (colorHex != null) {
              try {
                String clean = colorHex.replaceFirst('#', '');
                if (clean.length == 6) clean = 'FF$clean';
                bankColor = Color(int.parse(clean, radix: 16));
              } catch (e) {
                debugPrint("[ALEX_PROG] Error parseando color del banco $bankId ($colorHex): $e");
              }
            }

            String loteriasLabel = "AMBAS (🌴 🍑)";
            if (loterias == "FLORIDA") loteriasLabel = "SOLO FLORIDA (🌴)";
            if (loterias == "GEORGIA") loteriasLabel = "SOLO GEORGIA (🍑)";

            final String displayTitle = (bankName.isNotEmpty && bankName != "BANCO $bankId") 
                ? "$bankName (ID: $bankId)" 
                : "BANCO ID: $bankId";

            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: bankColor ?? const Color(0xFF38BDF8).withValues(alpha: 0.4), width: 1.5),
                boxShadow: [
                  BoxShadow(color: (bankColor ?? const Color(0xFF38BDF8)).withValues(alpha: 0.2), offset: const Offset(0, 4), blurRadius: 10),
                  BoxShadow(color: Colors.black.withValues(alpha: 0.5), offset: const Offset(0, 6), blurRadius: 12),
                ],
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                title: Text(displayTitle, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                subtitle: Text("LOTERÍAS: $loteriasLabel", style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.bold)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.alarm_on, color: Colors.amberAccent, size: 22),
                      tooltip: "Configurar Cobro y Renta de App",
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => RentConfigScreen(bancoId: bankId, isProgramadorMode: true),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    IconButton(
                      icon: const Icon(Icons.tune_rounded, color: Color(0xFF38BDF8), size: 22),
                      tooltip: "Configurar Loterías Habilitadas",
                      onPressed: () => _showLotteryPicker(bankId, loterias),
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: () => _showColorPicker(bankId),
                      child: Container(
                        width: 28, height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle, 
                          color: bankColor ?? Colors.transparent, 
                          border: Border.all(color: Colors.white, width: 1.2),
                          boxShadow: [
                            BoxShadow(color: (bankColor ?? Colors.black).withValues(alpha: 0.4), offset: const Offset(0, 2), blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.key_rounded, color: Colors.greenAccent, size: 20),
                      tooltip: "Cambiar Contraseña / PIN del Banco",
                      onPressed: () => _showEditPasswordDialog(bankId),
                    ),
                    const SizedBox(width: 2),
                    IconButton(
                      icon: const Icon(Icons.delete_sweep, color: Colors.redAccent, size: 20),
                      onPressed: () => _showDeleteBankDialog(bankId),
                    ),
                  ],
                ),
                onTap: () => _showLotteryPicker(bankId, loterias),
              ),
            );
          },
        );
      },
    );
  }

  void _showApproveDialog(Map<String, dynamic> request) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text("APROBAR SOLICITUD", style: TextStyle(color: Color(0xFF38BDF8), fontFamily: 'monospace')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("¿Deseas autorizar la creación de este banco?", style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            Text("ID: ${request['request_id']}", style: const TextStyle(color: Colors.white24, fontSize: 10, fontFamily: 'monospace')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR", style: TextStyle(color: Colors.white38))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF38BDF8), foregroundColor: Colors.black),
            onPressed: () async {
              final success = await _alex.approveBankRequest(request['request_id']);

              if (!ctx.mounted) return;
              
              if (success) {
                Navigator.pop(ctx);
                _loadData();
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text("SOLICITUD APROBADA. El usuario ya puede configurar su banco.")));
              } else {
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                  content: Text("ERROR AL APROBAR. Verifique su conexión o permisos."),
                  backgroundColor: Colors.redAccent,
                ));
              }
            },
            child: const Text("APROBAR AHORA"),
          ),
        ],
      ),
    );
  }

  void _showColorPicker(String bankId) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(25))),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("CAMBIAR COLOR REGENTE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
              const SizedBox(height: 20),
              GridView.builder(
                shrinkWrap: true,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 5, mainAxisSpacing: 10, crossAxisSpacing: 10),
                itemCount: _availableColors.length,
                itemBuilder: (context, index) {
                  final color = _availableColors[index];
                  final hex = color.toARGB32().toRadixString(16);
                  final bool isUsed = _usedColors.contains(hex);

                  return GestureDetector(
                    onTap: isUsed ? null : () async {
                      final navigator = Navigator.of(context);
                      await _alex.updateBankIdentity(bankId, bankId, hex);
                      if (mounted) navigator.pop();
                      _loadData();
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24, width: 2),
                      ),
                      child: isUsed ? const Icon(Icons.block, color: Colors.white54, size: 16) : null,
                    ),
                  );
                },
              ),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }

  void _showLotteryPicker(String bankId, String current) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(25))),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("LOTERÍAS PERMITIDAS PARA $bankId", style: const TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, letterSpacing: 1.2, fontFamily: 'monospace')),
              const SizedBox(height: 8),
              const Text("Como programador, selecciona qué loterías están habilitadas para este banco:", style: TextStyle(color: Colors.white60, fontSize: 12)),
              const SizedBox(height: 20),
              _lotteryOptionTile(bankId, "AMBAS", "FLORIDA Y GEORGIA (AMBAS)", current),
              const SizedBox(height: 10),
              _lotteryOptionTile(bankId, "FLORIDA", "FLORIDA ÚNICAMENTE", current),
              const SizedBox(height: 10),
              _lotteryOptionTile(bankId, "GEORGIA", "GEORGIA ÚNICAMENTE", current),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }

  Widget _lotteryOptionTile(String bankId, String option, String label, String current) {
    final bool isSel = current.toUpperCase() == option;
    return InkWell(
      onTap: () async {
        final nav = Navigator.of(context);
        await _alex.updateBankLoterias(bankId, option);
        if (mounted) {
          nav.pop();
          _loadData();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Loterías para $bankId configuradas a: $option"),
              backgroundColor: const Color(0xFF38BDF8),
            ),
          );
        }
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isSel ? const Color(0xFF38BDF8).withValues(alpha: 0.15) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isSel ? const Color(0xFF38BDF8) : Colors.white10, width: 1.5),
        ),
        child: Row(
          children: [
            Icon(
              isSel ? Icons.check_circle : Icons.circle_outlined,
              color: isSel ? const Color(0xFF38BDF8) : Colors.white38,
            ),
            const SizedBox(width: 12),
            if (option == "FLORIDA") ...[
              const LoteriaIcon(loteria: "FLORIDA", size: 18, borderRadius: 2),
              const SizedBox(width: 8),
            ] else if (option == "GEORGIA") ...[
              const LoteriaIcon(loteria: "GEORGIA", size: 18, borderRadius: 2),
              const SizedBox(width: 8),
            ] else ...[
              const LoteriaIcon(loteria: "FLORIDA", size: 16, borderRadius: 2),
              const SizedBox(width: 2),
              const LoteriaIcon(loteria: "GEORGIA", size: 16, borderRadius: 2),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: isSel ? Colors.white : Colors.white70,
                  fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUpdatesManager() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("GESTOR MULTIPLATAFORMA DE ACTUALIZACIONES (ANDROID & iOS)", style: TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, letterSpacing: 1)),
          const SizedBox(height: 8),
          const Text("Publica versiones globales para Android y gestiona enlaces de TestFlight / Safari para iOS.", style: TextStyle(color: Colors.white38, fontSize: 11)),
          const SizedBox(height: 25),
          
          TextField(
            controller: _versionCodeController,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            decoration: _inputDecoration("Version Code (ej: 48)", Icons.numbers),
          ),
          const SizedBox(height: 15),
          TextField(
            controller: _versionNameController,
            style: const TextStyle(color: Colors.white),
            decoration: _inputDecoration("Version Name (ej: 1.1.48)", Icons.label_outline),
          ),
          const SizedBox(height: 15),
          TextField(
            controller: _notesController,
            maxLines: 2,
            style: const TextStyle(color: Colors.white),
            decoration: _inputDecoration("Notas de la versión...", Icons.note_add_outlined),
          ),
          const SizedBox(height: 15),
          TextField(
            controller: _iosUrlController,
            style: const TextStyle(color: Colors.white),
            decoration: _inputDecoration("Enlace iOS (TestFlight / GitHub)", Icons.apple),
          ),
          const SizedBox(height: 20),

          // BOTÓN DE DISPARO COMPILACIÓN iOS EN LA NUBE
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton.icon(
              onPressed: _isTriggeringIos ? null : _triggerIosBuild,
              icon: const Icon(Icons.cloud_sync, color: Colors.amberAccent),
              label: Text(
                _isTriggeringIos ? "INICIANDO COMPILACIÓN iOS..." : "🚀 DISPARAR COMPILACIÓN iOS EN GITHUB",
                style: const TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 11),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.amberAccent),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 20),
          
          InkWell(
            onTap: _pickApk,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: _selectedApk != null ? const Color(0xFF10B981) : Colors.white10),
              ),
              child: Column(
                children: [
                  Icon(_selectedApk != null ? Icons.check_circle : Icons.upload_file, color: _selectedApk != null ? const Color(0xFF10B981) : const Color(0xFF38BDF8), size: 40),
                  const SizedBox(height: 10),
                  Text(
                    _selectedApk != null ? "APK SELECCIONADA: ${_selectedApk!.path.split('/').last}" : "SELECCIONAR ARCHIVO APK (ANDROID)",
                    style: TextStyle(color: _selectedApk != null ? Colors.white : Colors.white54, fontWeight: FontWeight.bold, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 30),
          ValueListenableBuilder<Map<String, dynamic>>(
            valueListenable: _alex.uploadProgressDetails,
            builder: (context, details, child) {
              if (!_isUploading) return const SizedBox.shrink();

              final double progress = (details['progress'] as double? ?? 0.0).clamp(0.0, 1.0);
              final String mbSent = details['mbSent']?.toString() ?? '0.0';
              final String mbTotal = details['mbTotal']?.toString() ?? '0.0';
              final String speed = details['speed']?.toString() ?? '0.0';
              final String percentStr = (progress * 100).toStringAsFixed(1);

              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.6), width: 1.5),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 4)),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Expanded(
                          child: Row(
                            children: [
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF38BDF8)),
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  "SUBIENDO APK A SUPABASE...",
                                  style: TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.5),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          "$percentStr%",
                          style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.w900, fontSize: 13, fontFamily: 'monospace'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: progress == 0 ? null : progress,
                        minHeight: 12,
                        backgroundColor: Colors.white10,
                        valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            "Enviado: $mbSent MB / $mbTotal MB",
                            style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          "Velocidad: $speed MB/s",
                          style: const TextStyle(color: Colors.amberAccent, fontSize: 10, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
          SizedBox(
            width: double.infinity,
            height: 55,
            child: ElevatedButton.icon(
              onPressed: _isUploading ? null : _uploadUpdate,
              icon: _isUploading ? const SizedBox.shrink() : const Icon(Icons.cloud_upload),
              label: _isUploading 
                ? const Text("ESPERA...", style: TextStyle(color: Colors.white38)) 
                : const Text("SUBIR Y ACTIVAR ACTUALIZACIÓN", style: TextStyle(fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF38BDF8),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),

          const SizedBox(height: 35),
          const Divider(color: Colors.white24, thickness: 1),
          const SizedBox(height: 20),

          // SECCIÓN DE MONITOR EN TIEMPO REAL DEL STORAGE DE SUPABASE
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.cloud_done, color: Color(0xFF10B981), size: 20),
                  SizedBox(width: 8),
                  Text("STORAGE EN NUBE (SUPABASE)", style: TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1)),
                ],
              ),
              IconButton(
                onPressed: () => setState(() {}),
                icon: const Icon(Icons.refresh, color: Color(0xFF38BDF8), size: 20),
                tooltip: "Refrescar Almacenamiento",
              ),
            ],
          ),
          const Text("Versiones guardadas activas en la base de datos y Storage de Supabase (Máximo 5 retenidas):", style: TextStyle(color: Colors.white38, fontSize: 11)),
          const SizedBox(height: 15),

          FutureBuilder<List<Map<String, dynamic>>>(
            future: _alex.getCloudUpdates(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(color: Color(0xFF38BDF8))));
              }

              final updates = snapshot.data ?? [];
              if (updates.isEmpty) {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: const Center(
                    child: Text("No hay actualizaciones registradas en Supabase Storage.", style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                );
              }

              return ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: updates.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final u = updates[index];
                  final String vName = u['version_name']?.toString() ?? 'N/A';
                  final String vCode = u['version_code']?.toString() ?? 'N/A';
                  final String pkg = u['package_name']?.toString() ?? 'N/A';
                  final String apkUrl = u['apk_url']?.toString() ?? '';
                  final String createdAt = u['created_at']?.toString() ?? '';
                  final String notes = u['release_notes']?.toString() ?? '';

                  return Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF38BDF8).withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text("v$vName (Build $vCode)", style: const TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, fontSize: 12)),
                                ),
                                const SizedBox(width: 8),
                                if (index == 0)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.green.shade800,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text("ACTIVA EN NUBE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 9)),
                                  ),
                              ],
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                              onPressed: () => _confirmDeleteCloudUpdate(u),
                              tooltip: "Eliminar versión de Supabase",
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text("Paquete: $pkg", style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace')),
                        if (createdAt.isNotEmpty)
                          Text("Fecha: ${createdAt.replaceAll('T', ' ').split('.').first}", style: const TextStyle(color: Colors.white38, fontSize: 10)),
                        if (notes.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text("Notas: $notes", style: const TextStyle(color: Colors.white54, fontSize: 11, fontStyle: FontStyle.italic)),
                        ],
                        if (apkUrl.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          InkWell(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: apkUrl));
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Enlace APK copiado al portapapeles"), backgroundColor: Colors.teal));
                            },
                            child: Row(
                              children: [
                                const Icon(Icons.link, color: Color(0xFF38BDF8), size: 14),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    apkUrl,
                                    style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 10, decoration: TextDecoration.underline),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const Icon(Icons.copy, color: Colors.white38, size: 12),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white38, fontSize: 12),
      prefixIcon: Icon(icon, color: const Color(0xFF38BDF8), size: 20),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.white10)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF38BDF8))),
      filled: true,
      fillColor: const Color(0xFF0F172A),
    );
  }

  Future<void> _pickApk() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['apk'],
    );

    if (result != null) {
      final file = File(result.files.single.path!);
      setState(() {
        _selectedApk = file;
      });

      // Intentar extraer info del APK automáticamente
      try {
        final Map<dynamic, dynamic>? info = await _apkChannel.invokeMethod("getApkInfo", {"path": file.path});
        if (info != null && mounted) {
          setState(() {
            _versionCodeController.text = info['versionCode'].toString();
            _versionNameController.text = info['versionName'].toString();
          });
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("DATOS DEL APK EXTRAÍDOS AUTOMÁTICAMENTE"),
            backgroundColor: Color(0xFF10B981),
            duration: Duration(seconds: 2),
          ));
        }
      } catch (e) {
        debugPrint("[ALEX_APK_INFO_ERR] $e");
      }
    }
  }

  Future<void> _uploadUpdate() async {
    if (_versionCodeController.text.isEmpty || _versionNameController.text.isEmpty || _selectedApk == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Completa todos los campos y selecciona el APK")));
      return;
    }

    final int? vCode = int.tryParse(_versionCodeController.text);
    if (vCode == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Version Code debe ser un número")));
      return;
    }

    setState(() => _isUploading = true);

    // 1. Confirmación de Integridad Pre-Subida
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text("VERIFICAR ACTUALIZACIÓN", style: TextStyle(color: Color(0xFF38BDF8), fontFamily: 'monospace')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Se va a publicar la siguiente mejora:", style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 15),
            _infoText("VERSIÓN", _versionNameController.text),
            _infoText("BUILD", _versionCodeController.text),
            _infoText("ARCHIVO", _selectedApk!.path.split('/').last),
            const SizedBox(height: 15),
            const Text("Esta acción notificará a todos los dispositivos de inmediato.", style: TextStyle(color: Colors.orangeAccent, fontSize: 10)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("CANCELAR", style: TextStyle(color: Colors.white38))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("CONFIRMAR Y SUBIR"),
          ),
        ],
      ),
    );

    if (confirm != true) {
      setState(() => _isUploading = false);
      return;
    }

    final res = await _alex.uploadNewUpdate(
      file: _selectedApk!,
      versionCode: vCode,
      versionName: _versionNameController.text,
      releaseNotes: _notesController.text,
      iosUrl: _iosUrlController.text.trim(),
    );

    setState(() => _isUploading = false);

    if (mounted) {
      if (res['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("¡ACTUALIZACIÓN MULTIPLATAFORMA PUBLICADA CON ÉXITO!"), backgroundColor: Colors.green));
        setState(() {
          _selectedApk = null;
          _versionCodeController.clear();
          _versionNameController.clear();
          _notesController.clear();
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: ${res['error']}"), backgroundColor: Colors.redAccent));
      }
    }
  }

  Future<void> _triggerIosBuild() async {
    setState(() => _isTriggeringIos = true);
    final res = await _alex.triggerGitHubIosBuild();
    setState(() => _isTriggeringIos = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res['message'] ?? "Sincronizando con GitHub..."),
          backgroundColor: res['success'] == true ? Colors.green : Colors.orangeAccent,
        ),
      );
    }
  }

  Future<void> _confirmDeleteCloudUpdate(Map<String, dynamic> u) async {
    final String vName = u['version_name']?.toString() ?? '';
    final String vCode = u['version_code']?.toString() ?? '';
    final dynamic id = u['id'];
    final String? apkUrl = u['apk_url']?.toString();

    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text("ELIMINAR ACTUALIZACIÓN", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
        content: Text("¿Está seguro de eliminar permanentemente la versión v$vName ($vCode) de Supabase Storage y Base de Datos?\n\nEsta acción no se puede deshacer."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("CANCELAR", style: TextStyle(color: Colors.white38))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("SÍ, ELIMINAR"),
          ),
        ],
      ),
    );

    if (confirm == true) {
      bool ok = await _alex.deleteCloudUpdate(id, vCode, apkUrl);
      if (mounted) {
        if (ok) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Versión eliminada de Supabase Storage"), backgroundColor: Colors.green));
          setState(() {});
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Error al eliminar versión"), backgroundColor: Colors.redAccent));
        }
      }
    }
  }

  Widget _infoText(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text("$label: ", style: const TextStyle(color: Colors.white24, fontSize: 10, fontWeight: FontWeight.bold)),
          Expanded(child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  void _showEditPasswordDialog(String bankId) {
    final TextEditingController passCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text("CAMBIAR CONTRASEÑA / PIN - $bankId", style: const TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, fontSize: 14)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Ingrese la nueva clave de acceso para este banco:", style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: passCtrl,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                hintText: "Nueva Contraseña / PIN",
                hintStyle: const TextStyle(color: Colors.white30),
                filled: true,
                fillColor: Colors.black26,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR", style: TextStyle(color: Colors.white38))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF38BDF8), foregroundColor: Colors.black),
            onPressed: () async {
              final newPass = passCtrl.text.trim();
              if (newPass.isEmpty) return;
              Navigator.pop(ctx);
              final success = await _alex.updateBankPassword(bankId, newPass);
              if (mounted) {
                if (success) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("🔑 Contraseña del Banco $bankId actualizada con éxito.")));
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("⚠️ Error: La contraseña ya está en uso o falló la conexión."), backgroundColor: Colors.orangeAccent));
                }
              }
            },
            child: const Text("GUARDAR", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showDeleteBankDialog(String bankId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text("ELIMINAR BANCO", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("ATENCIÓN: Esta acción es irreversible.", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text("Se borrarán todas las listas, jugadas y reportes del banco $bankId permanentemente de la nube.", 
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR", style: TextStyle(color: Colors.white24))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () async {
              Navigator.pop(ctx);
              setState(() => _isLoading = true);
              final success = await _alex.deleteBankFromServer(bankId);
              if (success) {
                _loadData();
              } else if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Error al eliminar el banco."), backgroundColor: Colors.redAccent));
                setState(() => _isLoading = false);
              }
            },
            child: const Text("BORRAR TODO"),
          ),
        ],
      ),
    );
  }
}
