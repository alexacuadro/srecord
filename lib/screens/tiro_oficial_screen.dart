import 'dart:async' as async;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/services/database_helper.dart';
import 'package:srecord/services/tiro_service.dart';
import 'package:srecord/services/recaudacion_service.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/core_network.dart';
import 'package:srecord/services/background_service.dart';
import 'package:srecord/services/notification_service.dart';
import 'package:srecord/widgets/loteria_icon.dart';

class TiroOficialScreen extends StatefulWidget {
  const TiroOficialScreen({super.key});
  @override
  State<TiroOficialScreen> createState() => _TiroOficialScreenState();
}

class _TiroOficialScreenState extends State<TiroOficialScreen> {
  final DatabaseHelper _db = DatabaseHelper();
  String _activeLoteria = "FLORIDA";
  String _enabledLoterias = "AMBAS";
  String _activeFecha = DateTime.now().toString().substring(0, 10);
  String _activeSeccion = "DIA";
  final TextEditingController _centenaController = TextEditingController();
  final TextEditingController _c1Controller = TextEditingController();
  final TextEditingController _c2Controller = TextEditingController();

  final FocusNode _centenaFocus = FocusNode();
  final FocusNode _c1Focus = FocusNode();
  final FocusNode _c2Focus = FocusNode();

  final Color primaryColor = Colors.blue.shade900;
  async.Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    print("[TIRO_SCREEN] >>> PANTALLA INICIALIZADA <<<");
    _loadStoredConfig();
    TiroService().version.addListener(_onTiroUpdate);
    _db.onSyncUpdate = _syncUpdateListener;
  }

  void _onTiroUpdate() {
    _loadResultado();
  }

  void _syncUpdateListener(int id) {
    if (!mounted) return;
    _debounceTimer?.cancel();
    _debounceTimer = async.Timer(const Duration(milliseconds: 300), () {
      if (mounted) _loadResultado();
    });
  }

  @override
  void dispose() {
    TiroService().version.removeListener(_onTiroUpdate);
    _db.removeSyncUpdate(_syncUpdateListener);
    _debounceTimer?.cancel();
    _centenaController.dispose();
    _c1Controller.dispose();
    _c2Controller.dispose();
    _centenaFocus.dispose();
    _c1Focus.dispose();
    _c2Focus.dispose();
    super.dispose();
  }

  Future<void> _loadStoredConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    _enabledLoterias = await Alex().getBankLoterias(bancoId);

    if (_enabledLoterias == "FLORIDA") {
      _activeLoteria = "FLORIDA";
    } else if (_enabledLoterias == "GEORGIA") {
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

    _loadResultado(force: true);
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
    _loadResultado(force: true);
  }

  Future<void> _loadResultado({bool force = false}) async {
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    final res = await _db.getResultado(_activeFecha, _activeSeccion, bancoId: bancoId, loteria: _activeLoteria);
    
    bool isEditing = _centenaFocus.hasFocus || _c1Focus.hasFocus || _c2Focus.hasFocus;

    if (force || !isEditing) {
      if (res != null) {
        _centenaController.text = res['n1'] ?? ""; 
        _c1Controller.text = res['n2'] ?? ""; 
        _c2Controller.text = res['n3'] ?? "";
      } else {
        _centenaController.clear(); _c1Controller.clear(); _c2Controller.clear();
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveTiro() async {
    print("[TIRO_SCREEN] !!! INICIANDO PUBLICACIÓN !!!");
    final n1 = _centenaController.text.trim();
    final n2 = _c1Controller.text.trim();
    final n3 = _c2Controller.text.trim();

    try {
      final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
      
      // 1. Detección de Conexión a Internet
      bool isOnline = CoreNetwork().isConnected;
      if (!isOnline) {
        if (mounted) {
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
                "⚠️ ATENCIÓN: Tu dispositivo no tiene conexión a internet. El tiro ganador se guardó localmente en el banco, pero NO PUDO SER ENVIADO a las listas. Conéctese a internet para enviar las notificaciones a sus listeros.",
                style: TextStyle(fontSize: 13),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("ENTENDIDO")),
              ],
            ),
          );
        }
        return;
      }

      // 2. Guardar resultado localmente
      await _db.saveResultado(_activeFecha, _activeSeccion, n1, n2, n3, bancoId: bancoId, loteria: _activeLoteria);
      
      // 3. Subir a la nube y emitir pulso de tiempo real para este banco
      await Alex().syncDataToCloud(isDeepSync: true);
      Alex().broadcastSyncPulse(isDeep: true);

      // 4. El primer dispositivo que recibe la notificación es el MISMO BANCO (Comprobación de Servicio)
      final String s1 = BackgroundService.mapToLargeSpheres(n1);
      final String s2 = BackgroundService.mapToLargeSpheres(n2);
      final String s3 = BackgroundService.mapToLargeSpheres(n3);

      final String bigTextStr = "🎰 TIRO GANADOR OFICIAL ($_activeLoteria - $_activeSeccion)\n"
          "-----------------------------------------\n"
          "🟡 CENTENA:   [ $s1 ]\n"
          "🔵 CORRIDO 1: [ $s2 ]\n"
          "🟠 CORRIDO 2: [ $s3 ]\n"
          "-----------------------------------------\n"
          "📅 FECHA: $_activeFecha";

      NotificationService().showNotification(
        id: 8888,
        title: "🎰 TIRO PUBLICADO CON ÉXITO ($_activeLoteria)",
        body: "Servicio Activo. 🟡 C: $s1 | 🔵 C1: $s2 | 🟠 C2: $s3",
        bigText: bigTextStr,
        payloadKey: "bank_tiro_${_activeLoteria}_${_activeFecha}_${_activeSeccion}_$n1$n2$n3",
      );
      
      final customLimites = await _db.getLimites(bancoId: bancoId, loteria: _activeLoteria);
      Map<String, String> tiro = {'n1': n1, 'n2': n2, 'n3': n3};
      
      List<String> listerosProcesados = await Alex().orchestrateTiroClosing(_activeFecha, _activeSeccion, tiro, customLimites, loteria: _activeLoteria);
      TiroService().refreshTiro(_activeFecha, _activeSeccion, loteria: _activeLoteria);
      
      if (mounted) {
        _showSummaryDialog(listerosProcesados);
        FocusScope.of(context).unfocus();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red));
    }
    _loadResultado(force: true);
  }

  void _showSummaryDialog(List<String> listeros) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 26),
            SizedBox(width: 10),
            Expanded(
              child: Text("VERIFICACIÓN DE ENVÍO DE TIRO", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Se confirmó la notificación lista por lista para este banco (${listeros.length} listas):", style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 12),
            Container(
              height: 200,
              width: double.maxFinite,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blueGrey.shade900.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.shade100),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: listeros.length,
                itemBuilder: (c, i) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.check_circle_outline, size: 16, color: Colors.green),
                  title: Text("Tiro enviado a: ${listeros[i]}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  trailing: const Text("ENTREGADO", style: TextStyle(color: Colors.green, fontSize: 9, fontWeight: FontWeight.w900)),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(8)),
              child: const Row(
                children: [
                  Icon(Icons.verified, color: Colors.green, size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text("Servicio de notificaciones activo y verificado en el banco.", style: TextStyle(color: Colors.green, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("ENTENDIDO", style: TextStyle(fontWeight: FontWeight.bold)))
        ],
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    final Color loteriaColor = _activeLoteria == "GEORGIA" ? Colors.orange.shade900 : Colors.blue.shade900;
    bool canPublish = _centenaController.text.length == 3 && 
                     _c1Controller.text.length == 2 && 
                     _c2Controller.text.length == 2;

    return Scaffold(
      appBar: AppBar(
        title: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LoteriaIcon(loteria: _activeLoteria, size: 20, borderRadius: 3),
              const SizedBox(width: 8),
              Text("RESULTADOS ($_activeLoteria)"),
            ],
          ),
        ),
        backgroundColor: loteriaColor,
        foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.calendar_today, size: 18), onPressed: _selectFecha),
        ],
      ),
      body: Column(
        children: [
          _buildFilterBar(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(25),
              child: Column(
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        LoteriaIcon(loteria: _activeLoteria, size: 24, borderRadius: 4),
                        const SizedBox(width: 8),
                        Text("TIRO GANADOR: $_activeLoteria - $_activeSeccion", style: TextStyle(fontWeight: FontWeight.w900, color: loteriaColor, fontSize: 15)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text("FECHA: $_activeFecha", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 30),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _winningBall("CENTENA", _centenaController, 3, _centenaFocus),
                        const SizedBox(width: 12),
                        _winningBall("CORRIDO 1", _c1Controller, 2, _c1Focus),
                        const SizedBox(width: 12),
                        _winningBall("CORRIDO 2", _c2Controller, 2, _c2Focus),
                      ],
                    ),
                  ),
                  const SizedBox(height: 25),
                  SizedBox(
                    width: double.infinity, height: 60,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: canPublish ? Colors.green.shade700 : Colors.grey.shade400, 
                        foregroundColor: Colors.white,
                        elevation: 5,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
                      ),
                      onPressed: canPublish ? _saveTiro : null,
                      icon: const Icon(Icons.publish_rounded),
                      label: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text("PUBLICAR RESULTADOS", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 1)),
                      ),
                    ),
                  ),
                  if (_centenaController.text.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity, height: 50,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.shade700, 
                          foregroundColor: Colors.white,
                          elevation: 3,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
                        ),
                        onPressed: _deleteTiro,
                        icon: const Icon(Icons.delete_forever),
                        label: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text("ELIMINAR TIRO GANADOR", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 1)),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteTiro() async {
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red),
            SizedBox(width: 8),
            Text("ELIMINAR TIRO", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
          ],
        ),
        content: Text("¿Está seguro de eliminar el tiro ganador de $_activeLoteria - $_activeSeccion para $_activeFecha?\n\nSe eliminarán los premios calculados y la lista volverá al estado previo."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("CANCELAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("SÍ, ELIMINAR"),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
      await Alex().deleteResultado(_activeFecha, _activeSeccion, bancoId: bancoId, loteria: _activeLoteria);
      _centenaController.clear();
      _c1Controller.clear();
      _c2Controller.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Tiro ganador eliminado correctamente."), backgroundColor: Colors.green));
      }
      _loadResultado(force: true);
    }
  }

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      color: Colors.blue.shade50,
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  if (_enabledLoterias == "FLORIDA")
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(color: primaryColor, borderRadius: BorderRadius.circular(15)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          LoteriaIcon(loteria: "FLORIDA", size: 14, borderRadius: 2),
                          SizedBox(width: 4),
                          Text("FL", style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    )
                  else if (_enabledLoterias == "GEORGIA")
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(color: primaryColor, borderRadius: BorderRadius.circular(15)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          LoteriaIcon(loteria: "GEORGIA", size: 14, borderRadius: 2),
                          SizedBox(width: 4),
                          Text("GA", style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    )
                  else
                    PopupMenuButton<String>(
                      icon: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(color: primaryColor, borderRadius: BorderRadius.circular(15)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LoteriaIcon(loteria: _activeLoteria, size: 14, borderRadius: 2),
                            const SizedBox(width: 4),
                            Text(
                              _activeLoteria == "GEORGIA" ? "GA" : "FL",
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      onSelected: (val) => _switchLoteria(val),
                      itemBuilder: (ctx) => [
                        PopupMenuItem(
                          value: "FLORIDA",
                          child: Row(
                            children: [
                              const LoteriaIcon(loteria: "FLORIDA", size: 18, borderRadius: 2),
                              const SizedBox(width: 8),
                              const Text("FLORIDA", style: TextStyle(fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: "GEORGIA",
                          child: Row(
                            children: [
                              const LoteriaIcon(loteria: "GEORGIA", size: 18, borderRadius: 2),
                              const SizedBox(width: 8),
                              const Text("GEORGIA", style: TextStyle(fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(width: 8),
                  PopupMenuButton<String>(
                    icon: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: _activeLoteria == "GEORGIA" ? Colors.orange.shade800 : primaryColor, 
                        borderRadius: BorderRadius.circular(15),
                        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 2, offset: Offset(0, 1))],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _activeLoteria == "GEORGIA" 
                              ? (_activeSeccion == "MIDDAY" ? Icons.wb_sunny : (_activeSeccion == "EVENING" ? Icons.wb_twilight : Icons.nightlight_round))
                              : (_activeSeccion == "NOCHE" ? Icons.nightlight_round : Icons.wb_sunny),
                            size: 14,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _activeLoteria == "GEORGIA" 
                              ? (_activeSeccion == "MIDDAY" ? "MAÑANA" : (_activeSeccion == "EVENING" ? "TARDE" : "NOCHE"))
                              : (_activeSeccion == "NOCHE" ? "NOCHE" : "DÍA"),
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: 2),
                          const Icon(Icons.arrow_drop_down, color: Colors.white, size: 16),
                        ],
                      ),
                    ),
                    tooltip: "Seleccionar Sección",
                    onSelected: (val) {
                      setState(() => _activeSeccion = val);
                      _loadResultado(force: true);
                    },
                    itemBuilder: (ctx) => _activeLoteria == "GEORGIA" ? [
                      PopupMenuItem(
                        value: "MIDDAY",
                        child: Row(
                          children: const [
                            Icon(Icons.wb_sunny, size: 16, color: Colors.orange),
                            SizedBox(width: 8),
                            Text("🌅 MAÑANA", style: TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: "EVENING",
                        child: Row(
                          children: const [
                            Icon(Icons.wb_twilight, size: 16, color: Colors.amber),
                            SizedBox(width: 8),
                            Text("☀️ TARDE", style: TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: "NIGHT",
                        child: Row(
                          children: const [
                            Icon(Icons.nightlight_round, size: 16, color: Colors.indigo),
                            SizedBox(width: 8),
                            Text("🌙 NOCHE", style: TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ] : [
                      PopupMenuItem(
                        value: "DIA",
                        child: Row(
                          children: const [
                            Icon(Icons.wb_sunny, size: 16, color: Colors.orange),
                            SizedBox(width: 8),
                            Text("🌅 DÍA", style: TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: "NOCHE",
                        child: Row(
                          children: const [
                            Icon(Icons.nightlight_round, size: 16, color: Colors.indigo),
                            SizedBox(width: 8),
                            Text("🌙 NOCHE", style: TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ],
                  )
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: _selectFecha,
            icon: const Icon(Icons.edit_calendar, size: 16),
            label: Text(_activeFecha, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          )
        ],
      ),
    );
  }

  Widget _seccionChip(String s, IconData icon) {
    bool isSel = _activeSeccion == s;
    String label = s;
    if (_activeLoteria == "GEORGIA") {
      if (s == "MIDDAY") label = "MAÑANA";
      if (s == "EVENING") label = "TARDE";
      if (s == "NIGHT") label = "NOCHE";
    }
    return ChoiceChip(
      label: Text(label),
      avatar: Icon(icon, size: 16, color: isSel ? Colors.white : Colors.blue),
      selected: isSel,
      selectedColor: primaryColor,
      labelStyle: TextStyle(color: isSel ? Colors.white : Colors.black, fontWeight: FontWeight.bold),
      onSelected: (val) {
        if (val) {
          setState(() => _activeSeccion = s);
          _loadResultado(force: true);
        }
      },
    );
  }

  Future<void> _selectFecha() async {
    DateTime? picked = await showDatePicker(
      context: context, 
      initialDate: DateTime.parse(_activeFecha), 
      firstDate: DateTime(2024), 
      lastDate: DateTime.now().add(const Duration(days: 365))
    );
    if (picked != null) {
      setState(() => _activeFecha = picked.toString().substring(0, 10));
      _loadResultado(force: true);
    }
  }

  Widget _winningBall(String label, TextEditingController c, int len, FocusNode f) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: primaryColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: primaryColor.withValues(alpha: 0.2)),
          ),
          child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: primaryColor, letterSpacing: 0.5)),
        ),
        const SizedBox(height: 12),
        Container(
          width: 90, height: 90,
          decoration: BoxDecoration(
            shape: BoxShape.circle, 
            gradient: RadialGradient(
              colors: [
                Colors.white,
                Colors.blue.shade50,
                Colors.blue.shade100,
              ],
              center: const Alignment(-0.35, -0.35),
              radius: 0.85,
            ),
            border: Border.all(color: primaryColor, width: 3.5),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 8)),
              BoxShadow(color: Colors.white.withValues(alpha: 0.8), blurRadius: 3, offset: const Offset(-2, -2)),
            ],
          ),
          child: Center(
            child: TextField(
              controller: c, focusNode: f, textAlign: TextAlign.center,
              keyboardType: TextInputType.number, maxLength: len,
              onChanged: (_) => setState(() {}),
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: primaryColor, fontFamily: 'monospace'),
              decoration: const InputDecoration(border: InputBorder.none, counterText: "", contentPadding: EdgeInsets.zero, isDense: true),
            ),
          ),
        ),
      ],
    );
  }
}
