import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/database_helper.dart';
import 'package:srecord/services/tiro_service.dart';
import 'package:srecord/services/recaudacion_service.dart';

class NumerosALimitarScreen extends StatefulWidget {
  const NumerosALimitarScreen({super.key});

  @override
  State<NumerosALimitarScreen> createState() => _NumerosALimitarScreenState();
}

class _NumerosALimitarScreenState extends State<NumerosALimitarScreen> {
  final DatabaseHelper _db = DatabaseHelper();
  final TextEditingController _numController = TextEditingController();
  final TextEditingController _fijoController = TextEditingController();
  final TextEditingController _corridoController = TextEditingController();
  final TextEditingController _pagoUnicoController = TextEditingController();
  
  List<Map<String, dynamic>> _limites = [];
  String _activeType = "BOLA"; 
  String _activeDestino = "LISTA"; 
  String _activeSeccion = DateTime.now().hour < 14 ? "DIA" : "NOCHE";
  String _activeLoteria = "FLORIDA";

  final Color primaryColor = Colors.blue.shade900;
  final Color accentColor = Colors.orange.shade800;

  @override
  void initState() {
    super.initState();
    _loadLimites();
    _db.onSyncUpdate = _onSyncUpdate;
  }

  void _onSyncUpdate(int id) {
    if (mounted) _loadLimites();
  }

  @override
  void dispose() {
    _db.removeSyncUpdate(_onSyncUpdate);
    _numController.dispose();
    _fijoController.dispose();
    _corridoController.dispose();
    _pagoUnicoController.dispose();
    super.dispose();
  }

  Future<void> _loadLimites() async {
    // BANCO ESPEJO: Recargar sección y lotería por si cambió remotamente
    final prefs = await SharedPreferences.getInstance();
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    final bankLoterias = await Alex().getBankLoterias(bancoId);
    
    final String savedSeccion = prefs.getString("sync_seccion") ?? _activeSeccion;
    final String savedLoteria = bankLoterias != "AMBAS" ? bankLoterias : (prefs.getString("sync_loteria") ?? _activeLoteria);
    
    if (!mounted) return;
    if (savedSeccion != _activeSeccion || savedLoteria != _activeLoteria) {
      setState(() { 
        _activeSeccion = savedSeccion;
        _activeLoteria = savedLoteria;
      });
    }

    final res = await _db.getLimites(bancoId: bancoId, loteria: _activeLoteria);
    if (!mounted) return;
    setState(() { _limites = res; });
  }

  void _addLimite() async {
    String numero = _numController.text.trim();
    if (numero.isEmpty) return;

    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    Map<String, dynamic> nuevoLimite = {
      "banco_id": bancoId, 
      "tipo": _activeType, 
      "numero": numero, 
      "destino": _activeDestino, 
      "seccion": _activeSeccion, 
      "loteria": _activeLoteria,
      "fijo": "", 
      "corrido": "", 
      "pago": ""
    };

    if (_activeType == "BOLA") {
      if (numero.length != 2) { _msg("Use 2 cifras"); return; }
      if (_fijoController.text.isEmpty || _corridoController.text.isEmpty) { _msg("Complete Fijo y Corrido"); return; }
      nuevoLimite["fijo"] = _fijoController.text.trim();
      nuevoLimite["corrido"] = _corridoController.text.trim();
    } else if (_activeType == "CENTENA") {
      if (numero.length != 3) { _msg("Use 3 cifras"); return; }
      if (_pagoUnicoController.text.isEmpty) { _msg("Indique el pago"); return; }
      nuevoLimite["pago"] = _pagoUnicoController.text.trim();
    } else if (_activeType == "PARLE") {
      if (!numero.contains("-") || numero.split("-").length < 2) { _msg("Formato: 00-00"); return; }
      List<String> parts = numero.split("-").map((s) => s.trim()).toList();
      parts.sort();
      numero = parts.join("-");
      nuevoLimite["numero"] = numero;
      if (_pagoUnicoController.text.isEmpty) { _msg("Indique el pago"); return; }
      nuevoLimite["pago"] = _pagoUnicoController.text.trim();
    }

    await _db.saveLimite(nuevoLimite);
    
    // Push inmediato al Cerebro
    Alex().syncDataToCloud();

    _loadLimites();
    TiroService().notifyLimitesChanged();
    _numController.clear(); _fijoController.clear(); _corridoController.clear(); _pagoUnicoController.clear();
    if (mounted) FocusScope.of(context).unfocus();
  }

  void _msg(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t), backgroundColor: Colors.red.shade800));

  @override
  Widget build(BuildContext context) {
    List<Map<String, dynamic>> filtered = _limites.where((l) => 
      l["tipo"] == _activeType && 
      l["destino"] == _activeDestino && 
      (l["seccion"] == _activeSeccion || l["seccion"] == "AMBAS") &&
      (l["loteria"] == null || l["loteria"] == _activeLoteria)
    ).toList();

    return Scaffold(
      body: Column(
        children: [
          _buildFilterBar(),
          _buildTypeSelector(),
          _buildFormPanel(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text("LIMITACIONES ACTIVAS (${_activeLoteria == 'GEORGIA' ? 'GEORGIA 🍑' : 'FLORIDA 🌴'})", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: primaryColor, letterSpacing: 2)),
          ),
          Expanded(child: _buildListView(filtered)),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    bool isGeorgia = _activeLoteria == "GEORGIA";
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: isGeorgia ? Colors.orange.shade50 : Colors.blue.shade50,
      child: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
              FutureBuilder<String>(
                future: Alex().getActiveBancoId().then((bId) => Alex().getBankLoterias(bId)),
                builder: (ctx, snap) {
                  final allowed = snap.data ?? "AMBAS";
                  if (allowed == "FLORIDA" || allowed == "GEORGIA") {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(color: primaryColor, borderRadius: BorderRadius.circular(15)),
                      child: Text(allowed == "GEORGIA" ? "GEORGIA 🍑" : "FLORIDA 🌴", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                    );
                  }
                  return _dualSwitcher("FLORIDA", "GEORGIA", _activeLoteria == "FLORIDA", (val) async {
                    final lot = val ? "FLORIDA" : "GEORGIA";
                    final sec = RecaudacionService.ensureValidSeccion(_activeSeccion, lot);
                    setState(() {
                      _activeLoteria = lot;
                      _activeSeccion = sec;
                    });
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString("sync_loteria", lot);
                    await prefs.setString("sync_seccion", sec);
                    _loadLimites();
                  });
                },
              ),
              const SizedBox(width: 8),
              PopupMenuButton<String>(
                child: Container(
                  decoration: BoxDecoration(
                    color: isGeorgia ? Colors.orange.shade800 : primaryColor, 
                    borderRadius: BorderRadius.circular(15),
                    boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 2, offset: Offset(0, 1))],
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 2),
                      const Icon(Icons.arrow_drop_down, color: Colors.white, size: 16),
                    ],
                  ),
                ),
                onSelected: (s) async {
                  setState(() => _activeSeccion = s);
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString("sync_seccion", s);
                  final String activeFecha = prefs.getString("sync_fecha") ?? DateTime.now().toString().substring(0, 10);
                  Alex().broadcastSectionSync(seccion: s, fecha: activeFecha, loteria: _activeLoteria);
                },
                itemBuilder: (ctx) => isGeorgia ? const [
                  PopupMenuItem(value: "MIDDAY", child: Row(children: [Icon(Icons.wb_sunny, size: 16, color: Colors.orange), SizedBox(width: 8), Text("🌅 MAÑANA", style: TextStyle(fontWeight: FontWeight.bold))])),
                  PopupMenuItem(value: "EVENING", child: Row(children: [Icon(Icons.wb_twilight, size: 16, color: Colors.amber), SizedBox(width: 8), Text("☀️ TARDE", style: TextStyle(fontWeight: FontWeight.bold))])),
                  PopupMenuItem(value: "NIGHT", child: Row(children: [Icon(Icons.nightlight_round, size: 16, color: Colors.indigo), SizedBox(width: 8), Text("🌙 NOCHE", style: TextStyle(fontWeight: FontWeight.bold))])),
                ] : const [
                  PopupMenuItem(value: "DIA", child: Row(children: [Icon(Icons.wb_sunny, size: 16, color: Colors.orange), SizedBox(width: 8), Text("🌅 DÍA", style: TextStyle(fontWeight: FontWeight.bold))])),
                  PopupMenuItem(value: "NOCHE", child: Row(children: [Icon(Icons.nightlight_round, size: 16, color: Colors.indigo), SizedBox(width: 8), Text("🌙 NOCHE", style: TextStyle(fontWeight: FontWeight.bold))])),
                ],
              ),
            ],
          ),
        ),
        ],
      ),
    );
  }

  Widget _dualSwitcher(String l1, String l2, bool isFirst, Function(bool) onChanged) {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.blue.shade100)),
      padding: const EdgeInsets.all(3),
      child: Row(
        children: [
          _switchBtn(l1, isFirst, () => onChanged(true)),
          _switchBtn(l2, !isFirst, () => onChanged(false)),
        ],
      ),
    );
  }

  Widget _switchBtn(String l, bool active, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(color: active ? primaryColor : Colors.transparent, borderRadius: BorderRadius.circular(18)),
      child: Text(l, style: TextStyle(color: active ? Colors.white : Colors.blue.shade800, fontSize: 9, fontWeight: FontWeight.bold)),
    ),
  );

  Widget _buildTypeSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: ["BOLA", "PARLE", "CENTENA"].map((t) {
          bool active = _activeType == t;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() { _activeType = t; _numController.clear(); }),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: active ? primaryColor : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: active ? primaryColor : Colors.blue.shade100, width: 1.5),
                  boxShadow: active ? [BoxShadow(color: Colors.black12, blurRadius: 4, offset: const Offset(0, 2))] : [],
                ),
                child: Center(child: Text(t, style: TextStyle(color: active ? Colors.white : Colors.blue.shade800, fontWeight: FontWeight.w900, fontSize: 11))),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildFormPanel() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.blue.shade100),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, 4))],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(flex: 2, child: _formField(_numController, _activeType == "PARLE" ? "00-00" : "NÚMERO")),
              const SizedBox(width: 10),
              if (_activeType == "BOLA") ...[
                Expanded(child: _formField(_fijoController, 'FIJO \$', isSmall: true)),
                const SizedBox(width: 8),
                Expanded(child: _formField(_corridoController, 'CORR \$', isSmall: true)),
              ] else
                Expanded(child: _formField(_pagoUnicoController, 'PAGA \$', isSmall: true)),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity, height: 50,
            child: ElevatedButton(
              onPressed: _addLimite,
              style: ElevatedButton.styleFrom(backgroundColor: primaryColor, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: const Text("ESTABLECER REGLA", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _formField(TextEditingController c, String label, {bool isSmall = false}) {
    return TextField(
      controller: c,
      style: TextStyle(color: primaryColor, fontWeight: FontWeight.w900, fontSize: 18),
      textAlign: TextAlign.center,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.blue.shade400, fontSize: 9, fontWeight: FontWeight.bold),
        filled: true,
        fillColor: Colors.blue.shade50,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
      ),
      keyboardType: TextInputType.number,
    );
  }

  Widget _buildListView(List<Map<String, dynamic>> list) {
    if (list.isEmpty) return Center(child: Text("SIN LIMITACIONES", style: TextStyle(color: Colors.blue.shade100, fontWeight: FontWeight.bold, letterSpacing: 1)));
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: list.length,
      itemBuilder: (context, idx) {
        final item = list[idx];
        List<String> numeros = item["numero"].toString().split("-");
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.blue.shade50), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))]),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: Wrap(spacing: 8, children: numeros.map((n) => _ball(n)).toList()),
            title: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_activeType == "BOLA") ...[
                  _tag("FIJO", item["fijo"], primaryColor),
                  const SizedBox(width: 10),
                  _tag("CORRIDO", item["corrido"], accentColor),
                ] else
                  _tag("PAGA", item["pago"], primaryColor),
              ],
            ),
            trailing: IconButton(icon: const Icon(Icons.remove_circle_outline, color: Colors.red), onPressed: () async { 
              await _db.deleteLimite(item["id"]); 
              Alex().syncDataToCloud(); // Sincronización inmediata del borrado
              _loadLimites(); 
              TiroService().notifyLimitesChanged(); 
            }),
          ),
        );
      },
    );
  }

  Widget _tag(String l, String v, Color c) => Column(crossAxisAlignment: CrossAxisAlignment.end, children: [Text(l, style: const TextStyle(color: Colors.grey, fontSize: 8, fontWeight: FontWeight.bold)), Text("\$$v", style: TextStyle(color: c, fontWeight: FontWeight.w900, fontSize: 16))]);

  Widget _ball(String n) => Container(width: 38, height: 38, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white, border: Border.all(color: Colors.blue.shade800, width: 1.5)), child: Center(child: Text(n, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 16))));
}
