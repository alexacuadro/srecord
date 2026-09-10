import 'dart:async' as async;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/screens/ajuste_topes_listero_screen.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/database_helper.dart';

class CrearListasScreen extends StatefulWidget {
  const CrearListasScreen({super.key});

  @override
  State<CrearListasScreen> createState() => _CrearListasScreenState();
}

class _CrearListasScreenState extends State<CrearListasScreen> {
  final DatabaseHelper _db = DatabaseHelper();
  List<Map<String, dynamic>> _listeros = [];
  List<String> _availablePlans = ["PLAN1"];
  async.Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _loadData();
    _db.onSyncUpdate = _syncUpdateListener;
  }

  void _syncUpdateListener(int id) {
    if (!mounted) return;
    _debounceTimer?.cancel();
    _debounceTimer = async.Timer(const Duration(milliseconds: 300), () {
      if (mounted) _loadData();
    });
  }

  @override
  void dispose() {
    _db.removeSyncUpdate(_syncUpdateListener);
    _debounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadData() async {
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    final planes = await _db.getPlanes(bancoId: bancoId);
    if (!mounted) return;
    if (planes.isNotEmpty) {
      setState(() { _availablePlans = planes.keys.toList(); });
    } else {
      setState(() { _availablePlans = ["PLAN1"]; });
    }
    final listeros = await _db.getListeros(bancoId: bancoId);
    if (!mounted) return;
    setState(() { 
      _listeros = listeros.map((l) => Map<String, dynamic>.from(l)).toList(); 
    });
  }

  Future<void> _saveListero(Map<String, dynamic> data) async {
    data['sync'] = 1;
    await _db.upsertListero(data);
    await Alex().syncDataToCloud(); // Await para asegurar que esté en la nube
    await Alex().broadcastSyncPulse(isDeep: true); // Forzar al otro dispositivo
  }

  void _addListero() async {
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    
    // VERIFICAR LÍMITE DE 50 LISTAS POR BANCO
    final listerosActuales = await _db.getListeros(bancoId: bancoId);
    if (listerosActuales.length >= 50) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text("LÍMITE DE LISTAS ALCANZADO", style: TextStyle(fontWeight: FontWeight.w900, color: Colors.red.shade900, fontSize: 16)),
          content: const Text("Cada banco tiene un límite máximo de 50 Listas para garantizar estabilidad y rendimiento. No puede crear más listas en este banco."),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("ENTENDIDO")),
          ],
        ),
      );
      return;
    }

    final bankLoterias = await Alex().getBankLoterias(bancoId);

    final TextEditingController nameController = TextEditingController();
    final TextEditingController pinController = TextEditingController();
    if (_availablePlans.isEmpty) _availablePlans.add("PLAN1");
    String selectedPlan = _availablePlans.first;
    String selectedLoterias = bankLoterias == "AMBAS" ? "AMBAS" : bankLoterias;

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text("NUEVA LISTA", style: TextStyle(fontWeight: FontWeight.w900, color: Colors.blue.shade900, fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController, 
                  style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold), 
                  decoration: InputDecoration(labelText: "Nombre del Listero", labelStyle: TextStyle(color: Colors.blue.shade800)), 
                  textCapitalization: TextCapitalization.characters
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: pinController, 
                  style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold), 
                  decoration: InputDecoration(labelText: "PIN de Acceso (4 cifras)", labelStyle: TextStyle(color: Colors.blue.shade800)), 
                  keyboardType: TextInputType.number, maxLength: 4
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  decoration: InputDecoration(labelText: "Plan de Pago", labelStyle: TextStyle(color: Colors.blue.shade800)),
                  initialValue: _availablePlans.contains(selectedPlan) ? selectedPlan : _availablePlans.first,
                  onChanged: (val) { setDialogState(() { selectedPlan = val!; }); },
                  items: _availablePlans.map((p) => DropdownMenuItem(value: p, child: Text(p, style: const TextStyle(fontWeight: FontWeight.bold)))).toList(),
                ),
                if (bankLoterias == "AMBAS") ...[
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    decoration: InputDecoration(labelText: "Loterías Permitidas", labelStyle: TextStyle(color: Colors.blue.shade800)),
                    initialValue: selectedLoterias,
                    onChanged: (val) { setDialogState(() { selectedLoterias = val!; }); },
                    items: const [
                      DropdownMenuItem(value: "AMBAS", child: Text("AMBAS (Florida y Georgia)", style: TextStyle(fontWeight: FontWeight.bold))),
                      DropdownMenuItem(value: "FLORIDA", child: Text("FLORIDA ÚNICAMENTE", style: TextStyle(fontWeight: FontWeight.bold))),
                      DropdownMenuItem(value: "GEORGIA", child: Text("GEORGIA ÚNICAMENTE", style: TextStyle(fontWeight: FontWeight.bold))),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text("CANCELAR", style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.bold))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade800, foregroundColor: Colors.white),
              onPressed: () async {
                if (nameController.text.trim().isNotEmpty && pinController.text.trim().length == 4) {
                  try {
                    final listero = {
                      "banco_id": bancoId, 
                      "nombre": nameController.text.trim().toUpperCase(), 
                      "pin": pinController.text.trim(), 
                      "plan": selectedPlan, 
                      "loterias": selectedLoterias,
                      "bloqueado": 0, 
                      "vinculado": 0
                    };
                    await _saveListero(listero);
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.remove("personal_topes_${bancoId}_${pinController.text.trim()}");
                    await _loadData();
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Error al crear lista: $e"), backgroundColor: Colors.red)
                      );
                    }
                  }
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Complete un nombre válido y PIN de 4 dígitos"), backgroundColor: Colors.orange)
                  );
                }
              },
              child: const Text("CREAR LISTA", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  void _editListeroLoterias(Map<String, dynamic> listero) async {
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    final bankLoterias = await Alex().getBankLoterias(bancoId);
    if (bankLoterias != "AMBAS") {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("El programador restringió este banco a solo: $bankLoterias."),
            backgroundColor: Colors.orange.shade800,
          ),
        );
      }
      return;
    }

    String currentLoterias = listero['loterias']?.toString() ?? "AMBAS";

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text("LOTERÍAS: ${listero['nombre']}", style: TextStyle(fontWeight: FontWeight.w900, color: Colors.blue.shade900, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String>(
                title: const Text("AMBAS (Florida y Georgia)", style: TextStyle(fontWeight: FontWeight.bold)),
                value: "AMBAS",
                groupValue: currentLoterias,
                onChanged: (v) => setDlgState(() => currentLoterias = v!),
              ),
              RadioListTile<String>(
                title: const Text("FLORIDA ÚNICAMENTE", style: TextStyle(fontWeight: FontWeight.bold)),
                value: "FLORIDA",
                groupValue: currentLoterias,
                onChanged: (v) => setDlgState(() => currentLoterias = v!),
              ),
              RadioListTile<String>(
                title: const Text("GEORGIA ÚNICAMENTE", style: TextStyle(fontWeight: FontWeight.bold)),
                value: "GEORGIA",
                groupValue: currentLoterias,
                onChanged: (v) => setDlgState(() => currentLoterias = v!),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade800, foregroundColor: Colors.white),
              onPressed: () async {
                Map<String, dynamic> updated = Map<String, dynamic>.from(listero);
                updated['loterias'] = currentLoterias;
                await _saveListero(updated);
                await Alex().updateListeroLoterias(bancoId, listero['pin'], currentLoterias);
                await _loadData();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text("GUARDAR"),
            ),
          ],
        ),
      ),
    );
  }

  void _resetListeroAnchor(int index) async {
    final pin = _listeros[index]['pin'];
    try {
      await Alex().unlinkListero(pin);
      await _loadData();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: const Text("Vínculo de dispositivo liberado."), backgroundColor: Colors.blue.shade800));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error al desvincular: $e"), backgroundColor: Colors.red));
    }
  }

  void _deleteListeroConfirm(Map<String, dynamic> listero) async {
    final String pin = listero['pin'];
    final String nombre = listero['nombre'];
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.delete_forever, color: Colors.red),
            SizedBox(width: 8),
            Text("ELIMINAR LISTA", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text("¿Está seguro de eliminar la lista '$nombre' (PIN: $pin)?\n\nSe eliminarán todos los registros asociados."),
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
      try {
        await Alex().deleteListero(pin);
        await _loadData();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Lista '$nombre' eliminada correctamente."), backgroundColor: Colors.green)
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Error al eliminar lista: $e"), backgroundColor: Colors.red)
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _listeros.length,
        itemBuilder: (context, index) {
          final l = _listeros[index];
          bool isBlocked = (l["bloqueado"] == true || l["bloqueado"] == 1);
          bool isLinked = (l["vinculado"] == true || l["vinculado"] == 1);
          String listeroLoterias = l['loterias']?.toString() ?? "AMBAS";
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.white, Color(0xFFF8FAFC)],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.blue.shade100, width: 1.2),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.12), offset: const Offset(0, 6), blurRadius: 10),
                BoxShadow(color: Colors.white, offset: const Offset(-2, -2), blurRadius: 4),
              ],
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: isBlocked ? [Colors.red.shade100, Colors.red.shade50] : [Colors.blue.shade100, Colors.blue.shade50],
                  ),
                  boxShadow: [
                    BoxShadow(color: isBlocked ? Colors.red.shade200 : Colors.blue.shade200, offset: const Offset(0, 3), blurRadius: 6),
                  ],
                ),
                child: Icon(Icons.person, color: isBlocked ? Colors.red.shade700 : Colors.blue.shade900),
              ),
              title: Text(l['nombre'], style: TextStyle(fontWeight: FontWeight.w900, color: Colors.blue.shade900, fontSize: 16)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text("PIN: ${l['pin']} • PLAN: ${l['plan']} • LOTERÍAS: $listeroLoterias", style: const TextStyle(color: Colors.black54, fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                  Text(isLinked ? 'DISPOSITIVO ANCLADO' : 'PENDIENTE DE VÍNCULO', style: TextStyle(color: isLinked ? Colors.green.shade700 : Colors.orange.shade800, fontSize: 9, fontWeight: FontWeight.w900)),
                ],
              ),
              trailing: PopupMenuButton<String>(
                icon: const Icon(Icons.settings_outlined, color: Colors.blueGrey),
                onSelected: (val) async {
                  if (val == 'reset') _resetListeroAnchor(index);
                  if (val == 'loterias') _editListeroLoterias(l);
                  if (val == 'topes') Navigator.push(context, MaterialPageRoute(builder: (_) => AjusteTopesListeroScreen(listeroPin: l["pin"], listeroName: l["nombre"])));
                  if (val == 'block') {
                    try {
                      await Alex().setListeroBlockStatus(l["pin"], !isBlocked);
                      await _loadData();
                    } catch (e) {
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red));
                    }
                  }
                  if (val == 'delete') {
                    _deleteListeroConfirm(l);
                  }
                },
                itemBuilder: (ctx) => [
                  if (isLinked) const PopupMenuItem(value: 'reset', child: ListTile(leading: Icon(Icons.phonelink_erase, color: Colors.orange), title: Text("Desvincular"))),
                  const PopupMenuItem(value: 'loterias', child: ListTile(leading: Icon(Icons.tune, color: Colors.indigo), title: Text("Loterías Permitidas"))),
                  const PopupMenuItem(value: 'topes', child: ListTile(leading: Icon(Icons.tune, color: Colors.blue), title: Text("Ajustar Topes"))),
                  PopupMenuItem(value: 'block', child: ListTile(leading: Icon(isBlocked ? Icons.lock_open : Icons.lock, color: isBlocked ? Colors.green : Colors.red), title: Text(isBlocked ? "Desbloquear" : "Bloquear"))),
                  const PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline, color: Colors.red), title: Text("Eliminar Listero"))),
                ],
              ),
            ),
          );
        },
      ),
      floatingActionButton: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.blue.shade700, Colors.blue.shade900],
          ),
          border: Border.all(color: Colors.white, width: 1.5),
          boxShadow: [
            BoxShadow(color: Colors.blue.shade900.withValues(alpha: 0.5), offset: const Offset(0, 6), blurRadius: 10),
            BoxShadow(color: Colors.white.withValues(alpha: 0.8), offset: const Offset(-1, -1), blurRadius: 3),
          ],
        ),
        child: FloatingActionButton(
          onPressed: _addListero,
          elevation: 0,
          highlightElevation: 0,
          backgroundColor: Colors.transparent,
          child: const Icon(Icons.add, color: Colors.white, size: 28),
        ),
      ),
    );
  }
}
