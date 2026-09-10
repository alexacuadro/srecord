import 'dart:async' as async;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/database_helper.dart';
import 'package:srecord/services/tiro_service.dart';
import 'package:srecord/services/recaudacion_service.dart';
import 'package:srecord/services/core_network.dart';
import 'package:srecord/widgets/connection_icon.dart';
import 'package:srecord/widgets/loteria_icon.dart';

class PartesListerosScreen extends StatefulWidget {
  const PartesListerosScreen({super.key});

  @override
  State<PartesListerosScreen> createState() => _PartesListerosScreenState();
}

class _PartesListerosScreenState extends State<PartesListerosScreen> {
  final DatabaseHelper _db = DatabaseHelper();
  List<Map<String, dynamic>> _listeros = [];
  final Map<String, double> _listeroSaldos = {};
  final Map<String, Map<String, dynamic>> _partesDeHoy = {};
  bool _isLoading = true;
  String _enabledLoterias = "AMBAS";
  String _activeLoteria = "FLORIDA";
  String _activeFecha = DateTime.now().toString().substring(0, 10);
  String _activeSeccion = "DIA";
  bool _hayPendientes = false;
  bool _algunoEnviado = false;

  async.Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _loadInitialConfig();
    TiroService().version.addListener(_onTiroUpdate);
    _db.onSyncUpdate = _syncUpdateListener;
  }

  void _onTiroUpdate() {
    _loadData(showLoader: false);
  }

  void _syncUpdateListener(int id) {
    if (!mounted) return;
    // DEBOUNCE: Evitar refrescos excesivos durante sincronización por ráfagas
    _debounceTimer?.cancel();
    _debounceTimer = async.Timer(const Duration(milliseconds: 300), () {
      if (mounted) _loadData(showLoader: false);
    });
  }

  @override
  void dispose() {
    TiroService().version.removeListener(_onTiroUpdate);
    _db.removeSyncUpdate(_syncUpdateListener);
    _debounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadInitialConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    final enabledLoterias = await Alex().getBankLoterias(bancoId);
    _enabledLoterias = enabledLoterias;

    if (enabledLoterias == "FLORIDA") {
      _activeLoteria = "FLORIDA";
    } else if (enabledLoterias == "GEORGIA") {
      _activeLoteria = "GEORGIA";
    } else {
      _activeLoteria = prefs.getString("sync_loteria") ?? "FLORIDA";
    }

    final openData = RecaudacionService.getOpenSeccionAndFecha(loteria: _activeLoteria);
    _activeFecha = prefs.getString("sync_fecha") ?? openData["fecha"]!;
    String rawSeccion = prefs.getString("sync_seccion") ?? openData["seccion"]!;
    _activeSeccion = RecaudacionService.ensureValidSeccion(rawSeccion, _activeLoteria);

    await prefs.setString("sync_loteria", _activeLoteria);
    await prefs.setString("sync_fecha", _activeFecha);
    await prefs.setString("sync_seccion", _activeSeccion);

    _loadData(showLoader: true);
  }

  void _switchLoteria(String loteria) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("sync_loteria", loteria);
    final openData = RecaudacionService.getOpenSeccionAndFecha(loteria: loteria);
    setState(() {
      _activeLoteria = loteria;
      _activeSeccion = openData["seccion"]!;
    });
    await prefs.setString("sync_seccion", _activeSeccion);
    _loadData(showLoader: true);
  }

  Future<void> _loadData({bool showLoader = false}) async {
    if (!mounted) return;
    if (showLoader) setState(() => _isLoading = true);
    
    final prefs = await SharedPreferences.getInstance();
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    final enabledLoterias = await Alex().getBankLoterias(bancoId);
    _enabledLoterias = enabledLoterias;

    String savedLoteria = prefs.getString("sync_loteria") ?? _activeLoteria;
    if (enabledLoterias == "FLORIDA") {
      savedLoteria = "FLORIDA";
    } else if (enabledLoterias == "GEORGIA") {
      savedLoteria = "GEORGIA";
    }

    final String savedFecha = prefs.getString("sync_fecha") ?? _activeFecha;
    String savedSeccion = prefs.getString("sync_seccion") ?? _activeSeccion;
    savedSeccion = RecaudacionService.ensureValidSeccion(savedSeccion, savedLoteria);

    if (savedLoteria != _activeLoteria || savedFecha != _activeFecha || savedSeccion != _activeSeccion) {
      if (mounted) {
        setState(() {
          _activeLoteria = savedLoteria;
          _activeFecha = savedFecha;
          _activeSeccion = savedSeccion;
        });
        await prefs.setString("sync_loteria", _activeLoteria);
        await prefs.setString("sync_seccion", _activeSeccion);
      }
    }

    try {
      final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
      var listeros = await _db.getListeros(bancoId: bancoId);
      
      // FALLBACK listeros
      if (listeros.isEmpty) listeros = await _db.getListeros(bancoId: "UNKNOWN");

      final Map<String, double> tempSaldos = {};
      final Map<String, Map<String, dynamic>> tempPartes = {};

      if (listeros.isNotEmpty) {
        var partesHoy = await _db.getPartesByFechaSeccion(_activeFecha, _activeSeccion, bancoId: bancoId, loteria: _activeLoteria);
        // FALLBACK partes
        if (partesHoy.isEmpty) partesHoy = await _db.getPartesByFechaSeccion(_activeFecha, _activeSeccion, bancoId: "UNKNOWN", loteria: _activeLoteria);
        
        for (var p in partesHoy) {
          tempPartes[p['listero_pin']] = p;
        }

        for (var l in listeros) {
          double saldo = await _db.getLastSaldoFinal(l['pin'], bancoId: bancoId, loteria: _activeLoteria);
          // FALLBACK saldo
          if (saldo == 0) saldo = await _db.getLastSaldoFinal(l['pin'], bancoId: "UNKNOWN", loteria: _activeLoteria);
          tempSaldos[l['pin']] = saldo;
        }
      }

      final hayPendientes = await _db.hasUnpublishedPartes(_activeFecha, _activeSeccion, bancoId: bancoId, loteria: _activeLoteria);
      final algunoEnviado = await _db.arePartesPublicados(_activeFecha, _activeSeccion, bancoId: bancoId, loteria: _activeLoteria);

      if (mounted) {
        setState(() {
          _listeros = listeros;
          _listeroSaldos.clear();
          _listeroSaldos.addAll(tempSaldos);
          _partesDeHoy.clear();
          _partesDeHoy.addAll(tempPartes);
          _hayPendientes = hayPendientes;
          _algunoEnviado = algunoEnviado;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Error loading partes listeros: $e");
      if (mounted) setState(() { _isLoading = false; });
    }
  }

  Future<void> _publicarMasivo() async {
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    if (!mounted) return;

    // 1. Detección de Conexión a Internet
    bool isOnline = CoreNetwork().isConnected;
    if (!isOnline) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.wifi_off, color: Colors.redAccent, size: 28),
              SizedBox(width: 10),
              Expanded(child: Text("SIN CONEXIÓN A INTERNET", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
            ],
          ),
          content: const Text(
            "⚠️ ATENCIÓN: No tienes conexión a internet. Los partes se marcaron para publicar localmente, pero NO PUEDEN SER ENVIADOS a los listeros hasta que te conectes a internet.",
            style: TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("ENTENDIDO")),
          ],
        ),
      );
      return;
    }

    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text("ENVIAR PARTES", style: TextStyle(color: Colors.blue.shade900, fontWeight: FontWeight.w900)),
        content: Text("¿Desea enviar masivamente todos los partes de $_activeFecha ($_activeSeccion)? Los listeros podrán ver sus saldos finales.", 
          style: const TextStyle(color: Colors.black87)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("CANCELAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade800, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("ENVIAR AHORA"),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await Alex().publishPartesForSection(_activeFecha, _activeSeccion, bancoId: bancoId, loteria: _activeLoteria);
      await _db.insertNotificacion(
        "PARTES DISPONIBLES", 
        "El banco ha publicado nuevos partes oficiales para $_activeFecha ($_activeSeccion).",
        bancoId: bancoId
      );
      await Alex().syncDataToCloud(isDeepSync: true);
      Alex().broadcastSyncPulse(isDeep: true);
      TiroService().notifyNewTiro(null);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Partes enviados correctamente a los listeros."), backgroundColor: Colors.green)
        );
      }
      _loadData();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _buildFilterBar(),
          Expanded(
            child: _isLoading 
              ? Center(child: CircularProgressIndicator(color: Colors.blue.shade800))
              : _listeros.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _listeros.length,
                      itemBuilder: (context, index) => _buildListeroCard(_listeros[index]),
                    ),
          ),
          if (_hayPendientes && _listeros.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: SizedBox(
                width: double.infinity, height: 55,
                child: ElevatedButton.icon(
                  onPressed: _publicarMasivo,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade800, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))),
                  icon: const Icon(Icons.send),
                  label: const Text("ENVIAR TODOS LOS PARTES", style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    bool isGeorgia = _activeLoteria == "GEORGIA";
    String displaySeccion = _activeSeccion;
    if (isGeorgia) {
      if (_activeSeccion == "MIDDAY") displaySeccion = "MAÑANA";
      if (_activeSeccion == "EVENING") displaySeccion = "TARDE";
      if (_activeSeccion == "NIGHT") displaySeccion = "NOCHE";
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isGeorgia
              ? [Colors.orange.shade900, Colors.orange.shade700]
              : [Colors.blue.shade900, Colors.lightBlue.shade800],
        ),
        boxShadow: const [
          BoxShadow(color: Colors.black26, offset: Offset(0, 2), blurRadius: 4),
        ],
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // 1. Selector 3D de Lotería
            if (_enabledLoterias == "FLORIDA" || _enabledLoterias == "GEORGIA")
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(10)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LoteriaIcon(loteria: _enabledLoterias, size: 14, borderRadius: 2),
                    const SizedBox(width: 5),
                    Text(_enabledLoterias, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 11)),
                  ],
                ),
              )
            else
              PopupMenuButton<String>(
                icon: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white30, width: 0.8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LoteriaIcon(loteria: _activeLoteria, size: 14, borderRadius: 2),
                      const SizedBox(width: 5),
                      Text(
                        _activeLoteria,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 11),
                      ),
                      const SizedBox(width: 2),
                      const Icon(Icons.arrow_drop_down, color: Colors.white, size: 16),
                    ],
                  ),
                ),
                tooltip: "Seleccionar Lotería",
                onSelected: (val) => _switchLoteria(val),
                itemBuilder: (ctx) => const [
                  PopupMenuItem(
                    value: "FLORIDA",
                    child: Row(
                      children: [
                        LoteriaIcon(loteria: "FLORIDA", size: 18, borderRadius: 2),
                        SizedBox(width: 8),
                        Text("FLORIDA", style: TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: "GEORGIA",
                    child: Row(
                      children: [
                        LoteriaIcon(loteria: "GEORGIA", size: 18, borderRadius: 2),
                        SizedBox(width: 8),
                        Text("GEORGIA", style: TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ],
              ),

            const SizedBox(width: 8),

            // 2. Selector 3D de Fecha
            GestureDetector(
              onTap: _selectFecha,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white38, width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.calendar_month, size: 14, color: Colors.amberAccent),
                    const SizedBox(width: 5),
                    Text(
                      _activeFecha,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(width: 8),

            // 3. Selector 3D de Sección
            PopupMenuButton<String>(
              icon: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white30, width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _activeSeccion == "DIA" || _activeSeccion == "MIDDAY"
                          ? Icons.wb_sunny
                          : (_activeSeccion == "EVENING" ? Icons.wb_twilight : Icons.nightlight_round),
                      color: _activeSeccion == "DIA" || _activeSeccion == "MIDDAY"
                          ? Colors.orangeAccent
                          : (_activeSeccion == "EVENING" ? Colors.amber : Colors.yellow),
                      size: 14,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      displaySeccion,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: 0.8),
                    ),
                    const SizedBox(width: 2),
                    const Icon(Icons.arrow_drop_down, color: Colors.white, size: 16),
                  ],
                ),
              ),
              tooltip: "Seleccionar Sección",
              onSelected: (val) => _switchSeccion(val),
              itemBuilder: (ctx) {
                if (_activeLoteria == "GEORGIA") {
                  return const [
                    PopupMenuItem(value: "MIDDAY", child: Row(children: [Icon(Icons.wb_sunny, size: 16, color: Colors.orange), SizedBox(width: 8), Text("🌅 MAÑANA", style: TextStyle(fontWeight: FontWeight.bold))])),
                    PopupMenuItem(value: "EVENING", child: Row(children: [Icon(Icons.wb_twilight, size: 16, color: Colors.amber), SizedBox(width: 8), Text("☀️ TARDE", style: TextStyle(fontWeight: FontWeight.bold))])),
                    PopupMenuItem(value: "NIGHT", child: Row(children: [Icon(Icons.nightlight_round, size: 16, color: Colors.indigo), SizedBox(width: 8), Text("🌙 NOCHE", style: TextStyle(fontWeight: FontWeight.bold))])),
                  ];
                } else {
                  return const [
                    PopupMenuItem(value: "DIA", child: Row(children: [Icon(Icons.wb_sunny, size: 16, color: Colors.orange), SizedBox(width: 8), Text("🌅 DÍA", style: TextStyle(fontWeight: FontWeight.bold))])),
                    PopupMenuItem(value: "NOCHE", child: Row(children: [Icon(Icons.nightlight_round, size: 16, color: Colors.indigo), SizedBox(width: 8), Text("🌙 NOCHE", style: TextStyle(fontWeight: FontWeight.bold))])),
                  ];
                }
              },
            ),

            if (_algunoEnviado) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(color: Colors.green.shade800, borderRadius: BorderRadius.circular(8)),
                child: const Text("ENVIADOS", style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w900)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _selectFecha() async {
    final openData = RecaudacionService.getOpenSeccionAndFecha(loteria: _activeLoteria);
    DateTime maxDate = DateTime.parse(openData["fecha"]!);

    DateTime? picked = await showDatePicker(
      context: context, 
      initialDate: DateTime.parse(_activeFecha), 
      firstDate: DateTime(2024), 
      lastDate: maxDate
    );

    if (picked != null) {
      final newFecha = picked.toString().substring(0, 10);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("sync_fecha", newFecha);

      if (newFecha == openData["fecha"] && RecaudacionService.isFutureSection(newFecha, _activeSeccion, loteria: _activeLoteria)) {
        _activeSeccion = openData["seccion"]!;
        await prefs.setString("sync_seccion", _activeSeccion);
      }

      setState(() { _activeFecha = newFecha; });
      Alex().broadcastSectionSync(seccion: _activeSeccion, fecha: newFecha);
      _loadData();
    }
  }

  void _switchSeccion(String newSeccion) async {
    if (RecaudacionService.isFutureSection(_activeFecha, newSeccion, loteria: _activeLoteria)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No puede navegar a secciones futuras."), backgroundColor: Colors.orange));
      return;
    }
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("sync_seccion", newSeccion);
    
    setState(() { _activeSeccion = newSeccion; });
    Alex().broadcastSectionSync(seccion: newSeccion, fecha: _activeFecha);
    _loadData();
  }

  Widget _buildEmptyState() => Center(child: Text("Sin listeros registrados", style: TextStyle(color: Colors.blue.shade100, fontWeight: FontWeight.bold)));

  Widget _buildListeroCard(Map<String, dynamic> listero) {
    String pin = listero['pin'];
    double ultimoSaldo = _listeroSaldos[pin] ?? 0.0;
    bool listeroDebe = ultimoSaldo >= 0;
    
    final parteHoy = _partesDeHoy[pin];
    final bool tieneActividad = parteHoy != null;
    final bool enviado = parteHoy?['publicado'] == 1;

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: BorderSide(color: Colors.blue.shade50)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: tieneActividad ? (enviado ? Colors.green.shade50 : Colors.orange.shade50) : Colors.blue.shade50, 
          child: Icon(Icons.person, color: tieneActividad ? (enviado ? Colors.green.shade800 : Colors.orange.shade800) : Colors.blue.shade800)
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(listero['nombre'], 
                style: TextStyle(color: Colors.blue.shade900, fontWeight: FontWeight.w900, fontSize: 14), // Reduced font size
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            if (tieneActividad)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(color: enviado ? Colors.green.shade700 : Colors.orange.shade700, borderRadius: BorderRadius.circular(4)),
                child: Text(enviado ? "ENVIADO" : "PENDIENTE", style: const TextStyle(color: Colors.white, fontSize: 6, fontWeight: FontWeight.bold)),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(color: Colors.blue.shade400, borderRadius: BorderRadius.circular(4)),
                child: const Text("SIN TIRO", style: TextStyle(color: Colors.white, fontSize: 6, fontWeight: FontWeight.bold)),
              ),
          ],
        ),
        subtitle: Text("PIN: $pin | PLAN: ${listero['plan']}", style: const TextStyle(color: Colors.black54, fontSize: 10, fontWeight: FontWeight.bold)),
        trailing: SizedBox(
          width: 80, // Fixed width for trailing to avoid competition
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text("SALDO TOTAL", style: TextStyle(color: Colors.grey, fontSize: 7, fontWeight: FontWeight.bold)),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text("\$${RecaudacionService.formatMoney(ultimoSaldo.abs())}", 
                  style: TextStyle(color: listeroDebe ? Colors.green.shade700 : Colors.red.shade700, fontWeight: FontWeight.w900, fontSize: 16)
                ),
              ),
            ],
          ),
        ),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DetallePartesListeroScreen(listero: listero))).then((_) => _loadData()),
      ),
    );
  }
}

class DetallePartesListeroScreen extends StatefulWidget {
  final Map<String, dynamic> listero;
  const DetallePartesListeroScreen({super.key, required this.listero});

  @override
  State<DetallePartesListeroScreen> createState() => _DetallePartesListeroScreenState();
}

class _DetallePartesListeroScreenState extends State<DetallePartesListeroScreen> {
  final DatabaseHelper _db = DatabaseHelper();
  List<Map<String, dynamic>> _partes = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPartes();
  }

  Future<void> _loadPartes() async {
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    final String listeroLoterias = widget.listero['loterias']?.toString() ?? "AMBAS";
    final res = await _db.getPartesByListero(widget.listero['pin'], bancoId: bancoId, loteria: listeroLoterias);
    setState(() { _partes = res; _isLoading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LoteriaIcon(loteria: widget.listero['loterias']?.toString() ?? widget.listero['loteria']?.toString() ?? 'FLORIDA', size: 34, width: 48, borderRadius: 8),
              const SizedBox(width: 8),
              Text(
                "PARTES: ${widget.listero['nombre']}",
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ), 
        backgroundColor: Colors.blue.shade800, 
        foregroundColor: Colors.white,
        actions: [
          const ConnectionIcon(),
        ],
      ),
      body: _isLoading 
        ? Center(child: CircularProgressIndicator(color: Colors.blue.shade800))
        : _partes.isEmpty
          ? const Center(child: Text("No hay partes registrados"))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _partes.length,
              itemBuilder: (context, index) => _buildParteCard(_partes[index], isOldest: index == _partes.length - 1),
            ),
    );
  }

  Widget _buildParteCard(Map<String, dynamic> p, {bool isOldest = false}) {
    double balanceDia = (p['total_dia'] as num).toDouble();
    double saldoFinal = (p['saldo_final'] as num).toDouble();
    String tiro = p['tiro'] ?? "--";
    String loteria = (p['loteria']?.toString() ?? 'FLORIDA').toUpperCase();
    String seccion = p['seccion']?.toString() ?? 'DIA';
    bool esBorrador = (p['publicado'] ?? 0) == 0;
    
    bool isGeorgia = loteria.contains("GEORGIA");
    Color cardBgColor = isGeorgia ? const Color(0xFFE65100) : const Color(0xFF0D47A1); // Naranja para Georgia, Azul para Florida
    
    // PERSPECTIVA BANCO: balance > 0 significa que el BANCO GANA (el listero debe)
    bool bancoGanaDia = balanceDia > 0;
    bool bancoGanaTotal = saldoFinal > 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: cardBgColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: esBorrador ? Colors.amberAccent : Colors.white38, width: 1.5),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.25), offset: const Offset(0, 6), blurRadius: 12),
        ],
      ),
      child: ExpansionTile(
        iconColor: Colors.white,
        collapsedIconColor: Colors.white70,
        title: Row(
          children: [
            LoteriaIcon(loteria: loteria, size: 18, width: 34, borderRadius: 4),
            const SizedBox(width: 8),
            Expanded(child: Text("${p['fecha']} | $loteria-$seccion", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13))),
            if (esBorrador) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: Colors.amber.shade400, borderRadius: BorderRadius.circular(4)), child: const Text("BORRADOR", style: TextStyle(color: Colors.black, fontSize: 8, fontWeight: FontWeight.w900))),
          ],
        ),
        subtitle: Text("Tiro Ganador: $tiro", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.white70)),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(bancoGanaTotal ? "GANA BANCO" : "DEBE BANCO", style: TextStyle(fontSize: 7, fontWeight: FontWeight.w900, color: bancoGanaTotal ? Colors.lightGreenAccent : Colors.amberAccent)),
            Text("\$${RecaudacionService.formatMoney(saldoFinal.abs())}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 18)),
          ],
        ),
        childrenPadding: const EdgeInsets.all(16),
        children: [
          if (bancoGanaDia)
            _smartSummary("BANCO GANA \$${RecaudacionService.formatMoney(balanceDia.abs())} EN ESTE DÍA", Colors.green)
          else if (balanceDia < 0)
            _smartSummary("BANCO PIERDE \$${RecaudacionService.formatMoney(balanceDia.abs())} EN ESTE DÍA", Colors.red)
          else
            _smartSummary("BALANCE SIN CAMBIOS", Colors.blueGrey),
          const SizedBox(height: 12),
          _buildLoteriaDrawRow(loteria, seccion, tiro, balanceDia, isBancoView: true),
          const SizedBox(height: 8),
          _infoRow("Fondo Anterior", p['fondo_anterior'], isEditable: true, onEdit: () => _editFondoAnterior(p), isLightText: true),
          const Divider(color: Colors.white24),
          _infoRow("Limpio Lista", p['limpio_lista'], isLightText: true),
          _infoRow("Premios Lista", p['premios_lista'], isLightText: true),
          _infoRow("Limpio Bote", p['limpio_bote'], isLightText: true),
          _infoRow("Premios Bote", p['premios_bote'], isLightText: true),
          const Divider(color: Colors.white24),
          _infoRow("UTILIDAD DEL DÍA", balanceDia.abs(), isBold: true, color: bancoGanaDia ? Colors.lightGreenAccent : Colors.amberAccent, isLightText: true),
          _infoRow("LIQUIDACIÓN (PAGO)", p['liquidacion'] ?? 0.0, isEditable: true, color: Colors.white70, onEdit: () => _editLiquidacion(p), isLightText: true),
          _infoRow("SALDO FINAL ACUMULADO", saldoFinal.abs(), isBold: true, color: bancoGanaTotal ? Colors.lightGreenAccent : Colors.amberAccent, fontSize: 16, isLightText: true),
        ],
      ),
    );
  }

  Widget _smartSummary(String msg, MaterialColor color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Text(msg, 
        textAlign: TextAlign.center,
        style: TextStyle(color: color[800], fontWeight: FontWeight.w900, fontSize: 10, letterSpacing: 0.5)
      ),
    );
  }

  void _editLiquidacion(Map<String, dynamic> parte) {
    final TextEditingController controller = TextEditingController(text: RecaudacionService.formatMoney((parte['liquidacion'] as num?)?.toDouble() ?? 0.0));
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text("REGISTRAR LIQUIDACIÓN", style: TextStyle(fontWeight: FontWeight.w900, color: Colors.blue.shade900)),
        content: TextField(
          controller: controller, 
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), 
          decoration: const InputDecoration(labelText: r"Monto Liquidado $", hintText: "Monto de pago o cobro", border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")), 
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade800, foregroundColor: Colors.white),
            onPressed: () async {
              final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
              final String lot = parte['loteria']?.toString() ?? "FLORIDA";
              double nuevaLiq = double.tryParse(controller.text.replaceAll(',', '.')) ?? 0.0;
              await _db.updateLiquidacionAndRecalculate(parte['listero_pin'], bancoId, parte['fecha'], parte['seccion'], nuevaLiq, loteria: lot);
              await Alex().syncDataToCloud(isDeepSync: true);
              Alex().broadcastSyncPulse(isDeep: true);
              TiroService().notifyNewTiro(null);
              if (ctx.mounted) Navigator.pop(ctx);
              _loadPartes();
            }, 
            child: const Text("GUARDAR")
          ),
        ],
      ),
    );
  }

  void _editFondoAnterior(Map<String, dynamic> parte) {
    final TextEditingController controller = TextEditingController(text: RecaudacionService.formatMoney((parte['fondo_anterior'] as num?)?.toDouble() ?? 0.0));
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("EDITAR FONDO ANTERIOR"),
        content: TextField(
          controller: controller, 
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), 
          decoration: const InputDecoration(labelText: r"Nuevo Fondo $", hintText: "Monto positivo o negativo"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")), 
          ElevatedButton(
            onPressed: () async {
              final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
              final String lot = parte['loteria']?.toString() ?? "FLORIDA";
              double nuevoFondo = double.tryParse(controller.text.replaceAll(',', '.')) ?? 0.0;
              await _db.updateFondoAndRecalculate(parte['listero_pin'], bancoId, parte['fecha'], parte['seccion'], nuevoFondo, loteria: lot);
              TiroService().notifyNewTiro(null);
              if (ctx.mounted) Navigator.pop(ctx);
              _loadPartes();
            }, 
            child: const Text("GUARDAR")
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, dynamic val, {bool isBold = false, Color? color, bool isEditable = false, double fontSize = 12, VoidCallback? onEdit, bool isLightText = false}) {
    double v = (val as num?)?.toDouble() ?? 0.0;
    Color defaultLabelColor = isLightText ? Colors.white70 : Colors.black87;
    Color defaultValueColor = isLightText ? Colors.white : (color ?? Colors.black87);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: Text(label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: defaultLabelColor), overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("\$${RecaudacionService.formatMoney(v)}", style: TextStyle(color: color ?? defaultValueColor, fontWeight: isBold ? FontWeight.w900 : FontWeight.bold, fontSize: fontSize)),
              if (isEditable) IconButton(icon: Icon(Icons.edit, size: 16, color: isLightText ? Colors.amberAccent : Colors.blue.shade800), onPressed: onEdit),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLoteriaDrawRow(String loteria, String seccion, String tiro, double balanceSec, {required bool isBancoView}) {
    bool gana = isBancoView ? (balanceSec > 0) : (balanceSec < 0);
    bool pierde = isBancoView ? (balanceSec < 0) : (balanceSec > 0);
    bool isGeorgia = loteria == 'GEORGIA';

    String labelDraw = "";
    if (isGeorgia) {
      if (seccion == 'MIDDAY' || seccion == 'DIA') {
        labelDraw = "Georgia-Mañana 🍑";
      } else if (seccion == 'EVENING' || seccion == 'TARDE') {
        labelDraw = "Georgia-Tarde 🍑";
      } else if (seccion == 'NIGHT' || seccion == 'NOCHE') {
        labelDraw = "Georgia-Noche 🍑";
      } else {
        labelDraw = "Georgia-$seccion 🍑";
      }
    } else {
      if (seccion == 'DIA' || seccion == 'MIDDAY') {
        labelDraw = "Florida-AM 🌴";
      } else if (seccion == 'NOCHE' || seccion == 'EVENING' || seccion == 'NIGHT') {
        labelDraw = "Florida-PM 🌴";
      } else {
        labelDraw = "Florida-$seccion 🌴";
      }
    }

    Color resultColor = gana ? Colors.green.shade800 : (pierde ? Colors.red.shade800 : Colors.blueGrey);
    String statusText = "";
    if (isBancoView) {
      statusText = gana ? "GANA BANCO" : (pierde ? "PIERDE BANCO" : "SIN MOVIMIENTO");
    } else {
      statusText = gana ? "GANA" : (pierde ? "PIERDE" : "SIN MOVIMIENTO");
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: resultColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    LoteriaIcon(loteria: loteria, size: 14, borderRadius: 2),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        labelDraw, 
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: isGeorgia ? Colors.orange.shade900 : Colors.blue.shade900),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text("Tiro Ganador: $tiro", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.black87)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: resultColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(color: resultColor, fontWeight: FontWeight.w900, fontSize: 9, letterSpacing: 0.5),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                "\$${RecaudacionService.formatMoney(balanceSec.abs())}",
                style: TextStyle(color: resultColor, fontWeight: FontWeight.w900, fontSize: 15),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
