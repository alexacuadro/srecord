import 'dart:convert';
import 'dart:async' as async;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/services/database_helper.dart';
import 'package:srecord/services/tiro_service.dart';
import 'package:srecord/services/recaudacion_service.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/screens/winners_detail_screen.dart';
import 'package:srecord/widgets/loteria_icon.dart';

class ColecturiaScreen extends StatefulWidget {
  const ColecturiaScreen({super.key});

  @override
  State<ColecturiaScreen> createState() => _ColecturiaScreenState();
}

class _ColecturiaScreenState extends State<ColecturiaScreen> {
  final DatabaseHelper _db = DatabaseHelper();
  List<Map<String, dynamic>> _listeros = [];
  Map<String, dynamic> _planes = {};
  List<Map<String, dynamic>> _limitesEspeciales = [];
  
  final Map<String, Map<String, dynamic>> _resumenLista = {};
  final Map<String, Map<String, dynamic>> _resumenBote = {};
  final Map<String, bool> _typingListeros = {};
  
  Map<String, double> _totalesLista = {"limpio": 0, "premios": 0, "balance": 0};
  Map<String, double> _totalesBote = {"limpio": 0, "premios": 0, "balance": 0};
  
  String _activeLoteria = "FLORIDA";
  String _enabledLoterias = "AMBAS";
  String _activeSeccion = "DIA";
  String _activeFecha = DateTime.now().toString().substring(0, 10);
  bool _isLoading = true;
  Color _regentColor = Colors.blue.shade800;
  Map<String, String>? _tiroActual;

  async.Timer? _debounceTimer;
  async.StreamSubscription? _typingSubscription;

  @override
  void initState() {
    super.initState();
    _loadInitialConfig();
    TiroService().version.addListener(_loadAllData);
    _db.onSyncUpdate = _syncUpdateListener;
    _typingSubscription = Alex().onTypingStatusReceived.listen((payload) {
      final pin = payload['pin'];
      final isTyping = payload['is_typing'] ?? false;
      if (mounted) {
        setState(() {
          _typingListeros[pin] = isTyping;
        });
      }
    });
  }

  void _syncUpdateListener(int id) {
    if (!mounted) return;
    
    // DEBOUNCE: Evitar refrescos excesivos
    _debounceTimer?.cancel();
    _debounceTimer = async.Timer(const Duration(milliseconds: 300), () {
      if (mounted) _loadAllData(isInitial: false);
    });
  }


  @override
  void dispose() {
    TiroService().version.removeListener(_loadAllData);
    _db.removeSyncUpdate(_syncUpdateListener);
    _typingSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadInitialConfig() async {
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

    await _loadAllData(isInitial: true);
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
    Alex().broadcastSectionSync(seccion: _activeSeccion, fecha: _activeFecha, loteria: _activeLoteria);
    await _loadAllData(isInitial: true);
  }

  Future<void> _loadAllData({bool isInitial = false}) async {
    if (!mounted) return;
    if (isInitial) setState(() { _isLoading = true; });
    
    final prefs = await SharedPreferences.getInstance();
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    final enabledLoterias = await Alex().getBankLoterias(bancoId);
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
      setState(() {
        _activeLoteria = savedLoteria;
        _activeFecha = savedFecha;
        _activeSeccion = savedSeccion;
      });
      await prefs.setString("sync_loteria", _activeLoteria);
      await prefs.setString("sync_seccion", _activeSeccion);
    }

    _regentColor = await Alex().getRegentColorObj();
    
    _planes = await _db.getPlanes(bancoId: bancoId, loteria: _activeLoteria);
    _limitesEspeciales = await _db.getLimites(bancoId: bancoId, loteria: _activeLoteria);

    try {
      var listeros = await _db.getListeros(bancoId: bancoId);
      debugPrint("[COLECTURIA] Listeros encontrados para $bancoId: ${listeros.length}");
      
      // FALLBACK: Si no hay listeros para este bancoId, buscar globales (Migración)
      if (listeros.isEmpty) {
        debugPrint("[COLECTURIA DEBUG] Banco $bancoId sin listeros. Buscando globales...");
        listeros = await _db.getListeros(bancoId: "UNKNOWN");
      }

      final Map<String, String>? tiro = await _db.getResultado(_activeFecha, _activeSeccion, bancoId: bancoId, loteria: _activeLoteria);
      _tiroActual = tiro;

      var allJugadas = await _db.getJugadasCompletas("", seccion: _activeSeccion, fecha: _activeFecha, bancoId: bancoId, loteria: _activeLoteria);
      
      // FALLBACK: Si no hay jugadas para este bancoId, buscar globales (datos antiguos)
      if (allJugadas.isEmpty) {
        debugPrint("[COLECTURIA] No hay jugadas para $bancoId. Buscando datos globales...");
        allJugadas = await _db.getJugadasCompletas("", seccion: _activeSeccion, fecha: _activeFecha, loteria: _activeLoteria);
      }

      debugPrint("[COLECTURIA] Jugadas finales a mostrar: ${allJugadas.length}");

      final Map<String, List<Map<String, dynamic>>> jugadasPorListero = {};
      final Set<String> processedUuuids = {};
      
      for (var j in allJugadas) {
        final uuid = j['uuid'] as String?;
        if (uuid != null && processedUuuids.contains(uuid)) continue;
        if (uuid != null) processedUuuids.add(uuid);

        final pin = (j['listero_pin'] as String).trim();
        jugadasPorListero.putIfAbsent(pin, () => []).add(j);
      }

      _totalesLista = {"limpio": 0, "premios": 0, "balance": 0};
      _totalesBote = {"limpio": 0, "premios": 0, "balance": 0};
      _resumenLista.clear();
      _resumenBote.clear();

      if (listeros.isNotEmpty) {
        _listeros = listeros;

        // BATCH QUERY: Cargar todos los partes oficiales de la sección en 1 sola consulta
        final partesList = await _db.getPartesByFechaSeccion(_activeFecha, _activeSeccion, bancoId: bancoId, loteria: _activeLoteria);
        final Map<String, Map<String, dynamic>> partesMap = {
          for (var p in partesList) (p['listero_pin']?.toString().trim() ?? ''): p
        };

        for (var listero in _listeros) {
          String pin = (listero["pin"] as String).trim();
          String planName = listero["plan"];
          Map<String, dynamic> plan = Map<String, dynamic>.from(_planes[planName] ?? {});

          final listeroJugadas = jugadasPorListero[pin] ?? [];
          final jl = listeroJugadas.where((j) => j['destino'] == 'LISTA').toList();
          final jb = listeroJugadas.where((j) => j['destino'] == 'BOTE').toList();

          // PRIORIDAD: Cargar cálculo oficial sólo si hay un tiro activo y el parte está publicado
          final parteOficial = (tiro != null) ? partesMap[pin] : null;
          Map<String, dynamic> metrics;
          
          if (parteOficial != null && parteOficial['publicado'] == 1) {
            metrics = Map<String, dynamic>.from(parteOficial);
            if (parteOficial['winners_json'] != null) {
              try {
                final decoded = json.decode(parteOficial['winners_json']);
                metrics['winners_lista'] = decoded['lista'] ?? [];
                metrics['winners_bote'] = decoded['bote'] ?? [];
              } catch (_) {}
            }
          } else {
            metrics = RecaudacionService.calculateParteMetrics(
              jugadasLista: jl, 
              jugadasBote: jb, 
              plan: plan, 
              tiro: tiro, 
              customLimites: _limitesEspeciales, 
              seccion: _activeSeccion
            );
          }

          _resumenLista[pin] = {
            "limpio": metrics['limpio_lista'],
            "premios": metrics['premios_lista'],
            "balance": metrics['limpio_lista']! - metrics['premios_lista']!,
            "winners": metrics['winners_lista'] ?? [] 
          };
          
          _resumenBote[pin] = {
            "limpio": metrics['limpio_bote'],
            "premios": metrics['premios_bote'],
            "balance": metrics['limpio_bote']! - metrics['premios_bote']!,
            "winners": metrics['winners_bote'] ?? []
          };

          _totalesLista["limpio"] = RecaudacionService.roundMoney(_totalesLista["limpio"]! + metrics['limpio_lista']!);
          _totalesLista["premios"] = RecaudacionService.roundMoney(_totalesLista["premios"]! + metrics['premios_lista']!);
          _totalesLista["balance"] = RecaudacionService.roundMoney(_totalesLista["balance"]! + (metrics['limpio_lista']! - metrics['premios_lista']!));

          _totalesBote["limpio"] = RecaudacionService.roundMoney(_totalesBote["limpio"]! + metrics['limpio_bote']!);
          _totalesBote["premios"] = RecaudacionService.roundMoney(_totalesBote["premios"]! + metrics['premios_bote']!);
          _totalesBote["balance"] = RecaudacionService.roundMoney(_totalesBote["balance"]! + (metrics['limpio_bote']! - metrics['premios_bote']!));
        }
      }
      if (mounted) setState(() { _isLoading = false; });
    } catch (e) {
      debugPrint("Error loading colecturia turbo data: $e");
      if (mounted) setState(() { _isLoading = false; });
    }
  }

  bool _isOnline(String? lastSeen) {
    if (lastSeen == null) return false;
    try {
      final dt = DateTime.parse(lastSeen);
      return DateTime.now().difference(dt).inMinutes < 5;
    } catch (_) { return false; }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildTiroBar(),
        _buildFilterBar(),
        if (!_isLoading) _buildSummaryStats(),
        Expanded(
          child: _isLoading 
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _listeros.length,
                  itemBuilder: (context, index) {
                    final l = _listeros[index];
                    final pin = l["pin"] ?? "---";
                    final rl = _resumenLista[pin] ?? {"limpio":0.0,"premios":0.0,"balance":0.0,"winners":[]};
                    final rb = _resumenBote[pin] ?? {"limpio":0.0,"premios":0.0,"balance":0.0,"winners":[]};
                    
                    double totLimpio = ((rl["limpio"] as num?)?.toDouble() ?? 0.0) + ((rb["limpio"] as num?)?.toDouble() ?? 0.0);
                    double totPremios = ((rl["premios"] as num?)?.toDouble() ?? 0.0) + ((rb["premios"] as num?)?.toDouble() ?? 0.0);
                    double balTotal = ((rl["balance"] as num?)?.toDouble() ?? 0.0) + ((rb["balance"] as num?)?.toDouble() ?? 0.0);
                    
                    final coverage = Alex().calculatePremioCoverage(totLimpio, totPremios);
                    final bool online = _isOnline(l['last_seen']);
                    final bool isTyping = _typingListeros[pin] ?? false;
                    final int syncCount = l['last_sync_count'] ?? 0;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: Colors.white, 
                        borderRadius: BorderRadius.circular(16), 
                        boxShadow: [
                          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 3)),
                        ],
                        border: Border.all(color: online ? Colors.green.shade300 : Colors.blue.shade50, width: online ? 1.5 : 1),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // CABECERA PRINCIPAL: LISTERO, ESTADOS Y BALANCES
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Stack(
                                  children: [
                                    CircleAvatar(
                                      radius: 18,
                                      backgroundColor: online ? Colors.green.shade50 : Colors.blue.shade50,
                                      child: Icon(Icons.person, size: 20, color: online ? Colors.green.shade800 : Colors.blue.shade800),
                                    ),
                                    if (online)
                                      Positioned(
                                        right: 0,
                                        bottom: 0,
                                        child: Container(
                                          width: 10,
                                          height: 10,
                                          decoration: BoxDecoration(
                                            color: Colors.green,
                                            shape: BoxShape.circle,
                                            border: Border.all(color: Colors.white, width: 1.5),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              l["nombre"] ?? "SIN NOMBRE", 
                                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Colors.blue.shade900), 
                                              overflow: TextOverflow.ellipsis
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                            decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(4)),
                                            child: Text("PIN: $pin", style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.grey.shade700)),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 3),
                                      Wrap(
                                        crossAxisAlignment: WrapCrossAlignment.center,
                                        spacing: 6,
                                        runSpacing: 2,
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: syncCount >= 300 ? Colors.green.shade100 : Colors.blue.shade50,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text("$syncCount jugadas", style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: syncCount >= 300 ? Colors.green.shade800 : Colors.blue.shade800)),
                                          ),
                                          if (isTyping)
                                            Text("• Anotando...", style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.green.shade700, fontStyle: FontStyle.italic)),
                                          if (totPremios > 0)
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: (coverage['color'] as Color).withValues(alpha: 0.12),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                coverage['completo'] ? "Cobertura OK" : "Cob: ${(coverage['porcentaje'] as num).round()}%",
                                                style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: coverage['color']),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      balTotal > 0 ? "GANA BANCO" : (balTotal < 0 ? "DEBE BANCO" : "BALANCE"), 
                                      style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: balTotal > 0 ? Colors.green.shade800 : (balTotal < 0 ? Colors.red.shade800 : Colors.grey))
                                    ),
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        "\$${RecaudacionService.formatMoney(balTotal.abs())}", 
                                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: balTotal > 0 ? Colors.green.shade700 : (balTotal < 0 ? Colors.red.shade700 : Colors.black87))
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  icon: Icon(Icons.visibility_outlined, color: Colors.blue.shade700, size: 20),
                                  onPressed: () => _mostrarVisorJugadas(l),
                                  tooltip: "Ver Jugadas",
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            const Divider(height: 1, color: Colors.black12),
                            const SizedBox(height: 10),
                            // TABLAS COMPACTAS DE LISTA Y BOTE
                            _compactDataRow("L", rl, Colors.teal.shade700),
                            const SizedBox(height: 6),
                            _compactDataRow("B", rb, Colors.orange.shade800),
                            if (totPremios > 0) 
                              Padding(
                                padding: const EdgeInsets.only(top: 10.0),
                                child: InkWell(
                                  onTap: () => _verGanadores(l, rl, rb),
                                  borderRadius: BorderRadius.circular(10),
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(vertical: 8),
                                    decoration: BoxDecoration(
                                      color: Colors.amber.shade50,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: Colors.amber.shade300),
                                    ),
                                    child: const Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.emoji_events_outlined, size: 16, color: Colors.amber),
                                        SizedBox(width: 8),
                                        Text("VER DETALLE DE PREMIOS", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.orange, letterSpacing: 0.5)),
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
                ),
        ),
        if (!_isLoading) _buildGeneralSummary(),
      ],
    );
  }

  Widget _buildSummaryStats() {
    int online = _listeros.where((l) => _isOnline(l['last_seen'])).length;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      color: _regentColor.withValues(alpha: 0.05),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _statItem("LISTAS", _listeros.length.toString(), Colors.blueGrey),
          _statItem("ONLINE", online.toString(), Colors.green),
          _statItem("OFFLINE", (_listeros.length - online).toString(), Colors.redAccent),
        ],
      ),
    );
  }

  Widget _statItem(String label, String val, Color color) {
    return Column(
      children: [
        Text(val, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: color)),
        Text(label, style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.grey)),
      ],
    );
  }

  Widget _compactDataRow(String label, Map<String, dynamic> data, Color color) {
    double limpio = (data["limpio"] as num?)?.toDouble() ?? 0.0;
    double premios = (data["premios"] as num?)?.toDouble() ?? 0.0;
    double bal = (data["balance"] as num?)?.toDouble() ?? 0.0;
    bool bancoGana = bal > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
            child: Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.white)),
          ),
          const SizedBox(width: 12),
          Expanded(child: _miniDataText("LIMPIO", limpio)),
          Expanded(child: _miniDataText("PREMIOS", premios)),
          Expanded(child: _miniDataText(bancoGana ? "GANA" : "DEBE", bal.abs(), color: bancoGana ? Colors.green.shade700 : Colors.red.shade700)),
        ],
      ),
    );
  }

  Widget _miniDataText(String label, double val, {Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 8, fontWeight: FontWeight.w900)),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text("\$${RecaudacionService.formatMoney(val)}", 
            style: TextStyle(color: color ?? Colors.blue.shade900, fontSize: 13, fontWeight: FontWeight.w900)
          ),
        ),
      ],
    );
  }

  Future<void> _deleteCurrentTiro() async {
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("ELIMINAR TIRO"),
        content: Text("¿Desea eliminar el tiro oficial de $_activeFecha ($_activeSeccion)? Se recalcularán los premios."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("CANCELAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true), 
            child: const Text("ELIMINAR")
          )
        ],
      )
    );

    if (confirm == true) {
      final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
      await _db.deleteResultado(_activeFecha, _activeSeccion, bancoId: bancoId, loteria: _activeLoteria);
      Alex().syncDataToCloud();
      TiroService().notifyNewTiro(null);
      _loadAllData();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Tiro eliminado correctamente"), backgroundColor: Colors.green));
    }
  }

  void _verGanadores(Map<String, dynamic> l, Map<String, dynamic> rl, Map<String, dynamic> rb) {
    final List<dynamic> winnersL = rl['winners'] ?? [];
    final List<dynamic> winnersB = rb['winners'] ?? [];
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WinnersDetailScreen(
          listeroNombre: l['nombre'],
          seccion: _activeSeccion,
          fecha: _activeFecha,
          loteria: _activeLoteria,
          winners: [...winnersL, ...winnersB],
          regentColor: _regentColor,
        ),
      ),
    );
  }

  Widget _buildTiroBar() {
    if (_tiroActual == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF0277BD),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))],
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            LoteriaIcon(loteria: _activeLoteria, size: 16, borderRadius: 3),
            const SizedBox(width: 6),
            Text("TIRO OFICIAL ($_activeLoteria):", style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
            const SizedBox(width: 10),
            _tiroBadge(_tiroActual!['n1']!, isLarge: true),
            const SizedBox(width: 10),
            _tiroBadge(_tiroActual!['n2']!),
            const SizedBox(width: 6),
            _tiroBadge(_tiroActual!['n3']!, isLast: true),
            const SizedBox(width: 15),
            IconButton(
              onPressed: _deleteCurrentTiro,
              icon: const Icon(Icons.delete_forever, color: Colors.white70, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip: "Eliminar Tiro",
            )
          ],
        ),
      ),
    );
  }

  Widget _tiroBadge(String n, {bool isLarge = false, bool isLast = false}) => Container(
    width: isLarge ? 44 : 34,
    height: isLarge ? 44 : 34,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        colors: [
          Colors.white,
          isLarge ? Colors.red.shade100 : (isLast ? Colors.amber.shade100 : Colors.blue.shade50),
        ],
        center: const Alignment(-0.3, -0.3),
        radius: 0.8,
      ),
      border: Border.all(color: _regentColor, width: 2),
      boxShadow: [
        BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: isLarge ? 6 : 4, offset: const Offset(0, 3)),
        BoxShadow(color: Colors.white.withValues(alpha: 0.8), blurRadius: 2, offset: const Offset(-1, -1)),
      ],
    ),
    child: Center(
      child: Text(n, 
        style: TextStyle(
          fontSize: isLarge ? 16 : 13, 
          fontWeight: FontWeight.w900, 
          color: isLarge ? Colors.red.shade800 : (isLast ? Colors.amber.shade900 : Colors.blue.shade900), 
          fontFamily: 'monospace',
        )
      ),
    ),
  );

  Widget _buildFilterBar() {
    bool isGeorgia = _activeLoteria == "GEORGIA";
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isGeorgia ? Colors.orange.shade50 : Colors.blue.shade50,
        border: Border(bottom: BorderSide(color: isGeorgia ? Colors.orange.shade200 : Colors.blue.shade200))
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  if (_enabledLoterias == "FLORIDA")
                    LoteriaBadge(loteria: "FLORIDA", isSelected: true)
                  else if (_enabledLoterias == "GEORGIA")
                    LoteriaBadge(loteria: "GEORGIA", isSelected: true)
                  else
                    PopupMenuButton<String>(
                      icon: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: Colors.blue.shade800, borderRadius: BorderRadius.circular(15)),
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
                  const SizedBox(width: 4),
                  PopupMenuButton<String>(
                    icon: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: isGeorgia ? Colors.orange.shade800 : Colors.blue.shade800, 
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 2, offset: Offset(0, 1))],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isGeorgia 
                              ? (_activeSeccion == "MIDDAY" ? Icons.wb_sunny : (_activeSeccion == "EVENING" ? Icons.wb_twilight : Icons.nightlight_round))
                              : (_activeSeccion == "NOCHE" ? Icons.nightlight_round : Icons.wb_sunny),
                            size: 14,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isGeorgia 
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
                    onSelected: (val) => _switchSeccion(val),
                    itemBuilder: (ctx) => isGeorgia ? [
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
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _selectFecha,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: isGeorgia ? Colors.orange.shade200 : Colors.blue.shade200)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.calendar_today, size: 13, color: isGeorgia ? Colors.orange.shade800 : Colors.blue.shade800), 
                  const SizedBox(width: 6), 
                  Text(_activeFecha, style: TextStyle(fontWeight: FontWeight.w900, color: isGeorgia ? Colors.orange.shade900 : Colors.blue.shade900, fontSize: 12))
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _seccionChip(String s, IconData icon, Color color) {
    bool active = _activeSeccion == s;
    String displayLabel = s;
    if (_activeLoteria == "GEORGIA") {
      if (s == "MIDDAY") displayLabel = "MAÑANA";
      if (s == "EVENING") displayLabel = "TARDE";
      if (s == "NIGHT") displayLabel = "NOCHE";
    }
    return GestureDetector(
      onTap: () {
         _switchSeccion(s);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? color : Colors.white, 
          borderRadius: BorderRadius.circular(20), 
          border: Border.all(color: active ? color : Colors.grey.shade300),
        ),
        child: Row(children: [Icon(icon, size: 14, color: active ? Colors.white : Colors.grey), const SizedBox(width: 8), Text(displayLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: active ? Colors.white : Colors.grey))]),
      ),
    );
  }

  void _switchSeccion(String s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("sync_seccion", s);
    setState(() { _activeSeccion = s; });
    
    // Notificar a dispositivos espejo
    Alex().broadcastSectionSync(seccion: s, fecha: _activeFecha, loteria: _activeLoteria);
    
    await _loadAllData(isInitial: true);
  }

  Future<void> _selectFecha() async {
    DateTime? picked = await showDatePicker(context: context, initialDate: DateTime.parse(_activeFecha), firstDate: DateTime(2024), lastDate: DateTime(2101));
    if (picked != null) {
      final newFecha = picked.toString().substring(0, 10);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("sync_fecha", newFecha);
      setState(() { _activeFecha = newFecha; });
      
      // Notificar a dispositivos espejo
      Alex().broadcastSectionSync(seccion: _activeSeccion, fecha: newFecha, loteria: _activeLoteria);
      
      await _loadAllData(isInitial: true);
    }
  }

  Widget _buildGeneralSummary() {
    double balTotal = _totalesLista["balance"]! + _totalesBote["balance"]!;
    bool bancoGana = balTotal > 0;
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: bancoGana ? Colors.green.shade50 : Colors.red.shade50, 
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)), 
        border: Border(top: BorderSide(color: bancoGana ? Colors.green.shade200 : Colors.red.shade200, width: 1.5))
      ),
      child: SafeArea(
        top: false,
        child: _summaryRowHorizontal("TOTAL", {
          "limpio": _totalesLista["limpio"]! + _totalesBote["limpio"]!,
          "premios": _totalesLista["premios"]! + _totalesBote["premios"]!,
          "balance": balTotal,
        }),
      ),
    );
  }

  Widget _summaryRowHorizontal(String title, Map<String, double> data) {
    double bal = data["balance"]!;
    bool bancoGana = bal > 0;
    final color = bancoGana ? Colors.green.shade800 : Colors.red.shade800;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _miniDataItem("LIMPIO", data["limpio"]!),
        Container(width: 1, height: 26, color: Colors.black12),
        _miniDataItem("PREMIO", data["premios"]!),
        Container(width: 1, height: 26, color: Colors.black12),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              bancoGana ? "GANA BANCO" : (bal < 0 ? "DEBE BANCO" : "BALANCE"),
              style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 0.5),
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                "\$${RecaudacionService.formatMoney(bal.abs())}",
                style: TextStyle(color: color, fontSize: 17, fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _miniDataItem(String label, double val) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(color: Colors.blueGrey, fontSize: 9, fontWeight: FontWeight.w900)),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            "\$${RecaudacionService.formatMoney(val)}",
            style: TextStyle(color: Colors.blue.shade900, fontSize: 14, fontWeight: FontWeight.w900),
          ),
        ),
      ],
    );
  }

  void _mostrarVisorJugadas(Map<String, dynamic> listero) {
    String visorDestino = "LISTA";

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(25))),
      builder: (context) => StatefulBuilder(
        builder: (context, setVisorState) => DraggableScrollableSheet(
          initialChildSize: 0.9,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) => Column(
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                decoration: BoxDecoration(
                  color: visorDestino == "LISTA" ? Colors.blue.shade800 : Colors.red.shade700,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(25)),
                ),
                child: Column(
                  children: [
                    Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white38, borderRadius: BorderRadius.circular(2))),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      listero['nombre'],
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4)),
                                    child: Text("PIN: ${listero['pin']}", style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  LoteriaIcon(loteria: _activeLoteria, size: 16, borderRadius: 3),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      "$_activeLoteria | $_activeSeccion | $_activeFecha",
                                      style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          children: [
                            _visorDestinoBtn("LISTA", visorDestino == "LISTA", () => setVisorState(() => visorDestino = "LISTA")),
                            const SizedBox(width: 8),
                            _visorDestinoBtn("BOTE", visorDestino == "BOTE", () => setVisorState(() => visorDestino = "BOTE")),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 15),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                color: visorDestino == "LISTA" ? Colors.lightBlue.shade50 : Colors.red.shade50,
                child: Row(children: [
                  _visorHeaderCell('BOLA', 18, visorDestino),
                  _visorSeparator(visorDestino),
                  _visorHeaderCell('PARLE', 11, visorDestino),
                  _visorSeparator(visorDestino),
                  _visorHeaderCell('CENTENA', 11, visorDestino)
                ]),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _visorHistoryCol(listero['pin'], "BOLA", visorDestino, 18, listero['plan']),
                    _visorSeparator(visorDestino, isFull: true),
                    _visorHistoryCol(listero['pin'], "PARLE", visorDestino, 11, listero['plan']),
                    _visorSeparator(visorDestino, isFull: true),
                    _visorHistoryCol(listero['pin'], "CENTENA", visorDestino, 11, listero['plan']),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _visorDestinoBtn(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(label, style: TextStyle(color: active ? Colors.black : Colors.white, fontWeight: FontWeight.w900, fontSize: 10)),
      ),
    );
  }

  Widget _visorHeaderCell(String l, int f, String dest) => Expanded(flex: f, child: Text(l, textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: dest == "LISTA" ? Colors.blue.shade800 : Colors.red.shade800)));

  Widget _visorSeparator(String dest, {bool isFull = false}) => Container(width: 1.5, height: isFull ? double.infinity : 15, color: (dest == "LISTA" ? Colors.lightBlue : Colors.red).withValues(alpha: isFull ? 0.2 : 0.5));

  Widget _visorHistoryCol(String pin, String tipo, String dest, int f, String planName) {
    return LiveVisorColumn(
      pin: pin,
      tipo: tipo,
      dest: dest,
      flex: f,
      activeSeccion: _activeSeccion,
      activeFecha: _activeFecha,
      activeLoteria: _activeLoteria,
      planes: _planes,
      planName: planName,
      tiroActual: _tiroActual,
      limitesEspeciales: _limitesEspeciales,
    );
  }
}

class LiveVisorColumn extends StatefulWidget {
  final String pin;
  final String tipo;
  final String dest;
  final int flex;
  final String activeSeccion;
  final String activeFecha;
  final String activeLoteria;
  final Map<String, dynamic> planes;
  final String planName;
  final Map<String, String>? tiroActual;
  final List<Map<String, dynamic>> limitesEspeciales;

  const LiveVisorColumn({
    super.key,
    required this.pin,
    required this.tipo,
    required this.dest,
    required this.flex,
    required this.activeSeccion,
    required this.activeFecha,
    required this.activeLoteria,
    required this.planes,
    required this.planName,
    this.tiroActual,
    required this.limitesEspeciales,
  });

  @override
  State<LiveVisorColumn> createState() => _LiveVisorColumnState();
}

class _LiveVisorColumnState extends State<LiveVisorColumn> {
  List<Map<String, dynamic>> _list = [];
  bool _loading = true;
  late async.StreamSubscription<Map<String, dynamic>> _subscription;
  final Map<int, double> _itemPrizes = {};

  @override
  void initState() {
    super.initState();
    _loadInitial();
    DatabaseHelper().onSyncUpdate = _syncUpdateListener;
    TiroService().version.addListener(_onTiroUpdate);
    _subscription = Alex().onLiveBetReceived.listen((bet) {
      final betLoteria = (bet['loteria']?.toString() ?? 'FLORIDA').trim().toUpperCase();
      if (mounted &&
          bet['listero_pin'] == widget.pin &&
          bet['tipo'] == widget.tipo &&
          bet['destino'] != null && 
          bet['destino'].toString().trim().toUpperCase() == widget.dest.trim().toUpperCase() &&
          bet['seccion'] == widget.activeSeccion &&
          bet['fecha'] == widget.activeFecha &&
          betLoteria == widget.activeLoteria.trim().toUpperCase()) {
        
        setState(() {
          final exists = _list.any((j) => j['uuid'] == bet['uuid']);
          if (!exists) {
            _list.insert(0, bet);
          } else {
            final idx = _list.indexWhere((j) => j['uuid'] == bet['uuid']);
            _list[idx] = bet;
          }
        });
      }
    });
  }

  void _syncUpdateListener(int id) {
    if (mounted) _loadInitial();
  }

  void _onTiroUpdate() {
    if (mounted) {
      setState(() {
        _calculatePrizes();
      });
    }
  }

  @override
  void didUpdateWidget(LiveVisorColumn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dest != widget.dest || 
        oldWidget.pin != widget.pin || 
        oldWidget.activeSeccion != widget.activeSeccion || 
        oldWidget.activeFecha != widget.activeFecha ||
        oldWidget.activeLoteria != widget.activeLoteria) {
      setState(() {
        _list = [];
        _loading = true;
      });
      _loadInitial();
    } else if (oldWidget.tiroActual != widget.tiroActual) {
      setState(() {
        _calculatePrizes();
      });
    }
  }

  @override
  void dispose() {
    DatabaseHelper().removeSyncUpdate(_syncUpdateListener);
    TiroService().version.removeListener(_onTiroUpdate);
    _subscription.cancel();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    var data = await DatabaseHelper().getJugadas(
      widget.pin, 
      widget.tipo, 
      destino: widget.dest, 
      seccion: widget.activeSeccion, 
      fecha: widget.activeFecha, 
      bancoId: bancoId,
      loteria: widget.activeLoteria
    );

    // FALLBACK
    if (data.isEmpty && widget.pin.isNotEmpty) {
      data = await DatabaseHelper().getJugadas(
        widget.pin, 
        widget.tipo, 
        destino: widget.dest, 
        seccion: widget.activeSeccion, 
        fecha: widget.activeFecha,
        loteria: widget.activeLoteria
      );
    }

    if (mounted) {
      setState(() {
        _list = List<Map<String, dynamic>>.from(data).reversed.toList();
        _calculatePrizes();
        _loading = false;
      });
    }
  }

  Future<void> _calculatePrizes() async {
    _itemPrizes.clear();
    if (widget.tiroActual == null) return;
    
    final Map<String, dynamic> plan = Map<String, dynamic>.from(widget.planes[widget.planName] ?? {});
    
    // Sort by ID to match aggregate order
    final sortedList = List<Map<String, dynamic>>.from(_list)..sort((a, b) => (a['id'] ?? 0).compareTo(b['id'] ?? 0));

    double? limpioTotal;
    if (widget.dest == 'LISTA') {
      final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
      var allJugadas = await DatabaseHelper().getJugadas(
        widget.pin, 
        "", 
        destino: 'LISTA', 
        seccion: widget.activeSeccion, 
        fecha: widget.activeFecha, 
        bancoId: bancoId,
        loteria: widget.activeLoteria
      );
      if (allJugadas.isEmpty && widget.pin.isNotEmpty) {
        allJugadas = await DatabaseHelper().getJugadas(
          widget.pin, 
          "", 
          destino: 'LISTA', 
          seccion: widget.activeSeccion, 
          fecha: widget.activeFecha,
          loteria: widget.activeLoteria
        );
      }
      if (allJugadas.isEmpty) {
        allJugadas = sortedList;
      }
      Map<String, double> brutosL = {
        "BOLA": RecaudacionService.calculateBruto(allJugadas, "BOLA"),
        "PARLE": RecaudacionService.calculateBruto(allJugadas, "PARLE"),
        "CENTENA": RecaudacionService.calculateBruto(allJugadas, "CENTENA"),
      };
      limpioTotal = RecaudacionService.calculateLimpio(brutosL, plan, 'LISTA');
    }

    Map<String, double> allowanceUsed = {};
    for (var j in sortedList) {
       double p = RecaudacionService.calculatePremio(
         j['tipo'], 
         j['valor'], 
         widget.tiroActual!, 
         plan, 
         widget.dest, 
         customLimites: widget.limitesEspeciales, 
         seccion: widget.activeSeccion,
         limpioTotal: limpioTotal,
         allowanceUsed: allowanceUsed
       );
       if (j['id'] != null) {
         _itemPrizes[j['id']] = p;
       }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Expanded(child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
    
    return Expanded(
      flex: widget.flex,
      child: ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: _list.length,
        itemBuilder: (ctx, idx) {
          final jugada = _list[idx];
          final id = jugada['id'] as int?;
          final it = jugada['valor'] as String;
          bool isWinner = id != null && (_itemPrizes[id] ?? 0) > 0;
          
          final statusColor = _getSyncStatusColor(jugada);
          final isInvalid = !RecaudacionService.isJugadaValida(jugada);

          int p = it.indexOf('(');
          String nums = p != -1 ? it.substring(0, p) : it;
          String money = p != -1 ? it.substring(p) : '';

          return Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            decoration: BoxDecoration(
              color: isWinner ? Colors.green.withValues(alpha: 0.1) : Colors.transparent, 
              border: Border(bottom: BorderSide(color: isWinner ? Colors.green.withValues(alpha: 0.3) : Colors.blue.shade100, width: 1.2))
            ),
            child: _jugadaVerticalDisplay(
              nums,
              money,
              TextStyle(
                fontSize: widget.tipo == "BOLA" ? 14 : 12,
                fontWeight: FontWeight.bold,
                decoration: isInvalid ? TextDecoration.lineThrough : null,
                color: isWinner ? Colors.green.shade800 : statusColor,
              ),
            ),
          );
        },
      ),
    );
  }

  Color _getSyncStatusColor(Map<String, dynamic> j) {
    if (j['sync'] == 0) return Colors.green.shade700; // EN NUBE
    final String lot = j['loteria']?.toString() ?? widget.activeLoteria;
    if (RecaudacionService.isPastGracePeriod(j['seccion'], j['fecha'], loteria: lot)) return Colors.red.shade700; // FALLO
    return Colors.orange.shade800; // LOCAL
  }

  Widget _jugadaVerticalDisplay(String nums, String money, TextStyle baseStyle) {
    List<String> rawNumbers = nums.split('-').where((s) => s.trim().isNotEmpty).toList();
    
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: rawNumbers.map((n) => Text(n.trim(), style: baseStyle)).toList(),
        ),
        if (rawNumbers.length > 1) ...[
          const SizedBox(width: 2),
          SizedBox(
            width: 8,
            child: FittedBox(
              fit: BoxFit.fill,
              child: Text('}', style: TextStyle(color: baseStyle.color?.withValues(alpha: 0.5) ?? Colors.grey, fontWeight: FontWeight.w100)),
            ),
          ),
        ],
        const SizedBox(width: 4),
        Expanded(
          child: Text.rich(
            TextSpan(children: _richTextSpans(money, baseStyle.copyWith(fontSize: (baseStyle.fontSize ?? 12) - 1, fontWeight: FontWeight.normal))),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  List<TextSpan> _richTextSpans(String text, TextStyle baseStyle) {
    if (!text.contains('(X)')) return [TextSpan(text: text, style: baseStyle)];
    List<TextSpan> spans = []; List<String> parts = text.split('(X)');
    for (int i = 0; i < parts.length; i++) {
      if (parts[i].isNotEmpty) spans.add(TextSpan(text: parts[i], style: baseStyle));
      if (i < parts.length - 1) {
        spans.add(TextSpan(text: '(', style: baseStyle));
        spans.add(TextSpan(text: 'X', style: baseStyle.copyWith(color: Colors.red)));
        spans.add(TextSpan(text: ')', style: baseStyle));
      }
    }
    return spans;
  }
}
