import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/database_helper.dart';
import 'package:srecord/services/recaudacion_service.dart';
import 'package:srecord/widgets/connection_icon.dart';

class NumerosLimitadosScreen extends StatefulWidget {
  const NumerosLimitadosScreen({super.key});

  @override
  State<NumerosLimitadosScreen> createState() => _NumerosLimitadosScreenState();
}

class _NumerosLimitadosScreenState extends State<NumerosLimitadosScreen> {
  final DatabaseHelper _db = DatabaseHelper();
  List<Map<String, dynamic>> _limites = [];
  String _activeType = "BOLA";
  String _activeSeccion = "DIA";
  String _activeLoteria = "FLORIDA";
  bool _isLoading = true;

  final Color primaryColor = Colors.blue.shade900;
  final Color accentColor = Colors.orange.shade800;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    final enabledLoterias = await Alex().getBankLoterias(bancoId);
    
    // Sincronizar con la sección y lotería activas globales
    _activeLoteria = enabledLoterias != "AMBAS" ? enabledLoterias : (prefs.getString("sync_loteria") ?? "FLORIDA");
    String rawSeccion = prefs.getString("sync_seccion") ?? "DIA";
    _activeSeccion = RecaudacionService.ensureValidSeccion(rawSeccion, _activeLoteria);
    
    final res = await _db.getLimites(bancoId: bancoId, loteria: _activeLoteria);
    setState(() { 
      _limites = res;
      _isLoading = false; 
    });
  }

  @override
  Widget build(BuildContext context) {
    List<Map<String, dynamic>> filtered = _limites.where((l) => 
      l["tipo"] == _activeType && 
      (l["seccion"] == _activeSeccion || l["seccion"] == "AMBAS") &&
      (l["loteria"] == null || l["loteria"] == _activeLoteria) &&
      l["destino"] == "LISTA" // Los listeros solo ven lo que les afecta a su lista
    ).toList();

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: const Text("NÚMEROS LIMITADOS", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white)),
        centerTitle: true,
        elevation: 4,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          const ConnectionIcon(color: Colors.white),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _loadData,
          )
        ],
      ),
      body: Column(
        children: [
          _buildSeccionIndicator(),
          _buildTypeSelector(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text("REGLAS DE PAGO ESPECIALES DEL BANCO", 
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: primaryColor, letterSpacing: 2)),
          ),
          Expanded(
            child: _isLoading 
              ? Center(child: CircularProgressIndicator(color: primaryColor))
              : _buildListView(filtered),
          ),
        ],
      ),
    );
  }

  Widget _buildSeccionIndicator() {
    String displaySeccion = _activeSeccion;
    if (_activeLoteria == 'GEORGIA') {
      if (_activeSeccion == 'MIDDAY') displaySeccion = 'MAÑANA';
      if (_activeSeccion == 'EVENING') displaySeccion = 'TARDE';
      if (_activeSeccion == 'NIGHT') displaySeccion = 'NOCHE';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10),
      color: Colors.blue.shade50,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(_activeSeccion == "DIA" || _activeSeccion == "MIDDAY" ? Icons.wb_sunny : Icons.nightlight_round, size: 14, color: primaryColor),
          const SizedBox(width: 10),
          Flexible(
            child: Text("MOSTRANDO LÍMITES DE: $displaySeccion (${_activeLoteria == 'GEORGIA' ? 'GEORGIA 🍑' : 'FLORIDA 🌴'})", 
              style: TextStyle(color: primaryColor, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypeSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: ["BOLA", "PARLE", "CENTENA"].map((t) {
          bool active = _activeType == t;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _activeType = t),
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

  Widget _buildListView(List<Map<String, dynamic>> list) {
    if (list.isEmpty) return Center(child: Text("SIN LIMITACIONES ACTIVAS", style: TextStyle(color: Colors.blue.shade100, fontWeight: FontWeight.bold, letterSpacing: 1)));
    
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: list.length,
      itemBuilder: (context, idx) {
        final item = list[idx];
        List<String> numeros = item["numero"].toString().split("-");

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.white, 
            borderRadius: BorderRadius.circular(15), 
            border: Border.all(color: Colors.blue.shade50), 
            boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))]
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: Wrap(
              spacing: 8,
              children: numeros.map((n) => _lotteryBall(n)).toList(),
            ),
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
          ),
        );
      },
    );
  }

  Widget _tag(String l, String v, Color c) => Column(
    crossAxisAlignment: CrossAxisAlignment.end, 
    children: [
      Text(l, style: const TextStyle(color: Colors.grey, fontSize: 8, fontWeight: FontWeight.bold)), 
      Text("\$$v", style: TextStyle(color: c, fontWeight: FontWeight.w900, fontSize: 16))
    ]
  );

  Widget _lotteryBall(String n) {
    return Container(
      width: 38, height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle, 
        color: Colors.white, 
        border: Border.all(color: Colors.blue.shade800, width: 1.5)
      ),
      child: Center(
        child: Text(n, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 16)),
      ),
    );
  }
}

