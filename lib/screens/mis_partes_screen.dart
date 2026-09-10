import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/database_helper.dart';
import 'package:srecord/services/tiro_service.dart';
import 'package:srecord/services/recaudacion_service.dart';
import 'package:srecord/widgets/connection_icon.dart';
import 'package:srecord/widgets/loteria_icon.dart';

class MisPartesScreen extends StatefulWidget {
  const MisPartesScreen({super.key});

  @override
  State<MisPartesScreen> createState() => _MisPartesScreenState();
}

class _MisPartesScreenState extends State<MisPartesScreen> {
  final DatabaseHelper _db = DatabaseHelper();
  String _listeroPin = "";
  List<Map<String, dynamic>> _history = [];
  bool _isLoading = true;
  Color _regentColor = Colors.blue.shade800;

  @override
  void initState() {
    super.initState();
    _loadInitialConfig();
    TiroService().version.addListener(_loadHistory);
  }

  @override
  void dispose() {
    TiroService().version.removeListener(_loadHistory);
    super.dispose();
  }

  Future<void> _loadInitialConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _listeroPin = (prefs.getString("current_listero_pin") ??
            prefs.getString("anchored_listero_pin") ??
            "")
        .trim();
    debugPrint("MisPartesScreen: Loaded PIN '$_listeroPin'");
    await _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      setState(() { _isLoading = true; });
      final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
      _regentColor = await Alex().getRegentColorObj();
      final res = await _db.getPartesByListero(_listeroPin, bancoId: bancoId, soloPublicados: true);
      if (mounted) {
        setState(() {
          _history = res;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Error loading mis partes: $e");
      if (mounted) setState(() { _isLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('HISTORIAL DE MIS PARTES'),
        centerTitle: true,
        backgroundColor: _regentColor,
        foregroundColor: Colors.white,
        actions: [
          const ConnectionIcon(),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadHistory),
        ],
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : _history.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _history.length,
              itemBuilder: (context, index) => _buildParteCard(_history[index]),
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history_edu_rounded, size: 80, color: Colors.blue.shade100),
          const SizedBox(height: 16),
          Text("PIN: $_listeroPin",
              style: const TextStyle(color: Colors.grey, fontSize: 10)),
          const SizedBox(height: 8),
          const Text("No tienes partes recibidos aún",
              style: TextStyle(
                  color: Colors.grey,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          const Text("Recibirás uno cuando el banco publique un tiro oficial",
              style: TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildParteCard(Map<String, dynamic> p) {
    double balance = (p['total_dia'] as num).toDouble();
    double liquidacion = (p['liquidacion'] ?? 0.0) as double;
    double saldoFinal = (p['saldo_final'] as num).toDouble();
    String tiro = p['tiro'] ?? "--";
    String loteria = (p['loteria']?.toString() ?? 'FLORIDA').toUpperCase();
    String seccion = p['seccion']?.toString() ?? 'DIA';

    double totalLimpio = (p['limpio_lista'] ?? 0.0) + (p['limpio_bote'] ?? 0.0);
    double totalPremios = (p['premios_lista'] ?? 0.0) + (p['premios_bote'] ?? 0.0);
    final coverage = Alex().calculatePremioCoverage(totalLimpio, totalPremios);

    bool listeroGana = balance < 0;
    bool isGeorgia = loteria.contains("GEORGIA");
    Color cardBgColor = isGeorgia ? const Color(0xFFE65100) : const Color(0xFF0D47A1);
    
    return Card(
      elevation: 6,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Colors.white38, width: 1.5)
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: cardBgColor,
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("${p['fecha']}", style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Colors.white), overflow: TextOverflow.ellipsis),
                        Row(
                          children: [
                            LoteriaIcon(loteria: loteria, size: 16, width: 32, borderRadius: 4),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                "$loteria - $seccion", 
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.2),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _statusBadge(listeroGana),
                ],
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Divider(height: 1),
              ),
              if (listeroGana)
                _smartSummary("¡FELICIDADES! HAS GANADO \$${RecaudacionService.formatMoney(balance.abs())} EN ESTE TIRO.", Colors.green)
              else if (balance > 0)
                _smartSummary("DEBES \$${RecaudacionService.formatMoney(balance)} AL BANCO POR ESTE TIRO.", Colors.red)
              else
                _smartSummary("TIRO EN CERO. SIN MOVIMIENTOS.", Colors.blueGrey),
              const SizedBox(height: 12),
              _buildLoteriaDrawRow(loteria, seccion, tiro, balance, isBancoView: false),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: (coverage['color'] as Color).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: (coverage['color'] as Color).withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(coverage['completo'] ? Icons.check_circle : Icons.info, color: coverage['color'], size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            "ESTADO DE PREMIOS: ${coverage['mensaje']}",
                            style: TextStyle(color: coverage['color'], fontWeight: FontWeight.w900, fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (!coverage['completo']) ...[
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          "Limpio: \$${RecaudacionService.formatMoney(totalLimpio)} / Premios: \$${RecaudacionService.formatMoney(totalPremios)}",
                          style: const TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _infoRow("FONDO ANTERIOR", (p['fondo_anterior'] as num).toDouble(), (p['fondo_anterior'] as num) > 0 ? Colors.green.shade700 : Colors.red.shade700),
              const SizedBox(height: 8),
              _infoRow(listeroGana ? "HAS GANADO (BALANCE)" : "DEBES (BALANCE)", balance.abs(), listeroGana ? Colors.green.shade700 : Colors.red.shade700),
              const SizedBox(height: 8),
              _infoRow("DINERO LIQUIDADO", liquidacion, Colors.blueGrey),
              const SizedBox(height: 15),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.blue.shade50, Colors.white],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.blue.shade100),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text("TOTAL EN CUENTA", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Colors.blue, letterSpacing: 0.5)),
                          ),
                          Text("Saldo Final", style: TextStyle(fontSize: 9, color: Colors.grey)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text("\$${RecaudacionService.formatMoney(saldoFinal.abs())}", 
                        style: TextStyle(
                          color: saldoFinal > 0 ? Colors.green.shade700 : Colors.red.shade700,
                          fontWeight: FontWeight.w900, 
                          fontSize: 24,
                          fontFamily: 'monospace'
                        )
                      ),
                    ),
                  ],
                ),
              ),
              if (saldoFinal > 0)
                 const Padding(
                   padding: EdgeInsets.only(top: 8.0),
                   child: Center(child: Text("DEBES DINERO AL BANCO", style: TextStyle(color: Colors.green, fontSize: 10, fontWeight: FontWeight.w900))),
                 )
              else if (saldoFinal < 0)
                 const Padding(
                   padding: EdgeInsets.only(top: 8.0),
                   child: Center(child: Text("EL BANCO TE DEBE DINERO", style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.w900))),
                 )
            ],
          ),
        ),
      ),
    );
  }

  Widget _smartSummary(String msg, MaterialColor color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Text(msg, 
        textAlign: TextAlign.center,
        style: TextStyle(color: color[800], fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: 0.5)
      ),
    );
  }

  Widget _statusBadge(bool listeroGana) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: listeroGana ? Colors.green.shade600 : Colors.red.shade600,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(color: (listeroGana ? Colors.green : Colors.red).withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 4))
        ],
      ),
      child: Text(
        listeroGana ? "¡GANASTE!" : "DEBES",
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 10,
          letterSpacing: 1,
        ),
      ),
    );
  }

  Widget _infoRow(String label, double value, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.black54, fontWeight: FontWeight.bold, fontSize: 12)),
        const SizedBox(width: 10),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text("\$${RecaudacionService.formatMoney(value)}", 
              style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 16)
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoteriaDrawRow(String loteria, String seccion, String tiro, double balanceSec, {required bool isBancoView}) {
    bool gana = isBancoView ? (balanceSec > 0) : (balanceSec < 0);
    bool pierde = isBancoView ? (balanceSec < 0) : (balanceSec > 0);

    String labelDraw = "";
    if (loteria == 'GEORGIA') {
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
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: loteria == 'GEORGIA' ? Colors.orange.shade900 : Colors.blue.shade900),
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
