import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/screens/login_screen.dart';
import 'package:srecord/services/database_helper.dart';

class GestionScreen extends StatelessWidget {
  const GestionScreen({super.key});

  void _clearDatabase(BuildContext context) async {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("LIMPIAR REGISTROS"),
        content: const Text("¿Seguro que desea eliminar TODOS los registros de jugadas? Esta acción es irreversible."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              final db = DatabaseHelper();
              final sdb = await db.database;
              await sdb.delete('jugadas');
              await sdb.delete('resultados');
              await sdb.delete('partes');
              if (context.mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Base de Datos Limpiada")));
              }
            },
            child: const Text("BORRAR TODO"),
          ),
        ],
      ),
    );
  }

  void _resetApp(BuildContext context) async {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("RESTABLECIMIENTO TOTAL"),
        content: const Text("Se borrarán Listeros, Planes, Anclajes y Jugadas de forma permanente."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.clear();
              final dbHelper = DatabaseHelper();
              final sdb = await dbHelper.database;
              await sdb.transaction((txn) async {
                await txn.delete('jugadas'); await txn.delete('resultados'); await txn.delete('partes');
                await txn.delete('notificaciones'); await txn.delete('limites');
                await txn.delete('listeros'); await txn.delete('planes');
              });
              if (context.mounted) {
                Navigator.pop(ctx);
                Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => LoginScreen()), (route) => false);
              }
            },
            child: const Text("RESET TOTAL"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle("INFRAESTRUCTURA DE DATOS"),
          _gestionTile(context, Icons.delete_sweep, "Vaciar Historial", "Elimina jugadas registradas (mantiene listeros).", () => _clearDatabase(context)),
          _gestionTile(context, Icons.settings_backup_restore, "Reseteo de Fábrica", "Borrado absoluto de todo el banco.", () => _resetApp(context), color: Colors.red),
          const SizedBox(height: 30),
          _sectionTitle("SISTEMA OPERATIVO"),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.blue.shade100)),
            child: const Column(
              children: [
                _InfoRow(label: "Versión de Kernel", value: "S-RECORD Milenium v19"),
                _InfoRow(label: "Cifrado de Datos", value: "SQLITE AES-256"),
                _InfoRow(label: "Estado de Nodos", value: "OPERATIVO", color: Colors.green),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) => Padding(padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8), child: Text(title, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.blue.shade800, letterSpacing: 1.5)));

  Widget _gestionTile(BuildContext context, IconData icon, String title, String subtitle, VoidCallback onTap, {Color? color}) {
    return Card(
      elevation: 1, margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Icon(icon, color: color ?? Colors.blue.shade800),
        title: Text(title, style: TextStyle(fontWeight: FontWeight.w900, color: color ?? Colors.blue.shade900, fontSize: 14)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
        onTap: onTap,
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label; final String value; final Color? color;
  const _InfoRow({required this.label, required this.value, this.color});
  @override
  Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(color: Colors.blueGrey, fontSize: 11, fontWeight: FontWeight.bold)),
          Text(value, style: TextStyle(color: color ?? Colors.blue.shade900, fontWeight: FontWeight.w900, fontSize: 11)),
    ]));
  }
}
