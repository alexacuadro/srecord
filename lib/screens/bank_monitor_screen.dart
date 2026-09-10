import 'package:flutter/material.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/database_helper.dart';
import 'package:intl/intl.dart';
import 'package:srecord/widgets/connection_icon.dart';

class BankMonitorScreen extends StatefulWidget {
  const BankMonitorScreen({super.key});

  @override
  State<BankMonitorScreen> createState() => _BankMonitorScreenState();
}

class _BankMonitorScreenState extends State<BankMonitorScreen> {
  final DatabaseHelper _db = DatabaseHelper();
  List<Map<String, dynamic>> _listeros = [];
  bool _isLoading = true;
  Color _regentColor = const Color(0xFF1A237E);

  @override
  void initState() {
    super.initState();
    _refreshData();
    _db.onSyncUpdate = _syncUpdateListener;
  }

  void _syncUpdateListener(int id) {
    if (mounted) _loadFromLocal();
  }

  @override
  void dispose() {
    _db.removeSyncUpdate(_syncUpdateListener);
    super.dispose();
  }

  Future<void> _refreshData() async {
    setState(() => _isLoading = true);
    // Forzamos un pull de los listeros desde la nube para ver los heartbeats reales
    await Alex().syncDataToCloud(); 
    await _loadFromLocal();
  }

  Future<void> _loadFromLocal() async {
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    _regentColor = await Alex().getRegentColorObj();
    final list = await _db.getListeros(bancoId: bancoId);
    if (mounted) {
      setState(() {
        _listeros = list;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("SUPERVISIÓN PRO"),
        backgroundColor: _regentColor,
        actions: [
          const ConnectionIcon(),
          IconButton(onPressed: _refreshData, icon: const Icon(Icons.refresh))
        ],
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              _buildSummaryHeader(),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(10),
                  itemCount: _listeros.length,
                  itemBuilder: (context, index) {
                    final l = _listeros[index];
                    return _buildListeroCard(l);
                  },
                ),
              ),
            ],
          ),
    );
  }

  Widget _buildSummaryHeader() {
    int online = _listeros.where((l) => _isOnline(l['last_seen'])).length;
    return Container(
      padding: const EdgeInsets.all(20),
      color: _regentColor.withValues(alpha: 0.1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStat("TOTAL", _listeros.length.toString(), Colors.black87),
          _buildStat("ONLINE", online.toString(), Colors.green),
          _buildStat("OFFLINE", (_listeros.length - online).toString(), Colors.red),
        ],
      ),
    );
  }

  Widget _buildStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: color)),
        Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
      ],
    );
  }

  Widget _buildListeroCard(Map<String, dynamic> l) {
    final bool online = _isOnline(l['last_seen']);
    final int count = l['last_sync_count'] ?? 0;
    final String lastTime = l['last_seen'] != null 
        ? DateFormat('HH:mm').format(DateTime.parse(l['last_seen'])) 
        : "---";

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200)
      ),
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Stack(
          children: [
            CircleAvatar(
              backgroundColor: _regentColor.withValues(alpha: 0.1),
              child: Text(l['nombre'][0].toUpperCase(), style: TextStyle(color: _regentColor, fontWeight: FontWeight.bold)),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: online ? Colors.green : Colors.grey,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2)
                ),
              ),
            )
          ],
        ),
        title: Text(l['nombre'], style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text("PIN: ${l['pin']} | Plan: ${l['plan']}", style: const TextStyle(fontSize: 11)),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text("$count Jugadas", style: TextStyle(
              fontWeight: FontWeight.w900,
              color: count >= 300 ? Colors.green : Colors.blueGrey,
              fontSize: 14
            )),
            Text(online ? "En línea" : "Visto: $lastTime", style: TextStyle(fontSize: 10, color: online ? Colors.green : Colors.grey)),
          ],
        ),
      ),
    );
  }

  bool _isOnline(String? lastSeen) {
    if (lastSeen == null) return false;
    final dt = DateTime.parse(lastSeen);
    return DateTime.now().difference(dt).inMinutes < 5;
  }
}
