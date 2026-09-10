import 'package:flutter/material.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/database_helper.dart';

class InfoListerosScreen extends StatefulWidget {
  const InfoListerosScreen({super.key});

  @override
  State<InfoListerosScreen> createState() => _InfoListerosScreenState();
}

class _InfoListerosScreenState extends State<InfoListerosScreen> {
  final DatabaseHelper _db = DatabaseHelper();
  final TextEditingController _tituloController = TextEditingController();
  final TextEditingController _mensajeController = TextEditingController();
  List<Map<String, dynamic>> _notificaciones = [];
  List<Map<String, dynamic>> _listeros = [];
  String? _selectedListeroPin; // null significa "TODOS"
  bool _esOficial = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadNotificaciones();
    _db.onSyncUpdate = _syncUpdateListener;
  }

  void _syncUpdateListener(int id) {
    if (mounted) _loadNotificaciones();
  }

  @override
  void dispose() {
    _db.removeSyncUpdate(_syncUpdateListener);
    super.dispose();
  }

  Future<void> _loadNotificaciones() async {
    setState(() => _isLoading = true);
    try {
      final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
      final res = await _db.getNotificaciones(all: true, bancoId: bancoId);
      final list = await _db.getListeros(bancoId: bancoId);
      setState(() { 
        _notificaciones = res; 
        _listeros = list;
        _isLoading = false; 
      });
    } catch (e) {
      debugPrint("Error loading notifications: $e");
      setState(() => _isLoading = false);
    }
  }

  void _enviarNotificacion() async {
    if (_tituloController.text.isEmpty || _mensajeController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Completa todos los campos"), backgroundColor: Colors.orange));
      return;
    }
    try {
      final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
      await _db.insertNotificacion(
        _tituloController.text, 
        _mensajeController.text, 
        bancoId: bancoId,
        listeroPin: _selectedListeroPin,
        esOficial: _esOficial,
      );
      _tituloController.clear(); _mensajeController.clear();
      
      // FORZAR ENTREGA: Subir a la nube y avisar a los listeros que hay un nuevo comunicado
      await Alex().syncDataToCloud(isDeepSync: true);
      await Alex().broadcastSyncPulse(isDeep: _esOficial, targetPin: _selectedListeroPin);
      
      setState(() {
        _selectedListeroPin = null;
        _esOficial = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Comunicado enviado y distribuido"), backgroundColor: Colors.green));
        _loadNotificaciones();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              color: Colors.blue.shade50,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("NUEVO COMUNICADO OFICIAL", style: TextStyle(color: Colors.blue.shade900, fontWeight: FontWeight.w900, fontSize: 10, letterSpacing: 1.5)),
                  const SizedBox(height: 15),
                  TextField(
                    controller: _tituloController,
                    decoration: const InputDecoration(labelText: "Asunto / Título", border: OutlineInputBorder(), filled: true, fillColor: Colors.white),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    initialValue: _selectedListeroPin,
                    decoration: const InputDecoration(labelText: "Destinatario", border: OutlineInputBorder(), filled: true, fillColor: Colors.white),
                    items: [
                      const DropdownMenuItem(value: null, child: Text("TODOS LOS LISTEROS")),
                      ..._listeros.map((l) => DropdownMenuItem(
                        value: l['pin'],
                        child: Text("LISTERO: ${l['pin']} - ${l['nombre']}"),
                      )),
                    ],
                    onChanged: (val) => setState(() => _selectedListeroPin = val),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _mensajeController,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: "Mensaje detallado...", border: OutlineInputBorder(), filled: true, fillColor: Colors.white),
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    title: const Text("Comunicado Oficial (Obligatorio)", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: const Text("Bloquea la pantalla del listero hasta que confirme lectura", style: TextStyle(fontSize: 11)),
                    value: _esOficial,
                    activeThumbColor: Colors.blue.shade900,
                    onChanged: (val) => setState(() => _esOficial = val),
                  ),
                  const SizedBox(height: 15),
                  SizedBox(
                    width: double.infinity, height: 50,
                    child: ElevatedButton.icon(
                      onPressed: _enviarNotificacion,
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade800, foregroundColor: Colors.white),
                      icon: const Icon(Icons.send),
                      label: Text(_selectedListeroPin == null ? "ENVIAR A TODOS" : "ENVIAR PRIVADO", style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
            _isLoading 
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 50),
                  child: Center(child: CircularProgressIndicator(color: Colors.blue.shade800)),
                )
              : _notificaciones.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 50),
                    child: Center(child: Text("Sin comunicados previos", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey))),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    itemCount: _notificaciones.length,
                    itemBuilder: (context, index) {
                      final n = _notificaciones[index];
                      return Card(
                        elevation: 2,
                        margin: const EdgeInsets.only(bottom: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: BorderSide(color: Colors.blue.shade100)),
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(16),
                          title: Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(n['titulo'], style: TextStyle(color: Colors.blue.shade900, fontWeight: FontWeight.w900)),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (n['es_oficial'] == 1)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(color: Colors.blue.shade100, borderRadius: BorderRadius.circular(4)),
                                      child: const Text("OFICIAL", style: TextStyle(color: Colors.blue, fontSize: 8, fontWeight: FontWeight.bold)),
                                    ),
                                  if (n['listero_pin'] != null) ...[
                                    const SizedBox(width: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(color: Colors.orange.shade100, borderRadius: BorderRadius.circular(4)),
                                      child: Text("PRIVADO: ${n['listero_pin']}", style: TextStyle(color: Colors.orange.shade900, fontSize: 8, fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 8),
                              Text(n['mensaje'], style: const TextStyle(color: Colors.black87, fontSize: 13, fontWeight: FontWeight.w500)),
                              const SizedBox(height: 12),
                              Row(children: [
                                  Icon(n['visto'] == 1 ? Icons.check_circle : Icons.schedule, size: 12, color: n['visto'] == 1 ? Colors.green : Colors.orange),
                                  const SizedBox(width: 4),
                                  Text(n['visto'] == 1 ? "LEÍDO" : "PENDIENTE", style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: n['visto'] == 1 ? Colors.green : Colors.orange)),
                                  const Spacer(),
                                  Text(n['fecha'], style: const TextStyle(fontSize: 9, color: Colors.grey, fontWeight: FontWeight.bold)),
                              ]),
                            ],
                          ),
                          trailing: IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: () async {
                              final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
                              await _db.deleteNotificacion(n['id'], bancoId: bancoId);
                              _loadNotificaciones();
                          }),
                        ),
                      );
                    },
                  ),
          ],
        ),
      ),
    );
  }
}
