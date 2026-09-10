import 'dart:async' as async;
import 'package:flutter/material.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/database_helper.dart';

class PlanesScreen extends StatefulWidget {
  const PlanesScreen({super.key});

  @override
  State<PlanesScreen> createState() => _PlanesScreenState();
}

class _PlanesScreenState extends State<PlanesScreen> {
  final DatabaseHelper _db = DatabaseHelper();
  String _selectedLoteria = "FLORIDA";
  String _selectedPlan = "PLAN1";
  List<String> _plans = ["PLAN1"];
  Map<String, Map<String, String>> _planData = {
    "PLAN1": {
      "por_lista_bola": "80%", "por_bote_bola": "95%",
      "por_lista_centena": "70%", "por_bote_centena": "95%",
      "por_lista_parlet": "70%", "por_bote_parlet": "95%",
      "pago_lista_fijo": r"$75", "pago_bote_fijo": r"$85",
      "pago_lista_corrido": r"$25", "pago_bote_corrido": r"$25",
      "pago_lista_centena": r"$500", "pago_bote_centena": r"$500",
      "pago_lista_parlet": r"$1100", "pago_bote_parlet": r"$1300",
      "tope_bola": r"$3000", "tope_bote_bola": r"$5000",
      "tope_centena": r"$300", "tope_bote_centena": r"$500",
      "tope_parlet": r"$300", "tope_bote_parlet": r"$500"
    },
  };
  async.Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _loadPlanes();
    _db.onSyncUpdate = _syncUpdateListener;
  }

  void _syncUpdateListener(int id) {
    if (!mounted) return;
    _debounceTimer?.cancel();
    _debounceTimer = async.Timer(const Duration(milliseconds: 300), () {
      if (mounted) _loadPlanes();
    });
  }

  @override
  void dispose() {
    _db.removeSyncUpdate(_syncUpdateListener);
    _debounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadPlanes() async {
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    final bankLoterias = await Alex().getBankLoterias(bancoId);
    if (bankLoterias == "FLORIDA") {
      _selectedLoteria = "FLORIDA";
    } else if (bankLoterias == "GEORGIA") {
      _selectedLoteria = "GEORGIA";
    }
    final Map<String, dynamic> data = await _db.getPlanes(bancoId: bancoId, loteria: _selectedLoteria);
    if (data.isNotEmpty) {
      if (!mounted) return;
      setState(() {
        _planData = data.map((key, value) {
          Map<String, String> plan = Map<String, String>.from(value);
          return MapEntry(key, plan);
        });
        _plans = _planData.keys.toList();
        if (!_plans.contains(_selectedPlan)) _selectedPlan = _plans.first;
      });
    }
  }

  Future<void> _savePlanLocal(String nombre, Map<String, dynamic> config) async {
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    await _db.upsertPlan(nombre, config, bancoId: bancoId, loteria: _selectedLoteria);
    Alex().syncDataToCloud(); // Push inmediato al guardar local
  }

  void _addNewPlan() {
    final TextEditingController controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text("NUEVO PLAN", style: TextStyle(color: Colors.blue.shade900, fontWeight: FontWeight.w900, fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            hintText: "Nombre del plan", 
            labelText: "Identificador del Plan",
            labelStyle: TextStyle(color: Colors.blue.shade800),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade800, foregroundColor: Colors.white),
            onPressed: () async {
              String name = controller.text.trim().toUpperCase();
              if (name.isNotEmpty && !_plans.contains(name)) {
                Map<String, dynamic> newConfig = Map.from(_planData[_selectedPlan]!);
                setState(() {
                  _plans.add(name);
                  _planData[name] = Map<String, String>.from(newConfig);
                  _selectedPlan = name;
                });
                await _savePlanLocal(name, newConfig);
                Alex().syncDataToCloud(); // Sincronizar nuevo plan
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text("CREAR", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _editValue(String key, String currentLabel) {
    final Map<String, String> currentValues = _planData[_selectedPlan]!;
    final TextEditingController controller = TextEditingController(
        text: currentValues[key]!.replaceAll(RegExp(r'[%$]'), ''));
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text("EDITAR $currentLabel", style: TextStyle(color: Colors.blue.shade900, fontWeight: FontWeight.w900, fontSize: 14)),
        content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.blue.shade800, fontSize: 32, fontWeight: FontWeight.w900),
            decoration: InputDecoration(
                suffixText: currentValues[key]!.contains('%') ? '%' : r'$',
                suffixStyle: TextStyle(color: Colors.orange.shade800, fontWeight: FontWeight.bold),
                border: const OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade800, foregroundColor: Colors.white),
            onPressed: () async {
              String suffix = currentValues[key]!.contains('%') ? '%' : r'$';
              String newVal = suffix == '%' ? "${controller.text}%" : '\$${controller.text}';
              setState(() { _planData[_selectedPlan]![key] = newVal; });
              await _savePlanLocal(_selectedPlan, _planData[_selectedPlan]!);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text("GUARDAR", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, String> currentValues = _planData[_selectedPlan] ?? {};
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // SELECTOR DE LOTERÍA (FLORIDA VS GEORGIA) EN 3D
            FutureBuilder<String>(
              future: Alex().getActiveBancoId().then((bId) => Alex().getBankLoterias(bId)),
              builder: (ctx, snap) {
                final allowed = snap.data ?? "AMBAS";
                if (allowed == "FLORIDA" || allowed == "GEORGIA") {
                  final isGeorgia = allowed == "GEORGIA";
                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: isGeorgia 
                            ? [Colors.orange.shade800, Colors.orange.shade900]
                            : [Colors.blue.shade800, Colors.blue.shade900],
                      ),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.15), offset: const Offset(0, 4), blurRadius: 8),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        isGeorgia ? "PLANES DE CONFIGURACIÓN DE GEORGIA (🍑)" : "PLANES DE CONFIGURACIÓN DE FLORIDA (🌴)",
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12),
                      ),
                    ),
                  );
                }
                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFE2E8F0), Color(0xFFCBD5E1)],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white, width: 1.2),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.15), offset: const Offset(0, 4), blurRadius: 8),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            if (_selectedLoteria != "FLORIDA") {
                              setState(() { _selectedLoteria = "FLORIDA"; });
                              _loadPlanes();
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              gradient: _selectedLoteria == "FLORIDA" 
                                ? LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Colors.blue.shade800, Colors.blue.shade900],
                                  )
                                : null,
                              color: _selectedLoteria == "FLORIDA" ? null : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                              border: _selectedLoteria == "FLORIDA" ? Border.all(color: Colors.white30) : null,
                              boxShadow: _selectedLoteria == "FLORIDA" ? [
                                BoxShadow(color: Colors.blue.shade900.withValues(alpha: 0.4), offset: const Offset(0, 4), blurRadius: 8),
                              ] : null,
                            ),
                            child: Center(
                              child: Text("FLORIDA (🌴)", style: TextStyle(color: _selectedLoteria == "FLORIDA" ? Colors.white : const Color(0xFF1E293B), fontWeight: FontWeight.w900, fontSize: 12)),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            if (_selectedLoteria != "GEORGIA") {
                              setState(() { _selectedLoteria = "GEORGIA"; });
                              _loadPlanes();
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              gradient: _selectedLoteria == "GEORGIA" 
                                ? LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Colors.orange.shade800, Colors.orange.shade900],
                                  )
                                : null,
                              color: _selectedLoteria == "GEORGIA" ? null : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                              border: _selectedLoteria == "GEORGIA" ? Border.all(color: Colors.white30) : null,
                              boxShadow: _selectedLoteria == "GEORGIA" ? [
                                BoxShadow(color: Colors.orange.shade900.withValues(alpha: 0.4), offset: const Offset(0, 4), blurRadius: 8),
                              ] : null,
                            ),
                            child: Center(
                              child: Text("GEORGIA (🍑)", style: TextStyle(color: _selectedLoteria == "GEORGIA" ? Colors.white : const Color(0xFF1E293B), fontWeight: FontWeight.w900, fontSize: 12)),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.blue.shade50, 
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: Colors.blue.shade100)
              ),
              child: Row(
                children: [
                  Icon(Icons.layers, color: Colors.blue.shade800),
                  const SizedBox(width: 15),
                  Expanded(
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        dropdownColor: Colors.white,
                        value: _selectedPlan,
                        isExpanded: true,
                        style: TextStyle(color: Colors.blue.shade900, fontWeight: FontWeight.w900, fontSize: 16),
                        onChanged: (String? newValue) { setState(() { _selectedPlan = newValue!; }); },
                        items: _plans.map<DropdownMenuItem<String>>((String value) {
                          return DropdownMenuItem<String>(value: value, child: Text(value));
                        }).toList(),
                      ),
                    ),
                  ),
                  IconButton(onPressed: _addNewPlan, icon: Icon(Icons.add_circle_outline, color: Colors.blue.shade800)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _buildSection("ESTRUCTURA DE COMISIONES (%)", [
              _buildRow("BOLA", "por_lista_bola", "por_bote_bola", Colors.blue.shade900, currentValues),
              _buildRow("CENTENA", "por_lista_centena", "por_bote_centena", Colors.blue.shade900, currentValues),
              _buildRow("PARLET", "por_lista_parlet", "por_bote_parlet", Colors.blue.shade900, currentValues),
            ]),
            _buildSection("PREMIOS Y PAGOS (\$)", [
              _buildRow("FIJO", "pago_lista_fijo", "pago_bote_fijo", Colors.red.shade700, currentValues),
              _buildRow("CORRIDO", "pago_lista_corrido", "pago_bote_corrido", Colors.red.shade700, currentValues),
              _buildRow("CENTENA", "pago_lista_centena", "pago_bote_centena", Colors.red.shade700, currentValues),
              _buildRow("PARLET", "pago_lista_parlet", "pago_bote_parlet", Colors.red.shade700, currentValues),
            ]),
            _buildSection("TOPES DE RIESGO (\$)", [
              _buildRow("BOLA", "tope_bola", "tope_bote_bola", Colors.orange.shade900, currentValues),
              _buildRow("CENTENA", "tope_centena", "tope_bote_centena", Colors.orange.shade900, currentValues),
              _buildRow("PARLET", "tope_parlet", "tope_bote_parlet", Colors.orange.shade900, currentValues),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
            child: Text(title, style: TextStyle(fontWeight: FontWeight.w900, color: Colors.blue.shade800, fontSize: 10, letterSpacing: 1.5))),
        ...children,
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _buildRow(String label, String keyL, String keyB, Color color, Map<String, String> data) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: _modernButton("LISTA", label, data[keyL] ?? "", color, () => _editValue(keyL, label))),
          const SizedBox(width: 8),
          Expanded(child: _modernButton("BOTE", label, data[keyB] ?? "", color, () => _editValue(keyB, label))),
        ],
      ),
    );
  }

  Widget _modernButton(String prefix, String label, String val, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.white, Color(0xFFF8FAFC)],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white, width: 1.5),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 8, offset: const Offset(0, 4)),
            BoxShadow(color: Colors.white.withValues(alpha: 0.9), blurRadius: 2, offset: const Offset(-1, -1)),
          ],
        ),
        child: Column(
          children: [
            Text("$prefix $label", style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Colors.grey.shade600, letterSpacing: 0.5)),
            const SizedBox(height: 4),
            Text(val, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: color)),
          ],
        ),
      ),
    );
  }
}
