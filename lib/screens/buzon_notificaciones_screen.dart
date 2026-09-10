import 'package:flutter/material.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/database_helper.dart';

class BuzonNotificacionesScreen extends StatefulWidget {
  const BuzonNotificacionesScreen({super.key});

  @override
  State<BuzonNotificacionesScreen> createState() => _BuzonNotificacionesScreenState();
}

class _BuzonNotificacionesScreenState extends State<BuzonNotificacionesScreen> {
  final DatabaseHelper _db = DatabaseHelper();
  List<Map<String, dynamic>> _notificaciones = [];
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
      final bancoId = await Alex().getActiveBancoId();
      final listeroPin = await Alex().getActiveListeroPin();
      
      // Obtenemos todas las notificaciones (leídas y no leídas) del listero
      final res = await _db.getNotificaciones(
        listeroPin: listeroPin.isEmpty ? null : listeroPin,
        bancoId: bancoId,
        all: true
      );
      
      setState(() {
        _notificaciones = res;
        _isLoading = false;
      });
      
      // Marcar todas como vistas al abrir el buzón
      for (var n in res) {
        if (n['visto'] == 0) {
          await _db.marcarNotificacionVista(n['id']);
        }
      }
    } catch (e) {
      debugPrint("Error loading notifications: $e");
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("BUZÓN DE MENSAJES", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
        backgroundColor: const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _notificaciones.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _notificaciones.length,
                  itemBuilder: (context, index) {
                    final n = _notificaciones[index];
                    final bool esOficial = n['es_oficial'] == 1;
                    return _buildNotificationCard(n, esOficial);
                  },
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.mail_outline, size: 80, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            "Sin mensajes del banco",
            style: TextStyle(color: Colors.grey.shade500, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildNotificationCard(Map<String, dynamic> n, bool esOficial) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
        side: BorderSide(
          color: esOficial ? Colors.blue.shade200 : Colors.grey.shade200,
          width: esOficial ? 2 : 1,
        ),
      ),
      child: ExpansionTile(
        leading: Icon(
          esOficial ? Icons.campaign : Icons.mail,
          color: esOficial ? Colors.blue.shade800 : Colors.grey.shade600,
        ),
        title: Text(
          n['titulo']?.toString().toUpperCase() ?? "SIN TÍTULO",
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 14,
            color: esOficial ? Colors.blue.shade900 : Colors.black87,
          ),
        ),
        subtitle: Text(
          n['fecha'] ?? "",
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(),
                Text(
                  n['mensaje'] ?? "",
                  style: const TextStyle(fontSize: 14, color: Colors.black54, height: 1.4),
                ),
                if (esOficial)
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      "COMUNICADO OFICIAL",
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue.shade900,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
