import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/database_helper.dart';

class NotificacionesListeroWidget extends StatefulWidget {
  const NotificacionesListeroWidget({super.key});

  @override
  State<NotificacionesListeroWidget> createState() => _NotificacionesListeroWidgetState();
}

class _NotificacionesListeroWidgetState extends State<NotificacionesListeroWidget> {
  final DatabaseHelper _db = DatabaseHelper();
  
  @override
  void initState() {
    super.initState();
    _db.onSyncUpdate = _handleSyncUpdate;
  }

  @override
  void dispose() {
    _db.removeSyncUpdate(_handleSyncUpdate);
    super.dispose();
  }

  void _handleSyncUpdate(int id) {
    if (mounted) setState(() {});
  }

  Future<Map<String, String?>> _getSessionInfo() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      "pin": prefs.getString("current_listero_pin") ?? prefs.getString("anchored_listero_pin"),
      "bancoId": await Alex().getActiveBancoId(),
    };
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, String?>>(
      future: _getSessionInfo(),
      builder: (context, sessionSnapshot) {
        if (!sessionSnapshot.hasData) return const SizedBox.shrink();

        return FutureBuilder<List<Map<String, dynamic>>>(
          future: _db.getNotificaciones(
            listeroPin: sessionSnapshot.data!["pin"],
            bancoId: sessionSnapshot.data!["bancoId"],
          ),
          builder: (context, snapshot) {
            if (!snapshot.hasData || snapshot.data!.isEmpty) {
              return const SizedBox.shrink();
            }

            final n = snapshot.data!.first; // Mostrar la más reciente

            return Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.shade300),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4, offset: const Offset(0, 2))
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.campaign, color: Colors.orange, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(n['titulo'], 
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.brown)),
                      ),
                      Text(n['fecha'], 
                        style: TextStyle(fontSize: 9, color: Colors.brown.withValues(alpha: 0.6))),
                    ],
                  ),
                  const Divider(height: 12),
                  Text(n['mensaje'], 
                    style: const TextStyle(fontSize: 11, color: Colors.black87)),
                  const SizedBox(height: 4),
                  const Align(
                    alignment: Alignment.centerRight,
                    child: Text("BANCO CENTRAL", 
                      style: TextStyle(fontSize: 7, fontWeight: FontWeight.bold, color: Colors.orange)),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
