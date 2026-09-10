import 'dart:convert';
import 'dart:async' as async;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/database_helper.dart';
import 'package:srecord/widgets/connection_icon.dart';

class AjusteTopesListeroScreen extends StatefulWidget {
  final String? listeroPin;
  final String? listeroName;
  const AjusteTopesListeroScreen({super.key, this.listeroPin, this.listeroName});

  @override
  State<AjusteTopesListeroScreen> createState() => _AjusteTopesListeroScreenState();
}

class _AjusteTopesListeroScreenState extends State<AjusteTopesListeroScreen> {
  Map<String, dynamic> _bankPlan = {};
  Map<String, double> _myTopes = {
    "bola_lista": 0.0,
    "parle_lista": 0.0,
    "centena_lista": 0.0,
    "bola_bote": 0.0,
    "parle_bote": 0.0,
    "centena_bote": 0.0,
  };
  String _listeroPin = "";
  String _listeroName = "";
  bool _isLoading = true;
  final DatabaseHelper _db = DatabaseHelper();
  async.Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _loadTopes();
    _db.onSyncUpdate = _onSyncUpdate;
  }

  void _onSyncUpdate(int id) {
    if (!mounted) return;
    _debounceTimer?.cancel();
    _debounceTimer = async.Timer(const Duration(milliseconds: 300), () {
      if (mounted) _loadTopes();
    });
  }

  @override
  void dispose() {
    _db.removeSyncUpdate(_onSyncUpdate);
    _debounceTimer?.cancel();
    super.dispose();
  }

  final Map<String, String> _defaultPlan = {
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
  };

  Future<void> _loadTopes() async {
    final prefs = await SharedPreferences.getInstance();
    
    _listeroPin = widget.listeroPin ?? (prefs.getString("current_listero_pin") ?? prefs.getString("anchored_listero_pin") ?? "");
    _listeroName = widget.listeroName ?? (prefs.getString("logged_listero_name") ?? "Mi Cuenta");
    
    _bankPlan = Map<String, dynamic>.from(_defaultPlan);

    // 1. Cargar Plan del Banco desde DB
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    final enabledLoterias = await Alex().getListeroLoterias(bancoId, _listeroPin);
    final String activeLoteria = enabledLoterias != "AMBAS" ? enabledLoterias : (prefs.getString("sync_loteria") ?? "FLORIDA");
    final listeros = await _db.getListeros(bancoId: bancoId);
    final planes = await _db.getPlanes(bancoId: bancoId, loteria: activeLoteria);
    
    if (listeros.isNotEmpty && planes.isNotEmpty) {
      try {
        Map<String, dynamic>? listero;
        for (var l in listeros) {
          if (l["pin"] == _listeroPin) {
            listero = l;
            break;
          }
        }
        if (listero != null && planes.containsKey(listero["plan"])) {
          _bankPlan = Map<String, dynamic>.from(planes[listero["plan"]]);
        }
      } catch (e) { debugPrint("Error plan load from DB: $e"); }
    }

    // 2. Cargar Topes Personales desde DB/Prefs aisladas
    final String? personalTopesJson = prefs.getString("personal_topes_${bancoId}_$_listeroPin");
    if (personalTopesJson != null) {
      Map<String, dynamic> decoded = json.decode(personalTopesJson);
      setState(() {
        _myTopes = decoded.map((key, value) => MapEntry(key, (value as num).toDouble()));
        // Asegurar que todas las llaves existan para evitar crashes
        _myTopes.putIfAbsent("bola_lista", () => _parseLimit(_bankPlan["tope_bola"]));
        _myTopes.putIfAbsent("parle_lista", () => _parseLimit(_bankPlan["tope_parlet"]));
        _myTopes.putIfAbsent("centena_lista", () => _parseLimit(_bankPlan["tope_centena"]));
        _myTopes.putIfAbsent("bola_bote", () => _parseLimit(_bankPlan["tope_bote_bola"]));
        _myTopes.putIfAbsent("parle_bote", () => _parseLimit(_bankPlan["tope_bote_parlet"]));
        _myTopes.putIfAbsent("centena_bote", () => _parseLimit(_bankPlan["tope_bote_centena"]));
      });
    } else {
      // Inicializar con los del banco
      setState(() {
        _myTopes["bola_lista"] = _parseLimit(_bankPlan["tope_bola"]);
        _myTopes["parle_lista"] = _parseLimit(_bankPlan["tope_parlet"]);
        _myTopes["centena_lista"] = _parseLimit(_bankPlan["tope_centena"]);
        _myTopes["bola_bote"] = _parseLimit(_bankPlan["tope_bote_bola"]);
        _myTopes["parle_bote"] = _parseLimit(_bankPlan["tope_bote_parlet"]);
        _myTopes["centena_bote"] = _parseLimit(_bankPlan["tope_bote_centena"]);
      });
    }

    if (mounted) setState(() { _isLoading = false; });
  }

  double _parseLimit(dynamic val) {
    if (val == null) {
      return 999999.0;
    }
    return double.tryParse(val.toString().replaceAll(RegExp(r'[^0-9.]'), '')) ?? 999999.0;
  }

  Future<void> _savePersonalTope(String key, String value) async {
    double newVal = double.tryParse(value) ?? 0;
    
    // 1. Validar contra el Banco
    String bankKey = "";
    if (key == "bola_lista") {
      bankKey = "tope_bola";
    } else if (key == "parle_lista") {
      bankKey = "tope_parlet";
    } else if (key == "centena_lista") {
      bankKey = "tope_centena";
    } else if (key == "bola_bote") {
      bankKey = "tope_bote_bola";
    } else if (key == "parle_bote") {
      bankKey = "tope_bote_parlet";
    } else if (key == "centena_bote") {
      bankKey = "tope_bote_centena";
    }

    double maxBank = _parseLimit(_bankPlan[bankKey]);
    if (newVal > maxBank) {
      _showMsg("No puede exceder el límite del banco (\$${maxBank.toStringAsFixed(maxBank % 1 == 0 ? 0 : 2)})");
      return;
    }

    // 2. Validar contra jugadas existentes (Solo si está bajando el tope)
    if (newVal < (_myTopes[key] ?? 0.0)) {
      final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
      final enabledLoterias = await Alex().getListeroLoterias(bancoId, _listeroPin);
      final prefs = await SharedPreferences.getInstance();
      String fecha = prefs.getString("sync_fecha") ?? DateTime.now().toString().substring(0, 10);
      String activeLoteria = enabledLoterias != "AMBAS" ? enabledLoterias : (prefs.getString("sync_loteria") ?? "FLORIDA");
      String seccion = prefs.getString("sync_seccion") ?? "DIA";
      String destino = key.contains("_lista") ? "LISTA" : "BOTE";
      String tipo = key.startsWith("bola") ? "BOLA" : (key.startsWith("parle") ? "PARLE" : "CENTENA");

      List<Map<String, dynamic>> jugadas = await _db.getJugadas(_listeroPin, tipo, destino: destino, seccion: seccion, fecha: fecha, bancoId: bancoId, loteria: activeLoteria);
      
      Map<String, double> acumulados = {};
      for (var j in jugadas) {
        String val = j['valor'];
        String num = val.split('(').first.trim();
        List<String> ams = RegExp(r'\((\d+\.?\d*|X)\)').allMatches(val).map((m) => m.group(1)!).toList();
        
        if (tipo == "PARLE") {
          double money = (ams.isEmpty || ams[0] == 'X') ? 0 : (double.tryParse(ams[0]) ?? 0);
          acumulados[num] = (acumulados[num] ?? 0) + money;
        } else if (tipo == "BOLA") {
          double f = (ams.isEmpty || ams[0] == 'X') ? 0 : (double.tryParse(ams[0]) ?? 0);
          double c = (ams.length < 2 || ams[1] == 'X') ? 0 : (double.tryParse(ams[1]) ?? 0);
          // El tope de bola se aplica tanto al fijo como al corrido por separado
          acumulados["$num-F"] = (acumulados["$num-F"] ?? 0) + f;
          acumulados["$num-C"] = (acumulados["$num-C"] ?? 0) + c;
        } else { // CENTENA
          double money = (ams.isEmpty || ams[0] == 'X') ? 0 : (double.tryParse(ams[0]) ?? 0);
          acumulados[num] = (acumulados[num] ?? 0) + money;
        }
      }

      double maxAcumulado = 0;
      if (acumulados.isNotEmpty) {
        maxAcumulado = acumulados.values.reduce((a, b) => a > b ? a : b);
      }

      if (newVal < maxAcumulado) {
        _showMsg("No puede bajar el tope a \$${newVal.toStringAsFixed(newVal % 1 == 0 ? 0 : 2)} porque tiene jugadas de \$${maxAcumulado.toStringAsFixed(maxAcumulado % 1 == 0 ? 0 : 2)}");
        return;
      }
    }

    setState(() { _myTopes[key] = newVal; });
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("personal_topes_${bancoId}_$_listeroPin", json.encode(_myTopes));
    _showMsg("Tope actualizado correctamente", color: Colors.green);
  }

  void _showMsg(String m, {Color color = Colors.redAccent}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: color));
  }

  void _editTope(String key, String label) {
    final TextEditingController controller = TextEditingController(text: (_myTopes[key] ?? 0.0).toStringAsFixed((_myTopes[key] ?? 0.0) % 1 == 0 ? 0 : 2));
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Ajustar $label"),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(labelText: r"Monto Máximo Personal $", border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("CANCELAR")),
          ElevatedButton(
            onPressed: () {
              _savePersonalTope(key, controller.text);
              Navigator.pop(context);
            },
            child: const Text("GUARDAR"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("TOPES: $_listeroName"),
        centerTitle: true, 
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
        actions: [
          const ConnectionIcon(),
        ],
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _sectionHeader("TOPES DE LA LISTA", Colors.teal.shade800),
              _topeTile("Bola (Lista)", "bola_lista", "tope_bola", Colors.teal),
              _topeTile("Parle (Lista)", "parle_lista", "tope_parlet", Colors.teal),
              _topeTile("Centena (Lista)", "centena_lista", "tope_centena", Colors.teal),
              
              const SizedBox(height: 20),
              _sectionHeader("TOPES DEL BOTE", Colors.red.shade800),
              _topeTile("Bola (Bote)", "bola_bote", "tope_bote_bola", Colors.red),
              _topeTile("Parle (Bote)", "parle_bote", "tope_bote_parlet", Colors.red),
              _topeTile("Centena (Bote)", "centena_bote", "tope_bote_centena", Colors.red),
              
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20, horizontal: 10),
                child: Text("Nota: Puede bajar sus topes para seguridad, pero nunca subirlos más que el banco.", 
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey, fontStyle: FontStyle.italic)),
              ),
            ],
          ),
    );
  }

  Widget _sectionHeader(String title, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: color, letterSpacing: 1)),
    );
  }

  Widget _topeTile(String label, String key, String bankKey, Color color) {
    double bankMax = _parseLimit(_bankPlan[bankKey]);

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Banco permite: \$${bankMax.toStringAsFixed(bankMax % 1 == 0 ? 0 : 2)}", style: const TextStyle(fontSize: 11, color: Colors.grey)),
            Text("Mi límite: \$${(_myTopes[key] ?? 0.0).toStringAsFixed((_myTopes[key] ?? 0.0) % 1 == 0 ? 0 : 2)}",
              style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 16)),
          ],
        ),
        trailing: Icon(Icons.edit_note, color: color),
        onTap: () => _editTope(key, label),
      ),
    );
  }
}
