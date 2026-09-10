import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/database_helper.dart';
import 'package:srecord/services/tiro_service.dart';
import 'package:srecord/services/recaudacion_service.dart';
import 'package:srecord/widgets/connection_icon.dart';
import 'package:srecord/widgets/loteria_icon.dart';

class PremiosScreen extends StatefulWidget {
  const PremiosScreen({super.key});

  @override
  State<PremiosScreen> createState() => _PremiosScreenState();
}

class _PremiosScreenState extends State<PremiosScreen> with SingleTickerProviderStateMixin {
  final DatabaseHelper _db = DatabaseHelper();
  String _listeroPin = "";
  
  final Map<String, String> _defaultPlan = {
    "por_lista_bola": "80%", "por_bote_bola": "95%",
    "por_lista_centena": "70%", "por_bote_centena": "95%",
    "por_lista_parlet": "70%", "por_bote_parlet": "95%",
    "pago_lista_fijo": r"$75", "pago_bote_fijo": r"$85",
    "pago_lista_corrido": r"$25", "pago_bote_corrido": r"$25",
    "pago_lista_centena": r"$500", "pago_bote_centena": r"$500",
    "pago_lista_parlet": r"$1100", "pago_bote_parlet": r"$1300",
  };

  Map<String, dynamic> _currentPlan = {};
  List<Map<String, dynamic>> _limitesEspeciales = [];
  String _activeLoteria = "FLORIDA";
  String _enabledLoterias = "AMBAS";
  String _activeSeccion = "DIA";
  String _activeFecha = DateTime.now().toString().substring(0, 10);
  
  List<Map<String, dynamic>> _winningJugadas = [];
  double _totalPremios = 0;
  bool _isLoading = true;

  late AnimationController _blinkController;

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..repeat(reverse: true);
    _loadData();
    TiroService().version.addListener(_calculatePremios);
  }

  @override
  void dispose() {
    _blinkController.dispose();
    TiroService().version.removeListener(_calculatePremios);
    super.dispose();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    _listeroPin = prefs.getString("current_listero_pin") ?? prefs.getString("anchored_listero_pin") ?? "";
    
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

    final String? limitesData = prefs.getString("banco_limites_pago_v4");
    if (limitesData != null) {
      _limitesEspeciales = List<Map<String, dynamic>>.from(json.decode(limitesData));
    }

    // Cargar Plan
    _currentPlan = Map<String, dynamic>.from(_defaultPlan);
    final listeros = await _db.getListeros(bancoId: bancoId);
    final planes = await _db.getPlanes(bancoId: bancoId, loteria: _activeLoteria);
    
    if (listeros.isNotEmpty && planes.isNotEmpty) {
      try {
        Map<String, dynamic>? listero;
        for (var l in listeros) {
          if (l["pin"] == _listeroPin) {
            listero = l;
            break;
          }
        }
        if (listero != null && planes.containsKey(listero["plan"])) {
          _currentPlan = Map<String, dynamic>.from(planes[listero["plan"]]);
        }
      } catch (e) { debugPrint("Error cargando plan en Premios desde DB: $e"); }
    }

    final customLimites = await _db.getLimites(bancoId: bancoId, loteria: _activeLoteria);
    _limitesEspeciales = customLimites;

    await _calculatePremios();
    if (mounted) setState(() { _isLoading = false; });
  }

  void _switchLoteria(String loteria) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("sync_loteria", loteria);
    final openData = RecaudacionService.getOpenSeccionAndFecha(loteria: loteria);
    setState(() {
      _activeLoteria = loteria;
      _activeSeccion = openData["seccion"]!;
      _isLoading = true;
    });
    await prefs.setString("sync_seccion", _activeSeccion);
    await _calculatePremios();
    if (mounted) setState(() { _isLoading = false; });
  }

  Future<void> _calculatePremios() async {
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";

    final Map<String, String>? tiro = await _db.getResultado(_activeFecha, _activeSeccion, bancoId: bancoId, loteria: _activeLoteria);
    if (tiro == null) {
      if (mounted) setState(() { _winningJugadas = []; _totalPremios = 0; });
      return;
    }

    // PRIORIDAD 1: Parte Oficial (Cálculo Sincronizado de Alex)
    final parteOficial = await _db.getParte(_listeroPin, _activeFecha, _activeSeccion, bancoId: bancoId, loteria: _activeLoteria);
    if (parteOficial != null && parteOficial['winners_json'] != null) {
      try {
        final decoded = json.decode(parteOficial['winners_json']);
        final List<dynamic> allWinners = [...(decoded['lista'] ?? []), ...(decoded['bote'] ?? [])];
        if (mounted) {
          setState(() {
            _winningJugadas = allWinners.map((e) => Map<String, dynamic>.from(e)).toList();
            _totalPremios = (parteOficial['premios_lista'] as num).toDouble() + (parteOficial['premios_bote'] as num).toDouble();
          });
        }
        return;
      } catch (e) {
        debugPrint("[PREMIOS] Error usando cálculo oficial: $e");
      }
    }

    List<Map<String, dynamic>> jugadas = await _db.getJugadasCompletas(_listeroPin, seccion: _activeSeccion, fecha: _activeFecha, bancoId: bancoId, loteria: _activeLoteria);
    
    List<Map<String, dynamic>> listaJugadas = jugadas.where((j) => j['destino'] == 'LISTA').toList();
    Map<String, double> brutosLista = {
      "BOLA": RecaudacionService.calculateBruto(listaJugadas, "BOLA"),
      "PARLE": RecaudacionService.calculateBruto(listaJugadas, "PARLE"),
      "CENTENA": RecaudacionService.calculateBruto(listaJugadas, "CENTENA"),
    };
    final limpiosMap = RecaudacionService.calculateLimpiosMap(brutosLista, _currentPlan, 'LISTA');
    double limpioTotalLista = limpiosMap.values.fold(0.0, (a, b) => a + b);

    List<Map<String, dynamic>> winners = [];
    double total = 0;
    Map<String, double> allowanceUsed = {};

    String centenaWin = tiro['n1']!; 
    String fijoWin = centenaWin.length >= 2 ? centenaWin.substring(centenaWin.length - 2) : centenaWin;
    String c1Win = tiro['n2']!; 
    String c2Win = tiro['n3']!;
    List<List<String>> winningPairs = [
      [fijoWin, c1Win],
      [fijoWin, c2Win],
      [c1Win, c2Win]
    ];

    List<String> winningPairsStrings = winningPairs.map((p) => (p..sort()).join('-')).toList();

    for (var j in jugadas) {
      Map<String, dynamic> meta = {};
      double premioJugada = RecaudacionService.calculatePremio(
        j['tipo'], 
        j['valor'], 
        tiro, 
        _currentPlan, 
        j['destino'],
        customLimites: _limitesEspeciales,
        seccion: _activeSeccion,
        limpioTotal: (j['destino'] == 'LISTA') ? limpioTotalLista : null,
        allowanceUsed: allowanceUsed,
        outMetadata: meta
      );

      if (premioJugada > 0) {
        winners.add({
          ...j, 
          'premio': premioJugada, 
          'subTipo': meta['subTipo'] ?? j['tipo'],
          'wasCapped': meta['wasCapped'] ?? false,
          'maxAllowedBet': meta['maxAllowedBet'] ?? 0.0,
          'limpioAlMomento': (j['destino'] == 'LISTA') ? limpioTotalLista : 0.0,
          'detailText': meta['detailText'] ?? "",
          'winningPairsStrings': winningPairsStrings
        });
        total += premioJugada;
      }
    }
    if (mounted) {
      setState(() {
        _winningJugadas = winners;
        _totalPremios = total;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color loteriaThemeColor = _activeLoteria == "GEORGIA" ? Colors.orange.shade900 : Colors.blue.shade900;
    return Scaffold(
      appBar: AppBar(
        title: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LoteriaIcon(loteria: _activeLoteria, size: 20, borderRadius: 3),
              const SizedBox(width: 8),
              Text('DETALLE DE PREMIOS ($_activeLoteria)'),
            ],
          ),
        ),
        centerTitle: true,
        backgroundColor: loteriaThemeColor,
        foregroundColor: Colors.white,
        actions: const [
          ConnectionIcon(),
        ],
      ),
      body: _isLoading 
        ? Center(child: CircularProgressIndicator(color: loteriaThemeColor))
        : Column(
            children: [
              _buildSummaryHeader(loteriaThemeColor),
              Expanded(
                child: _winningJugadas.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _winningJugadas.length,
                      itemBuilder: (context, index) => _buildPremioCard(_winningJugadas[index]),
                    ),
              ),
            ],
          ),
    );
  }

  Widget _buildSummaryHeader(Color themeColor) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: themeColor,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(30)),
      ),
      child: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_enabledLoterias == "FLORIDA")
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        LoteriaIcon(loteria: "FLORIDA", size: 14, borderRadius: 2),
                        SizedBox(width: 4),
                        Text("FL", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                      ],
                    ),
                  )
                else if (_enabledLoterias == "GEORGIA")
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        LoteriaIcon(loteria: "GEORGIA", size: 14, borderRadius: 2),
                        SizedBox(width: 4),
                        Text("GA", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                      ],
                    ),
                  )
                else
                  PopupMenuButton<String>(
                    icon: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(12)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LoteriaIcon(loteria: _activeLoteria, size: 14, borderRadius: 2),
                          const SizedBox(width: 4),
                          Text(
                            _activeLoteria == "GEORGIA" ? "GA" : "FL",
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
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
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(12)),
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
                        const SizedBox(width: 4),
                        Text(
                          _activeLoteria == "GEORGIA"
                              ? (_activeSeccion == "MIDDAY" ? "MAÑANA" : (_activeSeccion == "EVENING" ? "TARDE" : "NOCHE"))
                              : (_activeSeccion == "NOCHE" ? "NOCHE" : "DÍA"),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                        const SizedBox(width: 2),
                        const Icon(Icons.arrow_drop_down, color: Colors.white, size: 16),
                      ],
                    ),
                  ),
                  onSelected: (val) async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString("sync_seccion", val);
                    setState(() { _activeSeccion = val; _isLoading = true; });
                    await _calculatePremios();
                    if (mounted) setState(() { _isLoading = false; });
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
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _selectFecha,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.calendar_today, size: 12, color: Colors.white),
                        const SizedBox(width: 6),
                        Text(_activeFecha, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          const Text("TOTAL PREMIOS A PAGAR (LISTA + BOTE)", style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text("\$${RecaudacionService.formatMoney(_totalPremios)}", 
              style: const TextStyle(color: Colors.greenAccent, fontSize: 32, fontWeight: FontWeight.w900)),
          ),
        ],
      ),
    );
  }

  Future<void> _selectFecha() async {
    DateTime? picked = await showDatePicker(context: context, initialDate: DateTime.parse(_activeFecha), firstDate: DateTime(2024), lastDate: DateTime(2101));
    if (picked != null) {
      final newFecha = picked.toString().substring(0, 10);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("sync_fecha", newFecha);
      setState(() { _activeFecha = newFecha; _isLoading = true; });
      await _calculatePremios();
      setState(() { _isLoading = false; });
    }
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.emoji_events_outlined, size: 80, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          const Text("No hay premios registrados", style: TextStyle(color: Colors.grey, fontSize: 16, fontWeight: FontWeight.bold)),
          Text("Verifique el tiro oficial de $_activeSeccion", style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildPremioCard(Map<String, dynamic> j) {
    bool isBote = j['destino'] == 'BOTE';
    String it = j['valor'];
    bool wasCapped = j['wasCapped'] ?? false;
    double premioTotal = (j['premio'] as num).toDouble();
    String detailText = j['detailText'] ?? "";
    
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: BorderSide(color: isBote ? Colors.orange.shade100 : (wasCapped ? Colors.red.shade200 : Colors.blue.shade100))),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      j['tipo'] == 'PARLE' && it.contains('-') 
                        ? _parleTile(j, isBote)
                        : _simpleTile(j, isBote),
                      if (detailText.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Text(detailText, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Colors.blue.shade900, letterSpacing: 0.5)),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LoteriaIcon(loteria: _activeLoteria, size: 12, borderRadius: 2),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              wasCapped ? "PREMIO AJUSTADO" : "PREMIO", 
                              style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: wasCapped ? Colors.red : Colors.grey),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text("\$${RecaudacionService.formatMoney(premioTotal)}",
                          style: TextStyle(color: isBote ? Colors.orange.shade900 : (wasCapped ? Colors.red.shade800 : Colors.green.shade800), fontWeight: FontWeight.w900, fontSize: 20)),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: isBote ? Colors.orange : Colors.blue.shade800, borderRadius: BorderRadius.circular(4)),
                        child: Text(j['destino'], style: const TextStyle(fontSize: 8, color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (wasCapped)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
              decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: const BorderRadius.vertical(bottom: Radius.circular(15))),
              child: Text(
                "Regla 11x Agregada: El limpio de ${j['tipo']} (\$${j['limpioAlMomento'].toStringAsFixed(j['limpioAlMomento'] % 1 == 0 ? 0 : 2)}) solo cubre una apuesta total de hasta \$${j['maxAllowedBet'].toStringAsFixed(j['maxAllowedBet'] % 1 == 0 ? 0 : 2)}",
                style: TextStyle(color: Colors.red.shade900, fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
    );
  }

  Widget _simpleTile(Map<String, dynamic> j, bool isBote) {
    String it = j['valor'];
    int p = it.indexOf('(');
    String ns = p != -1 ? it.substring(0, p) : it;
    String mon = p != -1 ? it.substring(p) : '';
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedBuilder(
          animation: _blinkController,
          builder: (context, child) => Text(
            ns, 
            style: TextStyle(
              fontSize: 18, 
              fontWeight: FontWeight.bold, 
              color: Color.lerp(Colors.blueAccent, Colors.lightBlueAccent, _blinkController.value)
            )
          ),
        ),
        _richTextWithRedX(mon, const TextStyle(fontSize: 14, color: Colors.black54, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _parleTile(Map<String, dynamic> j, bool isBote) {
    String it = j['valor'];
    int p = it.indexOf('(');
    String ns = p != -1 ? it.substring(0, p) : it;
    String mon = p != -1 ? it.substring(p) : '';
    List<String> winningPairs = List<String>.from(j['winningPairsStrings'] ?? []);
    
    return Row(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: ns.split('-').map((n) {
            String num = n.trim();
            // Identificar si esta línea del parlés es parte de una combinación ganadora
            bool isPartWinner = false;
            for (var pair in winningPairs) {
               if (pair.contains(num)) {
                 isPartWinner = true;
                 break;
               }
            }

            return AnimatedBuilder(
              animation: _blinkController,
              builder: (context, child) => Text(
                num,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: isPartWinner 
                    ? Color.lerp(Colors.blueAccent, Colors.lightBlueAccent, _blinkController.value)
                    : Colors.black87
                )
              )
            );
          }).toList(),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 12,
          child: FittedBox(
            fit: BoxFit.fill,
            child: AnimatedBuilder(
              animation: _blinkController,
              builder: (context, child) => Text(
                '}',
                style: TextStyle(
                  color: Color.lerp(Colors.blueAccent, Colors.lightBlueAccent, _blinkController.value),
                  fontWeight: FontWeight.w100
                )
              )
            )
          )
        ),
        const SizedBox(width: 8),
        Expanded(
          child: AnimatedBuilder(
            animation: _blinkController,
            builder: (context, child) => _richTextWithRedX(
              mon,
              TextStyle(
                fontSize: 14,
                color: Color.lerp(Colors.redAccent, Colors.yellowAccent, _blinkController.value),
                fontWeight: FontWeight.bold
              )
            )
          ),
        )
      ],
    );
  }

  Widget _richTextWithRedX(String text, TextStyle baseStyle) {
    if (!text.contains('(X)')) return Text(text, style: baseStyle, overflow: TextOverflow.ellipsis);
    List<TextSpan> spans = [];
    List<String> parts = text.split('(X)');
    for (int i = 0; i < parts.length; i++) {
      if (parts[i].isNotEmpty) spans.add(TextSpan(text: parts[i], style: baseStyle));
      if (i < parts.length - 1) {
        spans.add(TextSpan(text: '(', style: baseStyle));
        spans.add(TextSpan(text: 'X', style: baseStyle.copyWith(color: Colors.red)));
        spans.add(TextSpan(text: ')', style: baseStyle));
      }
    }
    return Text.rich(TextSpan(children: spans), overflow: TextOverflow.ellipsis);
  }
}
