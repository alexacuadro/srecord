import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/database_helper.dart';
import 'package:srecord/services/recaudacion_service.dart';
import 'package:srecord/widgets/loteria_icon.dart';

class NumerosMasJugadosScreen extends StatefulWidget {
  const NumerosMasJugadosScreen({super.key});

  @override
  State<NumerosMasJugadosScreen> createState() => _NumerosMasJugadosScreenState();
}

class _NumerosMasJugadosScreenState extends State<NumerosMasJugadosScreen> with SingleTickerProviderStateMixin {
  final DatabaseHelper _db = DatabaseHelper();
  String _activeLoteria = "FLORIDA";
  String _enabledLoterias = "AMBAS";
  String _activeFecha = DateTime.now().toString().substring(0, 10);
  String _activeSeccion = "DIA";
  bool _isLoading = true;
  late TabController _tabController;

  Map<String, Map<String, Map<String, double>>> _bolaStats = {};
  Map<String, Map<String, double>> _parleStats = {};
  Map<String, Map<String, double>> _centenaStats = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadInitialConfig();
    DatabaseHelper().onSyncUpdate = _syncUpdateListener;
  }

  void _syncUpdateListener(int id) {
    if (mounted) _loadStats();
  }

  @override
  void dispose() { 
    DatabaseHelper().removeSyncUpdate(_syncUpdateListener);
    _tabController.dispose(); 
    super.dispose(); 
  }

  Future<void> _loadInitialConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final bancoId = await Alex().getActiveBancoId();
    _enabledLoterias = await Alex().getBankLoterias(bancoId);

    if (_enabledLoterias == "FLORIDA") {
      _activeLoteria = "FLORIDA";
    } else if (_enabledLoterias == "GEORGIA") {
      _activeLoteria = "GEORGIA";
    } else {
      _activeLoteria = prefs.getString("sync_loteria") ?? "FLORIDA";
    }

    final openData = RecaudacionService.getOpenSeccionAndFecha(loteria: _activeLoteria);
    String rawSeccion = prefs.getString("sync_seccion") ?? openData["seccion"]!;
    setState(() {
      _activeFecha = prefs.getString("sync_fecha") ?? openData["fecha"]!;
      _activeSeccion = RecaudacionService.ensureValidSeccion(rawSeccion, _activeLoteria);
    });
    _loadStats();
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
    _loadStats();
  }

  Future<void> _loadStats() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    // BANCO ESPEJO: Recargar seccion/fecha por si cambió remotamente
    final prefs = await SharedPreferences.getInstance();
    final bancoId = await Alex().getActiveBancoId();
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
    }

    final db = await _db.database;
    final List<Map<String, dynamic>> allJugadas = await db.query('jugadas', 
      where: "fecha = ? AND seccion = ? AND banco_id = ? AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))", 
      whereArgs: [_activeFecha, _activeSeccion, bancoId, _activeLoteria, _activeLoteria]
    );

    Map<String, Map<String, Map<String, double>>> bTemp = {};
    Map<String, Map<String, double>> pTemp = {};
    Map<String, Map<String, double>> cTemp = {};

    for (var j in allJugadas) {
      String tipo = j['tipo'], valor = j['valor'], destino = j['destino'] ?? 'LISTA', numPart = valor.split('(').first.trim();
      if (tipo == "BOLA") {
        List<double> ams = RecaudacionService.extractBolaAmounts(valor);
        bTemp.putIfAbsent(numPart, () => {"LISTA": {"f": 0.0, "c": 0.0}, "BOTE": {"f": 0.0, "c": 0.0}});
        bTemp[numPart]![destino]!["f"] = bTemp[numPart]![destino]!["f"]! + ams[0];
        bTemp[numPart]![destino]!["c"] = bTemp[numPart]![destino]!["c"]! + ams[1];
      } else if (tipo == "PARLE") {
        double money = RecaudacionService.extractMoney(valor);
        List<String> nums = numPart.split('-').map((s) => s.trim()).toList();
        if (nums.length >= 2) {
          for (int i = 0; i < nums.length; i++) {
            for (int k = i + 1; k < nums.length; k++) {
              String pair = ([nums[i], nums[k]]..sort()).join('-');
              pTemp.putIfAbsent(pair, () => {"LISTA": 0, "BOTE": 0});
              pTemp[pair]![destino] = pTemp[pair]![destino]! + money;
            }
          }
        }
      } else if (tipo == "CENTENA") {
        double money = RecaudacionService.extractMoney(valor);
        cTemp.putIfAbsent(numPart, () => {"LISTA": 0, "BOTE": 0});
        cTemp[numPart]![destino] = cTemp[numPart]![destino]! + money;
      }
    }
    setState(() { _bolaStats = bTemp; _parleStats = pTemp; _centenaStats = cTemp; _isLoading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _buildFilterBar(),
          TabBar(
            controller: _tabController,
            indicatorColor: Colors.blue.shade800,
            labelColor: Colors.blue.shade900,
            unselectedLabelColor: Colors.grey,
            labelStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
            tabs: const [Tab(text: "BOLAS"), Tab(text: "PARLES"), Tab(text: "CENTENAS")],
          ),
          Expanded(
            child: _isLoading 
              ? Center(child: CircularProgressIndicator(color: Colors.blue.shade800))
              : TabBarView(controller: _tabController, children: [_buildBolasStatsList(), _buildSimpleStatsList(_parleStats, "PARLE"), _buildSimpleStatsList(_centenaStats, "CENTENA")]),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    bool isGeorgia = _activeLoteria == "GEORGIA";
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      color: isGeorgia ? Colors.orange.shade50 : Colors.blue.shade50,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onTap: _selectFecha,
            child: Row(children: [Icon(Icons.calendar_month, size: 16, color: isGeorgia ? Colors.orange.shade800 : Colors.blue.shade800), const SizedBox(width: 6), Text(_activeFecha, style: TextStyle(fontWeight: FontWeight.w900, color: isGeorgia ? Colors.orange.shade900 : Colors.blue.shade900, fontSize: 13))]),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
              children: [
                if (_enabledLoterias == "FLORIDA")
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.blue.shade900, borderRadius: BorderRadius.circular(15)),
                    child: const Text("FL 🌴", style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                  )
                else if (_enabledLoterias == "GEORGIA")
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.blue.shade900, borderRadius: BorderRadius.circular(15)),
                    child: const Text("GA 🍑", style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                  )
                else
                  PopupMenuButton<String>(
                    icon: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: Colors.blue.shade900, borderRadius: BorderRadius.circular(15)),
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
                            Text("GEORGIA", style: TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ],
                  ),
                const SizedBox(width: 6),
                PopupMenuButton<String>(
                  icon: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: Colors.blue.shade800, borderRadius: BorderRadius.circular(20)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _activeSeccion == "DIA" || _activeSeccion == "MIDDAY"
                              ? Icons.wb_sunny
                              : (_activeSeccion == "EVENING" ? Icons.wb_twilight : Icons.nightlight_round),
                          size: 14, color: Colors.white,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _activeLoteria == "GEORGIA"
                              ? (_activeSeccion == "MIDDAY" ? "MAÑANA" : (_activeSeccion == "EVENING" ? "TARDE" : "NOCHE"))
                              : (_activeSeccion == "NOCHE" ? "NOCHE" : "DÍA"),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                        ),
                        const SizedBox(width: 2),
                        const Icon(Icons.arrow_drop_down, color: Colors.white, size: 16),
                      ],
                    ),
                  ),
                  onSelected: (val) async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString("sync_seccion", val);
                    setState(() => _activeSeccion = val);
                    _loadStats();
                  },
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
              ],
            ),
          ),
        ),
        ],
      ),
    );
  }

  Widget _buildBolasStatsList() {
    if (_bolaStats.isEmpty) return _emptyState();
    final sortedKeys = _bolaStats.keys.toList()..sort((a, b) {
      double totalA = _bolaStats[a]!["LISTA"]!["f"]! + _bolaStats[a]!["LISTA"]!["c"]! + _bolaStats[a]!["BOTE"]!["f"]! + _bolaStats[a]!["BOTE"]!["c"]!;
      double totalB = _bolaStats[b]!["LISTA"]!["f"]! + _bolaStats[b]!["LISTA"]!["c"]! + _bolaStats[b]!["BOTE"]!["f"]! + _bolaStats[b]!["BOTE"]!["c"]!;
      return totalB.compareTo(totalA);
    });
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: sortedKeys.length,
      itemBuilder: (context, index) {
        final num = sortedKeys[index];
        final data = _bolaStats[num]!;
        double total = data["LISTA"]!["f"]! + data["LISTA"]!["c"]! + data["BOTE"]!["f"]! + data["BOTE"]!["c"]!;
        return _statCard(num, total, [
          _row("LISTA", data["LISTA"]!["f"]!, data["LISTA"]!["c"]!, Colors.teal.shade700),
          _row("BOTE", data["BOTE"]!["f"]!, data["BOTE"]!["c"]!, Colors.orange.shade800),
        ]);
      },
    );
  }

  Widget _buildSimpleStatsList(Map<String, Map<String, double>> stats, String type) {
    if (stats.isEmpty) return _emptyState();
    final sortedKeys = stats.keys.toList()..sort((a, b) => (stats[b]!["LISTA"]! + stats[b]!["BOTE"]!).compareTo(stats[a]!["LISTA"]! + stats[a]!["BOTE"]!));
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: sortedKeys.length,
      itemBuilder: (context, index) {
        final key = sortedKeys[index];
        final data = stats[key]!;
        return _statCard(key, data["LISTA"]! + data["BOTE"]!, [
          _simpleRow("LISTA", data["LISTA"]!, Colors.blueGrey),
          _simpleRow("BOTE", data["BOTE"]!, Colors.blueGrey),
        ]);
      },
    );
  }

  Widget _statCard(String n, double t, List<Widget> rows) => Card(
    elevation: 2, margin: const EdgeInsets.only(bottom: 12),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: BorderSide(color: Colors.blue.shade50)),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        _badge(n), const SizedBox(width: 15),
        Expanded(child: Column(children: rows)),
        const SizedBox(width: 15),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [const Text("TOTAL", style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.grey)), Text("\$${t.toStringAsFixed(t % 1 == 0 ? 0 : 2)}", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Colors.blue.shade900))]),
      ]),
    ),
  );

  Widget _row(String l, double f, double c, Color col) => Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(l, style: TextStyle(color: col, fontSize: 8, fontWeight: FontWeight.w900)), Text("(${f.toStringAsFixed(f % 1 == 0 ? 0 : 2)})(${c.toStringAsFixed(c % 1 == 0 ? 0 : 2)})", style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 11))]);
  Widget _simpleRow(String l, double v, Color col) => Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(l, style: TextStyle(color: col, fontSize: 8, fontWeight: FontWeight.w900)), Text("\$${v.toStringAsFixed(v % 1 == 0 ? 0 : 2)}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11))]);
  Widget _badge(String n) => Container(width: 50, height: 50, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.blue.shade800, width: 2)), child: Center(child: Text(n, style: TextStyle(fontWeight: FontWeight.w900, fontSize: n.length > 3 ? 10 : 16, color: Colors.black87))));
  Widget _emptyState() => Center(child: Text("SIN REGISTROS", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue.shade100)));

  Future<void> _selectFecha() async {
    DateTime? picked = await showDatePicker(context: context, initialDate: DateTime.parse(_activeFecha), firstDate: DateTime(2024), lastDate: DateTime(2101));
    if (picked != null) {
      final newFecha = picked.toString().substring(0, 10);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("sync_fecha", newFecha);
      setState(() => _activeFecha = newFecha);

      // Notificar a dispositivos espejo
      Alex().broadcastSectionSync(seccion: _activeSeccion, fecha: newFecha, loteria: _activeLoteria);

      _loadStats();
    }
  }
}
