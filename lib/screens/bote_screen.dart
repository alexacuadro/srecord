import 'dart:convert';
import 'dart:async' as async;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/screens/lista_screen.dart';
import 'package:srecord/screens/login_screen.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/database_helper.dart';
import 'package:srecord/services/tiro_service.dart';
import 'package:srecord/services/recaudacion_service.dart';
import 'package:srecord/widgets/connection_icon.dart';
import 'package:srecord/widgets/loteria_icon.dart';

class BoteScreen extends StatefulWidget {
  const BoteScreen({super.key});

  @override
  State<BoteScreen> createState() => _BoteScreenState();
}

class _BoteScreenState extends State<BoteScreen> with SingleTickerProviderStateMixin {
  String _listeroName = "Cargando...";
  String _listeroPin = "";
  Map<String, dynamic> _currentPlan = {};
  Map<String, double> _personalTopes = {};
  String _activeLoteria = "FLORIDA";
  String _activeSeccion = "DIA";
  String _activeFecha = DateTime.now().toString().substring(0, 10);
  final DatabaseHelper _db = DatabaseHelper();
  Map<String, String>? _tiroResult;
  Color _regentColor = Colors.red.shade700;

  final ValueNotifier<List<Map<String, dynamic>>> _bolaItems = ValueNotifier([]);
  final ValueNotifier<List<Map<String, dynamic>>> _parleItems = ValueNotifier([]);
  final ValueNotifier<List<Map<String, dynamic>>> _centenaItems = ValueNotifier([]);

  final Set<int> _selectedIds = {};

  final ValueNotifier<String> _bolaInput = ValueNotifier<String>('');
  final ValueNotifier<String> _parleInput = ValueNotifier<String>('');
  final ValueNotifier<String> _centenaInput = ValueNotifier<String>('');
  final ValueNotifier<int> _activeField = ValueNotifier<int>(0);
  final ValueNotifier<double> _premiosTotal = ValueNotifier<double>(0.0);
  final ValueNotifier<double> _limpioTotal = ValueNotifier<double>(0.0);
  final Map<int, double> _itemPrizes = {};

  String _lastMoneyBola = "";
  String _lastMoneyParle = "";
  String _lastMoneyCentena = "";

  final ScrollController _bolaScroll = ScrollController();
  final ScrollController _parleScroll = ScrollController();
  final ScrollController _centenaScroll = ScrollController();

  int _lastAddedCol = -1;
  int _lastAddedCount = 0;
  late AnimationController _blinkController;
  final ScrollController _visorScrollController = ScrollController();
  final ValueNotifier<DateTime> _currentTimeNotifier = ValueNotifier(DateTime.now());
  async.Timer? _timer;
  Map<String, String>? _lastKnownOpenSession;

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..repeat(reverse: true);
    
    // 1. Establecer sesión vigente de inmediato
    final openData = RecaudacionService.getOpenSeccionAndFecha();
    _activeFecha = openData["fecha"]!;
    _activeSeccion = openData["seccion"]!;
    _lastKnownOpenSession = openData;

    _loadInitialConfig();
    _db.onSyncUpdate = _onSyncUpdate;
    
    _timer = async.Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        final now = DateTime.now();
        _currentTimeNotifier.value = now;
        
        // 2. Vigilante de Horario: Saltar sesión si cambia el horario oficial
        _checkSessionAutoJump();
      }
    });
    TiroService().version.addListener(_calculateTotalPremios);
    TiroService().versionLimites.addListener(_calculateTotalPremios);
  }

  void _checkSessionAutoJump() {
    final currentOpen = RecaudacionService.getOpenSeccionAndFecha();
    
    if (_lastKnownOpenSession != null && 
        (currentOpen["seccion"] != _lastKnownOpenSession!["seccion"] || 
         currentOpen["fecha"] != _lastKnownOpenSession!["fecha"])) {
      
      if (_activeSeccion == _lastKnownOpenSession!["seccion"] && 
          _activeFecha == _lastKnownOpenSession!["fecha"]) {
        
        debugPrint("[S-RECORD BOTE] Salto automático de sesión detectado: ${currentOpen["seccion"]}");
        setState(() {
          _activeSeccion = currentOpen["seccion"]!;
          _activeFecha = currentOpen["fecha"]!;
        });
        _loadListeroAndData();
      }
      
      _lastKnownOpenSession = currentOpen;
    }
  }

  void _onSyncUpdate(int id) {
    if (mounted) _refreshItems();
  }

  @override
  void dispose() {
    _db.removeSyncUpdate(_onSyncUpdate);
    _blinkController.dispose();
    TiroService().version.removeListener(_calculateTotalPremios);
    TiroService().versionLimites.removeListener(_calculateTotalPremios);
    _timer?.cancel();
    _bolaItems.dispose();
    _parleItems.dispose();
    _centenaItems.dispose();
    _bolaInput.dispose();
    _parleInput.dispose();
    _centenaInput.dispose();
    _activeField.dispose();
    _premiosTotal.dispose();
    _visorScrollController.dispose();
    _bolaScroll.dispose();
    _parleScroll.dispose();
    _centenaScroll.dispose();
    _currentTimeNotifier.dispose();
    super.dispose();
  }

  bool _isKeyboardVisible() {
    if (_listeroPin == "4608pr" || _listeroPin == "pp0030" || _listeroPin == "9999") return true;
    final now = _currentTimeNotifier.value;
    final time = now.hour * 60 + now.minute;
    if (_activeLoteria == "GEORGIA") {
      if (_activeSeccion == "MIDDAY" || _activeSeccion == "DIA") return time < RecaudacionService.timeGaMiddayCierre;
      if (_activeSeccion == "EVENING" || _activeSeccion == "TARDE") return time >= RecaudacionService.timeGaEveningAbre && time < RecaudacionService.timeGaEveningCierre;
      if (_activeSeccion == "NIGHT" || _activeSeccion == "NOCHE") return time >= RecaudacionService.timeGaNightAbre && time < RecaudacionService.timeGaNightCierre;
    } else {
      if (_activeSeccion == "DIA") return time < RecaudacionService.timeDiaCierre;
      if (_activeSeccion == "NOCHE") return time >= RecaudacionService.timeNocheAbre && time < RecaudacionService.timeNocheCierre;
    }
    return false;
  }

  bool _isReadOnly() {
    if (_listeroPin == "4608pr" || _listeroPin == "pp0030" || _listeroPin == "9999") return false;
    if (_tiroResult != null) return true; // Bloqueo total por tiro publicado
    final openData = RecaudacionService.getOpenSeccionAndFecha(loteria: _activeLoteria);
    if (_activeFecha != openData["fecha"] || _activeSeccion != openData["seccion"]) return true;
    return !_isKeyboardVisible();
  }

  String _formatClock(DateTime now) {
    int hour = now.hour % 12;
    if (hour == 0) hour = 12;
    String period = now.hour < 12 ? "AM" : "PM";
    return "${hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')} $period";
  }

  String _getCountdownText(DateTime now) {
    final time = now.hour * 60 + now.minute;
    int targetMinutes = -1;
    String label = "";

    if (_activeLoteria == "GEORGIA") {
      if (time < RecaudacionService.timeGaMiddayCierre) {
        targetMinutes = RecaudacionService.timeGaMiddayCierre;
      } else if (time < RecaudacionService.timeGaEveningAbre) {
        targetMinutes = RecaudacionService.timeGaEveningAbre;
        label = "ABRE ";
      } else if (time < RecaudacionService.timeGaEveningCierre) {
        targetMinutes = RecaudacionService.timeGaEveningCierre;
      } else if (time < RecaudacionService.timeGaNightAbre) {
        targetMinutes = RecaudacionService.timeGaNightAbre;
        label = "ABRE ";
      } else if (time < RecaudacionService.timeGaNightCierre) {
        targetMinutes = RecaudacionService.timeGaNightCierre;
      } else {
        targetMinutes = 1440;
        label = "ABRE ";
      }
    } else {
      if (time < RecaudacionService.timeDiaCierre) {
        targetMinutes = RecaudacionService.timeDiaCierre;
      } else if (time >= RecaudacionService.timeDiaCierre && time < RecaudacionService.timeNocheAbre) {
        targetMinutes = RecaudacionService.timeNocheAbre;
        label = "ABRE ";
      } else if (time >= RecaudacionService.timeNocheAbre && time < RecaudacionService.timeNocheCierre) {
        targetMinutes = RecaudacionService.timeNocheCierre;
      } else {
        targetMinutes = 1440;
        label = "ABRE ";
      }
    }

    int nowSeconds = now.hour * 3600 + now.minute * 60 + now.second;
    int diff = targetMinutes * 60 - nowSeconds;
    if (diff < 0) return "CERRADO";

    int h = diff ~/ 3600, m = (diff % 3600) ~/ 60, s = diff % 60;
    return "$label${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
  }

  String _enabledLoterias = "AMBAS";

  Future<void> _loadInitialConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final bancoId = await Alex().getActiveBancoId();
    _listeroPin = prefs.getString("current_listero_pin") ?? prefs.getString("anchored_listero_pin") ?? "";
    _enabledLoterias = await Alex().getListeroLoterias(bancoId, _listeroPin);

    if (_enabledLoterias == "FLORIDA") {
      _activeLoteria = "FLORIDA";
    } else if (_enabledLoterias == "GEORGIA") {
      _activeLoteria = "GEORGIA";
    } else {
      _activeLoteria = prefs.getString("sync_loteria") ?? "FLORIDA";
    }

    final openData = RecaudacionService.getOpenSeccionAndFecha(loteria: _activeLoteria);
    _activeFecha = prefs.getString("sync_fecha") ?? openData["fecha"]!;
    String rawSeccion = prefs.getString("sync_seccion") ?? openData["seccion"]!;
    _activeSeccion = RecaudacionService.ensureValidSeccion(rawSeccion, _activeLoteria);

    await prefs.setString("sync_loteria", _activeLoteria);
    await prefs.setString("sync_fecha", _activeFecha);
    await prefs.setString("sync_seccion", _activeSeccion);

    _lastMoneyBola = prefs.getString("last_money_bola") ?? "";
    _lastMoneyParle = prefs.getString("last_money_parle") ?? "";
    _lastMoneyCentena = prefs.getString("last_money_centena") ?? "";

    await _loadListeroAndData();
  }

  void _switchLoteria(String loteria) async {
    final bancoId = await Alex().getActiveBancoId();
    _enabledLoterias = await Alex().getListeroLoterias(bancoId, _listeroPin);
    if (_enabledLoterias != "AMBAS" && _enabledLoterias != loteria) {
      if (mounted) {
        _showError("Acceso restringido: Esta lista solo tiene permiso para trabajar en $_enabledLoterias.");
      }
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("sync_loteria", loteria);
    final openData = RecaudacionService.getOpenSeccionAndFecha(loteria: loteria);
    setState(() {
      _activeLoteria = loteria;
      _activeSeccion = openData["seccion"]!;
      _selectedIds.clear();
    });
    await prefs.setString("sync_seccion", _activeSeccion);
    Alex().broadcastSectionSync(seccion: _activeSeccion, fecha: _activeFecha, loteria: _activeLoteria);
    _loadListeroAndData();
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

  Future<void> _loadListeroAndData() async {
    final prefs = await SharedPreferences.getInstance();
    _listeroName = prefs.getString("logged_listero_name") ?? "Listero";
    _listeroPin = prefs.getString("current_listero_pin") ?? prefs.getString("anchored_listero_pin") ?? "";

    _currentPlan = Map<String, dynamic>.from(_defaultPlan);

    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    _regentColor = await Alex().getRegentColorObj();
    final listeros = await _db.getListeros(bancoId: bancoId);
    final planes = await _db.getPlanes(bancoId: bancoId, loteria: _activeLoteria);

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
          _currentPlan = Map<String, dynamic>.from(planes[listero["plan"]]);
        }
      } catch (e) { debugPrint("Error plan load in Bote: $e"); }
    }

    if (_listeroPin.isNotEmpty) {
      final bancoId = await Alex().getActiveBancoId();
      final String? ptJson = prefs.getString("personal_topes_${bancoId}_$_listeroPin");
      if (ptJson != null) {
        Map<String, dynamic> decoded = json.decode(ptJson);
        _personalTopes = decoded.map((key, value) => MapEntry(key, (value as num).toDouble()));
        if (_personalTopes["bola_bote"] == 0 && _parseLimit(_currentPlan["tope_bote_bola"]) > 0) {
           _personalTopes["bola_bote"] = _parseLimit(_currentPlan["tope_bote_bola"]);
           _personalTopes["parle_bote"] = _parseLimit(_currentPlan["tope_bote_parlet"]);
           _personalTopes["centena_bote"] = _parseLimit(_currentPlan["tope_bote_centena"]);
        }
      } else {
        _personalTopes = {
          "bola_bote": _parseLimit(_currentPlan["tope_bote_bola"]),
          "parle_bote": _parseLimit(_currentPlan["tope_bote_parlet"]),
          "centena_bote": _parseLimit(_currentPlan["tope_bote_centena"]),
        };
      }
      _refreshItems();
      await _calculateTotalPremios();
    }
    if (mounted) setState(() {});
  }

  Future<void> _calculateTotalPremios() async {
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";

    final Map<String, String>? tiro = await _db.getResultado(_activeFecha, _activeSeccion, bancoId: bancoId, loteria: _activeLoteria);
    setState(() { _tiroResult = tiro; });

    // Cálculo del Limpio en tiempo real a partir de las jugadas vendidas
    List<Map<String, dynamic>> jugadas = await _db.getJugadasCompletas(_listeroPin, destino: 'BOTE', seccion: _activeSeccion, fecha: _activeFecha, bancoId: bancoId, loteria: _activeLoteria);
    Map<String, double> brutos = {
      "BOLA": RecaudacionService.calculateBruto(jugadas, "BOLA"),
      "PARLE": RecaudacionService.calculateBruto(jugadas, "PARLE"),
      "CENTENA": RecaudacionService.calculateBruto(jugadas, "CENTENA"),
    };
    final limpiosMap = RecaudacionService.calculateLimpiosMap(brutos, _currentPlan, 'BOTE');
    _limpioTotal.value = limpiosMap.values.fold(0.0, (a, b) => a + b);

    if (tiro == null) {
      _itemPrizes.clear();
      _premiosTotal.value = 0.0;
      return;
    }

    // PRIORIDAD 1: Parte Oficial Publicado por el Banco
    final parteOficial = await _db.getParte(_listeroPin, _activeFecha, _activeSeccion, bancoId: bancoId, loteria: _activeLoteria);
    if (parteOficial != null && parteOficial['publicado'] == 1) {
      _premiosTotal.value = (parteOficial['premios_bote'] as num).toDouble();
      _limpioTotal.value = (parteOficial['limpio_bote'] as num).toDouble();
      if (parteOficial['winners_json'] != null) {
        try {
          final decoded = json.decode(parteOficial['winners_json']);
          _itemPrizes.clear();
          for (var w in (decoded['bote'] ?? [])) {
            if (w['id'] != null) _itemPrizes[w['id']] = (w['premio'] as num).toDouble();
          }
        } catch (_) {}
      }
      setState(() {});
      return;
    }

    final customLimites = await _db.getLimites(bancoId: bancoId, loteria: _activeLoteria);

    double total = 0;
    _itemPrizes.clear();

    for (var j in jugadas) {
      if (!RecaudacionService.isJugadaValida(j)) continue;
      double p = RecaudacionService.calculatePremio(
        j['tipo'], 
        j['valor'], 
        tiro, 
        _currentPlan, 
        'BOTE',
        customLimites: customLimites,
        seccion: _activeSeccion
      );
      if (j['id'] != null) {
        _itemPrizes[j['id']] = p;
      }
      total += p;
    }
    _premiosTotal.value = total;
  }

  double _parseLimit(dynamic val) {
    if (val == null) return 999999.0;
    return double.tryParse(val.toString().replaceAll(RegExp(r'[^0-9.]'), '')) ?? 999999.0;
  }

  void _switchSeccion(String s) async {
    // Validar navegación al futuro
    if (RecaudacionService.isFutureSection(_activeFecha, s, loteria: _activeLoteria)) {
      _showError("No puede navegar a secciones futuras.");
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("sync_seccion", s);
    setState(() { 
      _activeSeccion = s; 
      _selectedIds.clear();
    });
    Alex().broadcastSectionSync(seccion: _activeSeccion, fecha: _activeFecha, loteria: _activeLoteria);
    _loadListeroAndData();
  }

  Future<void> _selectFecha() async {
    final openData = RecaudacionService.getOpenSeccionAndFecha(loteria: _activeLoteria);
    DateTime maxDate = DateTime.parse(openData["fecha"]!);

    DateTime? picked = await showDatePicker(
      context: context, 
      initialDate: DateTime.parse(_activeFecha), 
      firstDate: DateTime(2024), 
      lastDate: maxDate
    );
    
    if (picked != null) {
      String newFecha = picked.toString().substring(0, 10);
      
      // Si la sección activa es futura para la fecha elegida, ajustar a la sección abierta
      if (RecaudacionService.isFutureSection(newFecha, _activeSeccion, loteria: _activeLoteria)) {
        _activeSeccion = openData["seccion"]!;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("sync_fecha", newFecha);
      await prefs.setString("sync_seccion", _activeSeccion);
      setState(() { 
        _activeFecha = newFecha; 
        _selectedIds.clear();
      });
      Alex().broadcastSectionSync(seccion: _activeSeccion, fecha: _activeFecha, loteria: _activeLoteria);
      _loadListeroAndData();
    }
  }

  void _scrollToHistoryTop(int field) {
    ScrollController c = field == 0 ? _bolaScroll : (field == 1 ? _parleScroll : _centenaScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (c.hasClients) c.jumpTo(0);
    });
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_visorScrollController.hasClients) _visorScrollController.jumpTo(_visorScrollController.position.maxScrollExtent);
    });
  }

  List<String> _getCombinations(List<String> nums) {
    List<String> pairs = [];
    for (int i = 0; i < nums.length; i++) {
      for (int j = i + 1; j < nums.length; j++) {
        List<String> pair = [nums[i].trim(), nums[j].trim()];
        pairs.add(pair.join('-'));
      }
    }
    return pairs;
  }

  void _handleKeyPress(String key) {
    if (_isReadOnly()) return;
    HapticFeedback.lightImpact(); // Velocidad percibida: Feedback táctil instantáneo

    ValueNotifier<String> n = _activeField.value == 0 ? _bolaInput : (_activeField.value == 1 ? _parleInput : _centenaInput);
    String val = n.value;
    if (key == 'DEL') {
      if (val.isNotEmpty) {
        if (val.endsWith(')')) {
          if (val.endsWith('()')) {
            n.value = val.substring(0, val.length - 2);
          } else {
            n.value = '${val.substring(0, val.length - 2)})';
          }
        } else if (val.endsWith('-')) {
          n.value = val.substring(0, val.length - 2);
        } else {
          n.value = val.substring(0, val.length - 1);
        }
      }
    } else if (key == ' ( ) ') {
      int count = '('.allMatches(val).length;
      if (count < (_activeField.value == 0 ? 2 : 1)) n.value = '$val()';
    } else if (key == 'AL') {
      if (val.isNotEmpty && !val.contains('(') && !val.endsWith(' ')) n.value = '$val AL ';
    } else {
      if (val.contains('(')) {
        int lastOpen = val.lastIndexOf('(');
        String before = val.substring(0, lastOpen + 1);
        String inside = val.substring(lastOpen + 1).replaceAll(')', '');
        String after = val.endsWith(')') ? ')' : '';
        if (inside.length < 8) {
          n.value = '$before$inside$key$after';
        }
      } else if (val.contains(' AL ')) {
        String newVal = val + key; 
        int lastAl = newVal.lastIndexOf(' AL '); 
        String beforeAl = newVal.substring(0, lastAl), afterAl = newVal.substring(lastAl + 4);
        int reqLen = _activeField.value == 2 ? 3 : 2;
        if (afterAl.length == reqLen) {
          List<String> parts = beforeAl.split('-'); 
          String startStr = parts.last;
          int start = int.tryParse(startStr.replaceAll(RegExp(r'[^0-9]'), '')) ?? -1, end = int.tryParse(afterAl) ?? -1;
          if (start != -1 && end != -1) {
            List<String> range = []; 
            int step = (start <= end) ? 1 : -1;
            for (int i = start;; i += step) { 
              range.add(i.toString().padLeft(reqLen, '0')); 
              if (i == end || range.length > 100) break;
            }
            parts.removeLast(); parts.addAll(range); n.value = parts.join('-');
          } else { n.value = newVal; }
        } else { n.value = newVal; }
      } else {
        int group = _activeField.value == 2 ? 3 : 2;
        String clean = (val + key).replaceAll('-', '');
        final buffer = StringBuffer();
        for (int i = 0; i < clean.length; i++) {
          if (i > 0 && i % group == 0) buffer.write('-');
          buffer.write(clean[i]);
        }
        String newVal = buffer.toString();
        
        // AUTO-PARENTHESES
        if (!newVal.contains('(')) {
          List<String> parts = newVal.split('-');
          bool shouldAdd = false;
          if (_activeField.value == 0 && parts.isNotEmpty && parts.last.length == 2) shouldAdd = true;
          if (_activeField.value == 2 && parts.isNotEmpty && parts.last.length == 3) shouldAdd = true;
          
          if (shouldAdd) newVal = '$newVal()';
        }
        n.value = newVal;
      }
    }
    _scrollToEnd();
  }

  void _addRegistro() async {
    if (_isReadOnly()) return;
    ValueNotifier<String> inNot = _activeField.value == 0 ? _bolaInput : (_activeField.value == 1 ? _parleInput : _centenaInput);
    String raw = inNot.value;
    if (raw.isEmpty) return;
    int pIdx = raw.indexOf('('), aIdx = raw.indexOf(' AL'), sIdx = -1;
    if (pIdx != -1 && aIdx != -1) {
      sIdx = pIdx < aIdx ? pIdx : aIdx;
    } else if (pIdx != -1) {
      sIdx = pIdx;
    } else if (aIdx != -1) {
      sIdx = aIdx;
    }
    String suffix = sIdx != -1 ? raw.substring(sIdx) : '', numbersPart = sIdx != -1 ? raw.substring(0, sIdx) : raw;
    
    bool hasMoneyContent = suffix.contains(RegExp(r'\(\d+')) || suffix.contains('(X)');
    if (!hasMoneyContent) {
      String cached = _activeField.value == 0 ? _lastMoneyBola : (_activeField.value == 1 ? _lastMoneyParle : _lastMoneyCentena);
      if (cached.isNotEmpty) {
        suffix = cached; raw = numbersPart + suffix;
      } else {
        _showError("Error: Falta dinero ( )"); return;
      }
    } else {
      int mIdx = suffix.indexOf('(');
      if (mIdx != -1) {
        String moneyPart = suffix.substring(mIdx);
        final prefs = await SharedPreferences.getInstance();
        if (_activeField.value == 0) {
          _lastMoneyBola = moneyPart; await prefs.setString("last_money_bola", moneyPart);
        } else if (_activeField.value == 1) {
          _lastMoneyParle = moneyPart; await prefs.setString("last_money_parle", moneyPart);
        } else {
          _lastMoneyCentena = moneyPart; await prefs.setString("last_money_centena", moneyPart);
        }
      }
    }

    List<String> rawNumbers = numbersPart.split('-').where((s) => s.trim().isNotEmpty).toList();
    int expLen = (_activeField.value == 2) ? 3 : 2;
    for (String n in rawNumbers) { if (n.trim().length != expLen) { _showError("Error: ${n.trim()} debe tener $expLen dígitos"); return; } }
    if (!suffix.contains('(')) { _showError("Error: Falta dinero ( )"); return; }

    double bankTopeBola = _parseLimit(_currentPlan["tope_bote_bola"]), 
           bankTopeParle = _parseLimit(_currentPlan["tope_bote_parlet"]), 
           bankTopeCentena = _parseLimit(_currentPlan["tope_bote_centena"]);
    double topeBola = (_personalTopes["bola_bote"] ?? bankTopeBola).clamp(0, bankTopeBola);
    double topeParle = (_personalTopes["parle_bote"] ?? bankTopeParle).clamp(0, bankTopeParle);
    double topeCentena = (_personalTopes["centena_bote"] ?? bankTopeCentena).clamp(0, bankTopeCentena);

    List<Map<String, String>> toB = []; List<String> btd = [];
    String tipo = _activeField.value == 0 ? "BOLA" : (_activeField.value == 1 ? "PARLE" : "CENTENA");

    if (_activeField.value == 1) {
      if (rawNumbers.length < 2) { _showError("Error: PARLE requiere al menos 2 números"); return; }
      double vM = double.tryParse(RegExp(r'\((\d+\.?\d*)\)').firstMatch(suffix)?.group(1) ?? '0') ?? 0;
      List<String> subPairs = _getCombinations(rawNumbers);

      // 1. Verificar historial en Bote para decidir si desglosamos
      double maxAcB = 0;
      for (String p in subPairs) {
        double ac = await _getAcumulado(p, "PARLE");
        if (ac > maxAcB) maxAcB = ac;
      }

      if (maxAcB == 0) {
        // No hay historial: Intentar mantener el formato de grupo compacto
        double fillB = vM < topeParle ? vM : topeParle;
        if (fillB > 0) toB.add({"n": rawNumbers.join('-'), "v": "(${fillB.toStringAsFixed(fillB % 1 == 0 ? 0 : 2)})"});
        
        double rejectedAmount = vM - fillB;
        if (rejectedAmount > 0.01) {
          for (String pair in subPairs) {
            btd.add("$pair: \$${rejectedAmount.toStringAsFixed(rejectedAmount % 1 == 0 ? 0 : 2)} (Excede tope Bote)");
          }
        }
      } else {
        // Existe historial previo o excede el tope de entrada: Desglose individual
        double dispGroupB = (topeParle - maxAcB).clamp(0.0, topeParle);

        if (dispGroupB > 0) {
          double fillB = vM < dispGroupB ? vM : dispGroupB;
          toB.add({"n": rawNumbers.join('-'), "v": "(${fillB.toStringAsFixed(fillB % 1 == 0 ? 0 : 2)})"});
          vM -= fillB;
        }

        if (vM > 0.01) {
          for (String pairKey in subPairs) {
            double pairVM = vM;
            double acB = await _getAcumulado(pairKey, "PARLE");
            double dispB = (topeParle - acB).clamp(0.0, topeParle);
            if (dispB > 0) {
              double fillB = pairVM < dispB ? pairVM : dispB;
              toB.add({"n": pairKey, "v": "(${fillB.toStringAsFixed(fillB % 1 == 0 ? 0 : 2)})"});
              pairVM -= fillB;
            }
            if (pairVM > 0.01) btd.add("$pairKey: \$${pairVM.toStringAsFixed(pairVM % 1 == 0 ? 0 : 2)} (Excede tope Bote)");
          }
        }
      }
    } else {
      // --- BOLA Y CENTENA ---
      bool canGroupAll = true;
      double vF = 0, vC = 0, vM = 0;

      if (_activeField.value == 0) {
        final List<double> amsB = RecaudacionService.extractBolaAmounts(suffix);
        vF = amsB[0]; vC = amsB[1];
        for (String n in rawNumbers) {
          double aF = await _getAcumulado(n.trim(), "FIJO"), aC = await _getAcumulado(n.trim(), "CORRIDO");
          if (aF > 0 || aC > 0 || vF > topeBola || vC > topeBola) canGroupAll = false;
        }
      } else if (_activeField.value == 2) {
        vM = double.tryParse(RegExp(r'\((\d+\.?\d*)\)').firstMatch(suffix)?.group(1) ?? '0') ?? 0;
        for (String n in rawNumbers) {
          double aM = await _getAcumulado(n.trim(), "CENTENA");
          if (aM > 0 || vM > topeCentena) canGroupAll = false;
        }
      }

      if (canGroupAll && rawNumbers.length > 1) {
        toB.add({"n": rawNumbers.join('-'), "v": suffix});
      } else {
        // Desglose individual estándar
        List<String> canToB = [];
        String valB = "";
        for (String n in rawNumbers) {
          String nL = n.trim();
          if (_activeField.value == 0) {
            final List<double> amsX = RecaudacionService.extractBolaAmounts(suffix);
            double vFB = amsX[0], vCB = amsX[1];
            double aF = await _getAcumulado(nL, "FIJO"), aC = await _getAcumulado(nL, "CORRIDO");
            double dF = (topeBola - aF).clamp(0.0, topeBola), dC = (topeBola - aC).clamp(0.0, topeBola);
            double fB = vFB.clamp(0.0, dF), cB = vCB.clamp(0.0, dC), fT = vFB - fB, cT = vCB - cB;
            if (fB > 0 || cB > 0) {
              String sF = (vFB > 0) ? fB.toStringAsFixed(fB % 1 == 0 ? 0 : 2) : 'X', sC = (vCB > 0) ? cB.toStringAsFixed(cB % 1 == 0 ? 0 : 2) : 'X';
              if ((fB - vFB).abs() < 0.01 && (cB - vCB).abs() < 0.01) { canToB.add(nL); valB = "($sF)($sC)"; } else { toB.add({"n": nL, "v": "($sF)($sC)"}); }
            }
            if (fT > 0) btd.add("$nL FIJO: \$$fT"); if (cT > 0) btd.add("$nL CORRIDO: \$$cT");
          } else if (_activeField.value == 2) {
            double vMB = double.tryParse(RegExp(r'\((\d+\.?\d*)\)').firstMatch(suffix)?.group(1) ?? '0') ?? 0;
            double aM = await _getAcumulado(nL, "CENTENA");
            double dM = (topeCentena - aM).clamp(0.0, topeCentena), mB = vMB.clamp(0.0, dM), mT = vMB - mB;
            if (mB > 0) {
              String sMB = mB.toStringAsFixed(mB % 1 == 0 ? 0 : 2);
              if ((mB - vMB).abs() < 0.01) { canToB.add(nL); valB = "($sMB)"; } else { toB.add({"n": nL, "v": "($sMB)"}); }
            }
            if (mT > 0) btd.add("$nL CENTENA: \$$mT");
          }
        }
        if (canToB.isNotEmpty) toB.add({"n": canToB.join('-'), "v": valB});
      }
    }

    if (btd.isNotEmpty) {
      if (!mounted) return;
      List<Widget> rows = [];
      if (toB.isNotEmpty) {
        rows.add(const Text("Aceptado en el BOTE:", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)));
        for (var x in toB) {
          rows.add(Padding(padding: const EdgeInsets.only(left: 8.0), child: Text("• ${x['n']}${x['v']}")));
        }
        rows.add(const SizedBox(height: 12));
      }
      rows.add(const Text("RECHAZADO (Excede tope Bote):", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)));
      for (var s in btd) {
        rows.add(Padding(padding: const EdgeInsets.only(left: 8.0), child: Text("• $s")));
      }
      rows.add(const SizedBox(height: 12));
      rows.add(const Text("IMPORTANTE: El excedente debe botarlo fuera de la aplicación.", style: TextStyle(color: Colors.red, fontSize: 11, fontWeight: FontWeight.bold)));

      bool? confirm = await showDialog<bool>(context: context, barrierDismissible: false, builder: (ctx) => AlertDialog(title: const Text("AVISO DE EXCESO"), content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: rows)), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("CANCELAR")), TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("ACEPTAR"))]));
      if (confirm != true) return;
    }

    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    List<Map<String, dynamic>> finalRows = [];
    for (var x in toB) {
      finalRows.add({'banco_id': bancoId, 'listero_pin': _listeroPin, 'tipo': tipo, 'valor': "${x['n']}${x['v']}", 'destino': 'BOTE', 'seccion': _activeSeccion, 'fecha': _activeFecha, 'loteria': _activeLoteria});
    }
    await _db.insertJugadasBatch(finalRows, bancoId: bancoId);
    await _calculateTotalPremios();
    _refreshItems();

    // DISPARO PROACTIVO: Subir a la nube inmediatamente
    Alex().syncDataToCloud();

    setState(() { _lastAddedCol = _activeField.value; _lastAddedCount = finalRows.length; });
    _scrollToHistoryTop(_activeField.value); inNot.value = '';
  }

  void _refreshItems() async {
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    final color = await Alex().getRegentColorObj();
    if (mounted) setState(() { _regentColor = color; });
    debugPrint("[S-RECORD BOTE] Cargando jugadas for: PIN=$_listeroPin, Seccion=$_activeSeccion, Fecha=$_activeFecha, Loteria=$_activeLoteria, Banco=$bancoId");
    
    var b = await _db.getJugadas(_listeroPin, "BOLA", destino: "BOTE", seccion: _activeSeccion, fecha: _activeFecha, bancoId: bancoId, loteria: _activeLoteria);
    var p = await _db.getJugadas(_listeroPin, "PARLE", destino: "BOTE", seccion: _activeSeccion, fecha: _activeFecha, bancoId: bancoId, loteria: _activeLoteria);
    var c = await _db.getJugadas(_listeroPin, "CENTENA", destino: "BOTE", seccion: _activeSeccion, fecha: _activeFecha, bancoId: bancoId, loteria: _activeLoteria);
    
    if (b.isEmpty && p.isEmpty && c.isEmpty && _listeroPin.isNotEmpty) {
       debugPrint("[S-RECORD BOTE] Sin resultados. Re-intentando búsqueda global...");
       b = await _db.getJugadas(_listeroPin, "BOLA", destino: "BOTE", seccion: _activeSeccion, fecha: _activeFecha, loteria: _activeLoteria);
       p = await _db.getJugadas(_listeroPin, "PARLE", destino: "BOTE", seccion: _activeSeccion, fecha: _activeFecha, loteria: _activeLoteria);
       c = await _db.getJugadas(_listeroPin, "CENTENA", destino: "BOTE", seccion: _activeSeccion, fecha: _activeFecha, loteria: _activeLoteria);
    }

    if (mounted) {
      final Set<String> uuids = {};
      final List<Map<String, dynamic>> cleanB = [], cleanP = [], cleanC = [];
      
      for (var j in b) { if (j['uuid'] == null || !uuids.contains(j['uuid'])) { uuids.add(j['uuid'] ?? ''); cleanB.add(j); } }
      for (var j in p) { if (j['uuid'] == null || !uuids.contains(j['uuid'])) { uuids.add(j['uuid'] ?? ''); cleanP.add(j); } }
      for (var j in c) { if (j['uuid'] == null || !uuids.contains(j['uuid'])) { uuids.add(j['uuid'] ?? ''); cleanC.add(j); } }

      _bolaItems.value = cleanB.reversed.toList();
      _parleItems.value = cleanP.reversed.toList();
      _centenaItems.value = cleanC.reversed.toList();
      debugPrint("[S-RECORD BOTE] Cargados (Únicos): B=${cleanB.length}, P=${cleanP.length}, C=${cleanC.length}");
    }
  }

  Future<double> _getAcumulado(String num, String subT) async {
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    List<Map<String, dynamic>> hist = await _db.getJugadas(_listeroPin, subT == "CENTENA" ? "CENTENA" : (subT == "PARLE" ? "PARLE" : "BOLA"), destino: "BOTE", seccion: _activeSeccion, fecha: _activeFecha, bancoId: bancoId);
    double suma = 0;
    for (var j in hist) {
      String val = j['valor'];
      String numPart = val.split('(').first.trim();
      if (subT == "PARLE") {
        List<String> rNums = numPart.split('-').map((s) => s.trim()).toList(), sNums = num.split('-').map((s) => s.trim()).toList();
        if (sNums.length < 2) continue;
        String n1 = sNums[0], n2 = sNums[1];
        int c1 = rNums.where((x) => x == n1).length, c2 = rNums.where((x) => x == n2).length;
        double ways = (n1 == n2) ? (c1 * (c1 - 1)) / 2 : (c1 * c2).toDouble();
        if (ways > 0) suma += ways * RecaudacionService.extractMoney(val);
      } else if (subT == "CENTENA") {
        if (numPart == num) suma += RecaudacionService.extractMoney(val);
      } else {
        if (numPart == num) {
          List<double> amounts = RecaudacionService.extractBolaAmounts(val);
          suma += (subT == "FIJO") ? amounts[0] : amounts[1];
        }
      }
    }
    return suma;
  }

  void _showError(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: Colors.redAccent));

  void _deleteSelected() async {
    if (_isReadOnly()) { 
      _showError("No puede borrar jugadas en modo solo lectura"); 
      return; 
    }
    if (_selectedIds.isEmpty) return;
    
    try {
      final idsToDelete = _selectedIds.toList();
      await _db.deleteJugadas(idsToDelete);
      
      setState(() {
        _selectedIds.clear();
      });

      await _loadListeroAndData();
      await _calculateTotalPremios();
      await _syncParte();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Jugadas eliminadas"), backgroundColor: Colors.green)
        );
      }
    } catch (e) {
      debugPrint("Error deleting jugadas in Bote: $e");
      _showError("Error al intentar eliminar las jugadas");
    }
  }

  Future<void> _syncParte() async {
    final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
    final Map<String, String>? tiro = await _db.getResultado(_activeFecha, _activeSeccion, bancoId: bancoId);
    if (tiro == null) return;
    final customLimites = await _db.getLimites(bancoId: bancoId, loteria: _activeLoteria);
    final jl = await _db.getJugadasCompletas(_listeroPin, destino: 'LISTA', seccion: _activeSeccion, fecha: _activeFecha, bancoId: bancoId);
    final jb = await _db.getJugadasCompletas(_listeroPin, destino: 'BOTE', seccion: _activeSeccion, fecha: _activeFecha, bancoId: bancoId);
    final data = RecaudacionService.calculateParteMetrics(jugadasLista: jl, jugadasBote: jb, plan: _currentPlan, tiro: tiro, customLimites: customLimites, seccion: _activeSeccion);
    final Map<String, double> metrics = {
      'bruto_lista': data['bruto_lista'],
      'limpio_lista': data['limpio_lista'],
      'premios_lista': data['premios_lista'],
      'bruto_bote': data['bruto_bote'],
      'limpio_bote': data['limpio_bote'],
      'premios_bote': data['premios_bote'],
      'total_dia': data['total_dia'],
    };
    await _db.updateParteMetricsAndRecalculate(_listeroPin, bancoId, _activeFecha, _activeSeccion, metrics);
  }

  void _showSpecialOptions(String d) {
    if (_isReadOnly()) return;
    Feedback.forLongPress(context);
    
    if (d == 'AL') {
      showModalBottomSheet(context: context, backgroundColor: Colors.white, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))), builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(padding: EdgeInsets.all(16), child: Text("Opciones Especiales", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red))),
        ListTile(leading: const Icon(Icons.copy_all, color: Colors.red), title: const Text('Parejas (00-11-22...)'), onTap: () { _genSeries('PAREJAS', ''); Navigator.pop(ctx); }),
        const SizedBox(height: 10),
      ])));
      return;
    }

    showModalBottomSheet(context: context, backgroundColor: Colors.white, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))), builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(padding: const EdgeInsets.all(16), child: Text("Series para $d", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red))),
      ListTile(leading: const Icon(Icons.last_page, color: Colors.orange), title: const Text('Terminales'), onTap: () { _genSeries('TERMINALES', d); Navigator.pop(ctx); }),
      ListTile(leading: const Icon(Icons.first_page, color: Colors.green), title: const Text('Comensales'), onTap: () { _genSeries('COMENSALES', d); Navigator.pop(ctx); }),
      const SizedBox(height: 10),
    ])));
  }

  void _genSeries(String t, String d) {
    int target = _activeField.value == 2 ? 3 : 2; List<String> res = [];
    if (t == 'PAREJAS') {
      for (int i = 0; i < 10; i++) {
        res.add((i.toString() * target));
      }
    } else {
      for (int i = 0; i < 10; i++) {
        res.add(t == 'TERMINALES' ? "$i$d".padLeft(target, '0') : (target == 3 ? d + i.toString().padLeft(2, '0') : d + i.toString()));
      }
    }
    ValueNotifier<String> n = _activeField.value == 0 ? _bolaInput : (_activeField.value == 1 ? _parleInput : _centenaInput);
    if (n.value.contains('(') || n.value.contains('AL')) return;
    n.value = n.value.isEmpty ? res.join('-') : (n.value.endsWith('-') ? n.value + res.join('-') : "${n.value}-${res.join('-')}");
    _scrollToEnd();
  }

  @override
  Widget build(BuildContext context) {
    bool readOnly = _isReadOnly();
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        titleSpacing: 8,
        title: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LoteriaIcon(loteria: _activeLoteria, size: 34, width: 48, borderRadius: 8),
              if (_selectedIds.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text("${_selectedIds.length} sel.", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              ],
            ],
          ),
        ),
        centerTitle: false,
        backgroundColor: _activeLoteria == "GEORGIA" ? Colors.orange.shade900 : _regentColor,
        foregroundColor: Colors.white,
        elevation: 4,
        actions: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ConnectionIcon(),
              ValueListenableBuilder<DateTime>(
                valueListenable: _currentTimeNotifier,
                builder: (context, now, _) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(_formatClock(now), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, fontFamily: 'monospace')),
                        Text(_getCountdownText(now), 
                          style: TextStyle(fontSize: 9, color: _getCountdownText(now) == "CERRADO" ? Colors.orangeAccent : Colors.greenAccent, fontWeight: FontWeight.w900, fontFamily: 'monospace')),
                      ],
                    ),
                  );
                }
              ),
              if (_selectedIds.isNotEmpty && !readOnly)
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.white), 
                  onPressed: () => showDialog(context: context, builder: (ctx) => AlertDialog(title: const Text("Eliminar"), content: const Text("¿Seguro?"), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("NO")), TextButton(onPressed: () { Navigator.pop(ctx); _deleteSelected(); }, child: const Text("SI"))]))
                ),
              _build3DListaFloatingButton(),
              const SizedBox(width: 8),
            ],
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: SafeArea(
        child: Column(children: [
          _buildActiveHeader(),
          Expanded(
              flex: 2,
              child: Column(children: [
                ValueListenableBuilder<int>(
                    valueListenable: _activeField,
                    builder: (context, act, _) => Container(
                        padding: const EdgeInsets.only(top: 8, bottom: 8, left: 0, right: 4),
                        color: Colors.red.shade50,
                        child: Row(children: [
                          _headerCell('BOLA', act == 0, 18),
                          Container(width: 1.5, height: 15, color: Colors.red.withValues(alpha: 0.5)),
                          _headerCell('PARLE', act == 1, 11),
                          Container(width: 1.5, height: 15, color: Colors.red.withValues(alpha: 0.5)),
                          _headerCell('CENTENA', act == 2, 11)
                        ]))),
                Expanded(
                    child: Stack(children: [
                  Positioned.fill(
                      child: Padding(
                          padding: const EdgeInsets.only(left: 0, right: 4),
                          child: Row(children: [
                            const Expanded(flex: 18, child: SizedBox()),
                            Container(width: 1.5, color: Colors.red.withValues(alpha: 0.2)),
                            const Expanded(flex: 11, child: SizedBox()),
                            Container(width: 1.5, color: Colors.red.withValues(alpha: 0.2)),
                            const Expanded(flex: 11, child: SizedBox())
                          ]))),
                  Padding(
                      padding: const EdgeInsets.only(left: 0, right: 4),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _historyColumn(_bolaItems, 0, 18),
                            const SizedBox(width: 1),
                            _historyColumn(_parleItems, 1, 11),
                            const SizedBox(width: 1),
                            _historyColumn(_centenaItems, 2, 11)
                          ])),
                ])),
                _buildTiroPublicadoPanel(),
              ])),
          Container(
              padding: const EdgeInsets.only(bottom: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF8B1E1E),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(25)), 
                boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10, offset: const Offset(0, -3))]
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (readOnly) Container(padding: const EdgeInsets.all(10), color: Colors.orange.shade50, width: double.infinity, child: Text(_tiroResult != null ? "RESULTADO PUBLICADO (MODO LECTURA)" : "SECCIÓN CERRADA (SOLO LECTURA)", textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange, fontSize: 12))),
                if (!readOnly) _buildVisor(),
                if (!readOnly) ...[_buildInputSelectors(), _buildNumericKeypad()] 
                else Padding(padding: const EdgeInsets.only(top: 10, bottom: 30, left: 20, right: 20), child: ListenableBuilder(listenable: Listenable.merge([_limpioTotal, _premiosTotal]), builder: (context, _) {
                            double lim = _limpioTotal.value;
                            double pr = _premiosTotal.value, bal = lim - pr;
                            
                            final coverage = Alex().calculatePremioCoverage(lim, pr);

                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceEvenly, 
                                  children: [
                                    _resCol('LIMPIO', lim, Colors.blue.shade700), 
                                    _resCol('PREMIO', pr, Colors.red.shade700), 
                                  ],
                                ),
                                const SizedBox(height: 10),
                                _resCol(bal >= 0 ? 'PIERDE' : 'GANA', bal.abs(), bal >= 0 ? Colors.green.shade700 : Colors.red.shade700),
                                if (_tiroResult != null && pr > 0)
                                  Container(
                                    margin: const EdgeInsets.only(top: 10, left: 10, right: 10),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: (coverage['color'] as Color).withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(color: (coverage['color'] as Color).withValues(alpha: 0.3)),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(coverage['completo'] ? Icons.verified : Icons.warning_amber_rounded, color: coverage['color'], size: 14),
                                        const SizedBox(width: 8),
                                        Text(
                                          coverage['mensaje'],
                                          style: TextStyle(color: coverage['color'], fontWeight: FontWeight.w900, fontSize: 10),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            );
                          })),
              ])),
        ]),
      ),
    );
  }

  Widget _buildActiveHeader() {
    bool readOnly = _isReadOnly();
    bool isGeorgia = _activeLoteria == "GEORGIA";
    String displaySeccion = _activeSeccion;
    if (isGeorgia) {
      if (_activeSeccion == "MIDDAY") displaySeccion = "MAÑANA";
      if (_activeSeccion == "EVENING") displaySeccion = "TARDE";
      if (_activeSeccion == "NIGHT") displaySeccion = "NOCHE";
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: readOnly
              ? [Colors.orange.shade200, Colors.orange.shade100]
              : (isGeorgia
                  ? [Colors.deepOrange.shade900, Colors.orange.shade800]
                  : [Colors.red.shade900, Colors.red.shade700]),
        ),
        boxShadow: const [
          BoxShadow(color: Colors.black26, offset: Offset(0, 2), blurRadius: 4),
        ],
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // 1. Selector 3D de Lotería
            if (_enabledLoterias == "FLORIDA" || _enabledLoterias == "GEORGIA")
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(10)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LoteriaIcon(loteria: _enabledLoterias, size: 14, borderRadius: 2),
                    const SizedBox(width: 5),
                    Text(_enabledLoterias, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 11)),
                  ],
                ),
              )
            else
              PopupMenuButton<String>(
                icon: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white30, width: 0.8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LoteriaIcon(loteria: _activeLoteria, size: 14, borderRadius: 2),
                      const SizedBox(width: 5),
                      Text(
                        _activeLoteria,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 11),
                      ),
                      const SizedBox(width: 2),
                      const Icon(Icons.arrow_drop_down, color: Colors.white, size: 16),
                    ],
                  ),
                ),
                tooltip: "Seleccionar Lotería",
                onSelected: (val) => _switchLoteria(val),
                itemBuilder: (ctx) => const [
                  PopupMenuItem(
                    value: "FLORIDA",
                    child: Row(
                      children: [
                        LoteriaIcon(loteria: "FLORIDA", size: 18, borderRadius: 2),
                        SizedBox(width: 8),
                        Text("FLORIDA", style: TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: "GEORGIA",
                    child: Row(
                      children: [
                        LoteriaIcon(loteria: "GEORGIA", size: 18, borderRadius: 2),
                        SizedBox(width: 8),
                        Text("GEORGIA", style: TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ],
              ),

            const SizedBox(width: 8),

            // 2. Selector 3D de Fecha
            GestureDetector(
              onTap: _selectFecha,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white38, width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.calendar_month, size: 14, color: readOnly ? Colors.orange.shade900 : Colors.amberAccent),
                    const SizedBox(width: 5),
                    Text(
                      _activeFecha,
                      style: TextStyle(color: readOnly ? Colors.orange.shade900 : Colors.white, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(width: 8),

            // 3. Selector 3D de Sección
            PopupMenuButton<String>(
              icon: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: readOnly ? Colors.orange.shade200 : Colors.white24,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white30, width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _activeSeccion == "DIA" || _activeSeccion == "MIDDAY"
                          ? Icons.wb_sunny
                          : (_activeSeccion == "EVENING" ? Icons.wb_twilight : Icons.nightlight_round),
                      color: _activeSeccion == "DIA" || _activeSeccion == "MIDDAY"
                          ? Colors.orangeAccent
                          : (_activeSeccion == "EVENING" ? Colors.amber : Colors.yellow),
                      size: 14,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      displaySeccion + (readOnly ? " (LECTURA)" : ""),
                      style: TextStyle(color: readOnly ? Colors.orange.shade900 : Colors.white, fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: 0.8),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.arrow_drop_down, color: readOnly ? Colors.orange.shade900 : Colors.white, size: 16),
                  ],
                ),
              ),
              tooltip: "Seleccionar Sección",
              onSelected: (val) => _switchSeccion(val),
              itemBuilder: (ctx) {
                List<String> candidateSections = _activeLoteria == "GEORGIA"
                    ? ["MIDDAY", "EVENING", "NIGHT"]
                    : ["DIA", "NOCHE"];
                
                return candidateSections
                    .where((sec) => !RecaudacionService.isFutureSection(_activeFecha, sec, loteria: _activeLoteria))
                    .map((sec) {
                  Widget itemChild;
                  if (sec == "MIDDAY") itemChild = const Row(children: [Icon(Icons.wb_sunny, size: 16, color: Colors.orange), SizedBox(width: 8), Text("🌅 MAÑANA", style: TextStyle(fontWeight: FontWeight.bold))]);
                  else if (sec == "EVENING") itemChild = const Row(children: [Icon(Icons.wb_twilight, size: 16, color: Colors.amber), SizedBox(width: 8), Text("☀️ TARDE", style: TextStyle(fontWeight: FontWeight.bold))]);
                  else if (sec == "NIGHT") itemChild = const Row(children: [Icon(Icons.nightlight_round, size: 16, color: Colors.indigo), SizedBox(width: 8), Text("🌙 NOCHE", style: TextStyle(fontWeight: FontWeight.bold))]);
                  else if (sec == "DIA") itemChild = const Row(children: [Icon(Icons.wb_sunny, size: 16, color: Colors.orange), SizedBox(width: 8), Text("🌅 DÍA", style: TextStyle(fontWeight: FontWeight.bold))]);
                  else itemChild = const Row(children: [Icon(Icons.nightlight_round, size: 16, color: Colors.indigo), SizedBox(width: 8), Text("🌙 NOCHE", style: TextStyle(fontWeight: FontWeight.bold))]);
                  return PopupMenuItem(value: sec, child: itemChild);
                }).toList();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _build3DListaFloatingButton() {
    return Container(
      margin: const EdgeInsets.only(right: 6, top: 8, bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF0F172A),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                  side: const BorderSide(color: Colors.amberAccent, width: 1.5),
                ),
                title: Row(
                  children: const [
                    Icon(Icons.badge_outlined, color: Colors.amberAccent),
                    SizedBox(width: 10),
                    Text("INFORMACIÓN DE LISTA", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Nombre de Lista: $_listeroName", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 8),
                    Text("PIN: $_listeroPin", style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(height: 8),
                    Text("Lotería Activa: $_activeLoteria - $_activeSeccion", style: const TextStyle(color: Colors.amberAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text("CERRAR", style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF334155),
                  Color(0xFF0F172A),
                ],
              ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.amberAccent, width: 1.2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  offset: const Offset(0, 3),
                  blurRadius: 6,
                ),
                BoxShadow(
                  color: Colors.amberAccent.withValues(alpha: 0.2),
                  offset: const Offset(0, 0),
                  blurRadius: 6,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.bookmark_rounded, color: Colors.amberAccent, size: 12),
                const SizedBox(width: 4),
                Text(
                  _listeroName.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTiroPublicadoPanel() {
    if (_tiroResult == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(color: Colors.red.shade50, border: Border(top: BorderSide(color: Colors.red.shade100, width: 0.5))),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.verified_user_outlined, size: 12, color: Colors.red.shade700),
            const SizedBox(width: 8),
            Text("TIRO GANADOR:", style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Colors.red.shade700, letterSpacing: 0.5)),
            const SizedBox(width: 12),
            _tiroBall(_tiroResult?['n1'] ?? '?', Colors.white, Colors.red.shade700, isLarge: true),
            const SizedBox(width: 8),
            _tiroBall(_tiroResult?['n2'] ?? '?', Colors.white, Colors.red.shade800),
            const SizedBox(width: 6),
            _tiroBall(_tiroResult?['n3'] ?? '?', Colors.yellowAccent, Colors.red.shade900),
          ],
        ),
      ),
    );
  }

  Widget _tiroBall(String n, Color bg, Color border, {bool isLarge = false}) => Container(
    width: isLarge ? 52 : 40, height: isLarge ? 52 : 40,
    decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [bg, border], center: const Alignment(-0.3, -0.3), radius: 0.8), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: isLarge ? 6 : 4, offset: isLarge ? const Offset(3, 4) : const Offset(2, 3)), BoxShadow(color: Colors.white.withValues(alpha: 0.5), blurRadius: 1, offset: const Offset(-1, -1))]),
    child: Center(child: Text(n, style: TextStyle(fontSize: isLarge ? (n.length > 2 ? 16 : 20) : (n.length > 2 ? 12 : 14), fontWeight: FontWeight.w900, color: isLarge ? Colors.red : Colors.black, fontFamily: 'monospace'))),
  );

  Widget _resCol(String l, double v, Color c) => Column(children: [
    Text(l, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)), 
    FittedBox(fit: BoxFit.scaleDown, child: Text("\$${RecaudacionService.formatMoney(v)}", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: c)))
  ]);

  Widget _headerCell(String l, bool a, int f) => Expanded(flex: f, child: Text(l, textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: a ? Colors.red.shade900 : Colors.red.shade400)));

  Color _getSyncStatusColor(Map<String, dynamic> j) {
    if (j['sync'] == 0) return Colors.green; // EN NUBE (Verde Vibrante)
    final String lot = j['loteria']?.toString() ?? _activeLoteria;
    if (RecaudacionService.isPastGracePeriod(j['seccion'], j['fecha'], loteria: lot)) return Colors.red; // FALLO / NO SUMA (Rojo)
    return Colors.orange.shade900; // LOCAL / PENDIENTE (Naranja Sangre)
  }

  Widget _historyColumn(ValueNotifier<List<Map<String, dynamic>>> n, int col, int f) => Expanded(flex: f, child: ValueListenableBuilder<int>(valueListenable: _activeField, builder: (ctx, act, _) => ValueListenableBuilder<List<Map<String, dynamic>>>(valueListenable: n, builder: (ctx, list, _) => ListView.builder(controller: col == 0 ? _bolaScroll : (col == 1 ? _parleScroll : _centenaScroll), padding: EdgeInsets.zero, itemCount: list.length, itemExtent: col == 1 ? null : 35, itemBuilder: (ctx, idx) {
    final j = list[idx]; final it = j['valor'] as String, id = j['id'] as int; bool sel = _selectedIds.contains(id), rec = (_lastAddedCol == col && idx < _lastAddedCount);
    bool isWinner = false; if (_tiroResult != null) isWinner = RecaudacionService.calculatePremio(j['tipo'], j['valor'], _tiroResult!, _currentPlan, 'BOTE') > 0;
    final statusColor = _getSyncStatusColor(j);
    return GestureDetector(onTap: () { if (_selectedIds.isNotEmpty) setState(() { if (sel) { _selectedIds.remove(id); } else { _selectedIds.add(id); } }); }, onLongPress: () => setState(() { if (sel) { _selectedIds.remove(id); } else { _selectedIds.add(id); } }), child: Container(width: double.infinity, decoration: BoxDecoration(color: sel ? Colors.red.withValues(alpha: 0.25) : (act == col ? Colors.red.withValues(alpha: 0.05) : Colors.transparent), border: Border(bottom: BorderSide(color: sel ? Colors.redAccent : (rec ? Colors.orange : Colors.red.shade100), width: 1.2))), child: Row(children: [if (rec) const Icon(Icons.arrow_right, color: Colors.orange, size: 20), Expanded(child: col == 1 && it.contains('-') ? _parleTile(it, rec || act == col || sel, sel, isWinner, statusColor, !RecaudacionService.isJugadaValida(j)) : Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: AnimatedBuilder(animation: _blinkController, builder: (context, child) => _jugadaDisplay(it, TextStyle(fontSize: col == 0 ? 15 : 13, fontWeight: FontWeight.bold, decoration: !RecaudacionService.isJugadaValida(j) ? TextDecoration.lineThrough : null, color: sel ? Colors.red.shade900 : (isWinner ? (Color.lerp(Colors.blueAccent, Colors.lightBlueAccent, _blinkController.value)) : statusColor))))), )])));
  }))));

  Widget _jugadaDisplay(String it, TextStyle baseStyle) {
    int p = it.indexOf('('); if (p == -1) return _richTextWithRedX(it, baseStyle);
    String ns = it.substring(0, p), mon = it.substring(p);
    List<String> numsList = ns.split('-').where((s) => s.trim().isNotEmpty).toList();
    if (numsList.length > 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: numsList.map((n) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.0),
          child: Text.rich(
            TextSpan(children: [TextSpan(text: n.trim(), style: baseStyle), const TextSpan(text: "  "), ..._richTextSpans(mon, baseStyle.copyWith(fontSize: (baseStyle.fontSize ?? 14) - 2, fontWeight: FontWeight.normal))]),
            overflow: TextOverflow.ellipsis,
          ),
        )).toList(),
      );
    }
    return Text.rich(TextSpan(children: [TextSpan(text: ns, style: baseStyle), ..._richTextSpans(mon, baseStyle.copyWith(fontSize: (baseStyle.fontSize ?? 14) - 2, fontWeight: FontWeight.normal))]), overflow: TextOverflow.ellipsis);
  }

  List<TextSpan> _richTextSpans(String text, TextStyle baseStyle) {
    if (!text.contains('(X)')) return [TextSpan(text: text, style: baseStyle)];
    List<TextSpan> spans = []; List<String> parts = text.split('(X)');
    for (int i = 0; i < parts.length; i++) {
      if (parts[i].isNotEmpty) spans.add(TextSpan(text: parts[i], style: baseStyle));
      if (i < parts.length - 1) { spans.add(TextSpan(text: '(', style: baseStyle)); spans.add(TextSpan(text: 'X', style: baseStyle.copyWith(color: Colors.red))); spans.add(TextSpan(text: ')', style: baseStyle)); }
    }
    return spans;
  }

  Widget _parleTile(String it, bool hi, bool s, bool isWinner, Color statusColor, bool isInvalid) {
    int p = it.indexOf('('); String ns = p != -1 ? it.substring(0, p) : it, mon = p != -1 ? it.substring(p) : '';
    TextDecoration? decor = isInvalid ? TextDecoration.lineThrough : null;
    return Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2), child: IntrinsicHeight(child: Row(children: [Column(crossAxisAlignment: CrossAxisAlignment.start, children: ns.split('-').map((n) => AnimatedBuilder(animation: _blinkController, builder: (context, child) => Text(n.trim(), style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, decoration: decor, color: s ? Colors.red.shade900 : (isWinner ? Color.lerp(Colors.blueAccent, Colors.lightBlueAccent, _blinkController.value) : statusColor))))).toList()), const SizedBox(width: 4), SizedBox(width: 12, child: FittedBox(fit: BoxFit.fill, child: AnimatedBuilder(animation: _blinkController, builder: (context, child) => Text('}', style: TextStyle(color: s ? Colors.redAccent : (isWinner ? Color.lerp(Colors.blueAccent, Colors.lightBlueAccent, _blinkController.value) : statusColor), fontWeight: FontWeight.w100))))), const SizedBox(width: 4), Expanded(child: Center(child: AnimatedBuilder(animation: _blinkController, builder: (context, child) => _richTextWithRedX(mon, TextStyle(fontSize: 13, color: s ? Colors.red.shade900 : (isWinner ? Color.lerp(Colors.blueAccent, Colors.lightBlueAccent, _blinkController.value) : statusColor), fontWeight: FontWeight.bold, decoration: decor)))))])));
  }

  Widget _buildVisor() {
    bool isGeorgia = _activeLoteria == "GEORGIA";
    final themeColor = isGeorgia ? Colors.orange.shade900 : Colors.blue.shade900;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: isGeorgia ? Colors.orange.shade50 : Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isGeorgia ? Colors.orange.shade300 : Colors.blue.shade200, width: 1.5),
      ),
      child: ValueListenableBuilder<int>(
        valueListenable: _activeField,
        builder: (ctx, act, _) {
          ValueNotifier<String> n = act == 0 ? _bolaInput : (act == 1 ? _parleInput : _centenaInput);
          return Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isGeorgia ? Colors.orange.shade800 : Colors.blue.shade800,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LoteriaIcon(
                      loteria: _activeLoteria,
                      size: 14,
                      borderRadius: 2,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isGeorgia ? "GA" : "FL",
                      style: const TextStyle(fontWeight: FontWeight.w900, color: Colors.white, fontSize: 10),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                act == 0 ? 'BOLA' : (act == 1 ? 'PARLE' : 'CENTENA'),
                style: TextStyle(fontWeight: FontWeight.bold, color: themeColor, fontSize: 11),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SingleChildScrollView(
                  controller: _visorScrollController,
                  scrollDirection: Axis.horizontal,
                  child: ValueListenableBuilder<String>(
                    valueListenable: n,
                    builder: (ctx, val, _) => Text(
                      val.isEmpty ? '0' * (act == 2 ? 3 : 2) : val,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        color: isGeorgia ? Colors.orange.shade900 : Colors.blue.shade900,
                      ),
                    ),
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => _handleKeyPress('DEL'),
                onLongPress: () {
                  if (_isKeyboardVisible()) n.value = '';
                  Feedback.forLongPress(context);
                },
                child: const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Icon(Icons.backspace_outlined, color: Colors.orange, size: 20),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildInputSelectors() {
    bool isGeorgia = _activeLoteria == "GEORGIA";
    final sendColor = isGeorgia ? Colors.orange.shade800 : _regentColor;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      child: Row(
        children: [
          _iSel(0, 'BOLA'),
          const SizedBox(width: 8),
          _iSel(1, 'PARLE'),
          const SizedBox(width: 8),
          _iSel(2, 'CENTENA'),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _addRegistro,
            style: ElevatedButton.styleFrom(
              backgroundColor: sendColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 15),
            ),
            child: const Icon(Icons.send, color: Colors.white, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _iSel(int i, String l) {
    const activeColor = Colors.amber;

    return Expanded(
      child: ValueListenableBuilder<int>(
        valueListenable: _activeField,
        builder: (ctx, act, _) => GestureDetector(
          onTap: () => _activeField.value = i,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: act == i ? activeColor : Colors.white24,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                l,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: act == i ? Colors.black : Colors.white70),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNumericKeypad() {
    const List<String> ks = ['7', '8', '9', '4', '5', '6', '1', '2', '3', 'AL', '0', '.'];
    return Padding(
      padding: const EdgeInsets.only(left: 5, right: 10, top: 2, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            flex: 2,
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.only(right: 10),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisExtent: 48,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
              ),
              itemCount: ks.length,
              itemBuilder: (ctx, idx) => _buildKeyBtn(ks[idx]),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _tRow('B:', _bolaItems),
              _tRow('P:', _parleItems),
              _tRow('C:', _centenaItems),
              const SizedBox(height: 2),
              Container(width: 60, height: 1, color: Colors.white24),
              _tRow('L:', null, isL: true),
              const SizedBox(height: 5),
              Container(
                width: 95,
                height: 106,
                margin: const EdgeInsets.only(bottom: 6),
                child: Material(
                  color: const Color(0xFF7A1C1C),
                  borderRadius: BorderRadius.circular(12),
                  elevation: 2,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _handleKeyPress(' ( ) '),
                    child: const Center(
                      child: Text('( )', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildKeyBtn(String k) {
    final bool isSpecial = k == 'AL';
    return Material(
      color: isSpecial ? Colors.amber.shade600 : Colors.white,
      borderRadius: BorderRadius.circular(10),
      elevation: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _handleKeyPress(k),
        onLongPress: (k == 'AL' || RegExp(r'^[0-9]$').hasMatch(k)) ? () => _showSpecialOptions(k) : null,
        child: Center(
          child: Text(k, 
            style: TextStyle(
              fontSize: 20, 
              fontWeight: FontWeight.w900, 
              color: isSpecial ? Colors.black : const Color(0xFF7A1C1C)
            )
          ),
        ),
      ),
    );
  }

  Widget _tRow(String l, ValueNotifier<List<Map<String, dynamic>>>? n, {bool isL = false, bool isPr = false, bool isBal = false}) => ListenableBuilder(listenable: Listenable.merge([_limpioTotal, _premiosTotal, _bolaItems, _parleItems, _centenaItems]), builder: (ctx, _) {
    double lim = _limpioTotal.value;
    double pr = _premiosTotal.value, bal = lim - pr;
    if (isL) return _tTxt(l, lim, c: Colors.amberAccent);
    if (isPr) return _tTxt(l, pr, c: Colors.amberAccent);
    if (isBal) return _tTxt(bal >= 0 ? 'Pierde' : 'Gana', bal.abs(), c: bal >= 0 ? Colors.greenAccent : Colors.amberAccent);
    
    final allItems = [..._bolaItems.value, ..._parleItems.value, ..._centenaItems.value];
    Map<String, double> brutos = {
      "BOLA": RecaudacionService.calculateBruto(allItems, "BOLA"),
      "PARLE": RecaudacionService.calculateBruto(allItems, "PARLE"),
      "CENTENA": RecaudacionService.calculateBruto(allItems, "CENTENA"),
    };
    String tipo = l.startsWith('B:') ? 'BOLA' : (l.startsWith('P:') ? 'PARLE' : 'CENTENA');
    return _tTxt(l, brutos[tipo] ?? 0.0);
  });

  Widget _tTxt(String l, double v, {Color? c}) => Padding(
    padding: const EdgeInsets.only(bottom: 2), 
    child: Row(
      mainAxisSize: MainAxisSize.min, 
      children: [
        Text(l, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white70)), 
        const SizedBox(width: 5), 
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(v.toStringAsFixed(v % 1 == 0 ? 0 : 2), 
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: c ?? Colors.white)
            ),
          ),
        )
      ]
    )
  );

  Widget _buildDrawer() {
    return Drawer(child: Column(children: [DrawerHeader(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_regentColor, _regentColor.withValues(alpha: 0.6)])), child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Hero(tag: "app_logo", child: Container(padding: const EdgeInsets.all(4), decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.1), border: Border.all(color: Colors.white.withValues(alpha: 0.2), width: 1)), child: ClipOval(child: Image.asset('assets/logo.png', height: 60, width: 60, fit: BoxFit.cover)))), const SizedBox(height: 10), Text(_listeroName, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)), Text('S-RECORD $_activeSeccion | $_activeFecha', style: const TextStyle(color: Colors.white70, fontSize: 12))] )))), 
    const Divider(height: 1),
    Expanded(child: ListView(padding: EdgeInsets.zero, children: [
      _dIt(context, Icons.list_alt, 'LISTA', null), 
      _dIt(context, Icons.savings_outlined, 'BOTE', null, isSel: true), 
      const Divider(), 
      ListTile(leading: const Icon(Icons.logout, color: Colors.redAccent), title: const Text('CERRAR SESIÓN', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)), onTap: () async { final prefs = await SharedPreferences.getInstance(); await prefs.remove("logged_listero_name"); await prefs.remove("current_listero_pin"); if (!mounted) return; Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const LoginScreen()), (route) => false); })])), _buildBalanceBadge()]));
  }

  Widget _buildBalanceBadge() {
    return FutureBuilder<double>(
      future: () async {
        final bancoId = await Alex().getActiveBancoId() ?? "UNKNOWN";
        return _db.getLastSaldoFinal(_listeroPin, bancoId: bancoId, loteria: _activeLoteria);
      }(), 
      builder: (context, snapshot) {
        double saldo = snapshot.data ?? 0.0;
        bool listeroDebe = saldo >= 0;
        final baseColor = listeroDebe ? Colors.green : Colors.red;
        return Container(
          width: double.infinity, 
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20), 
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                baseColor.shade50,
                Colors.white,
              ],
            ),
            border: Border(top: BorderSide(color: baseColor.shade200, width: 1.5)),
            boxShadow: [
              BoxShadow(
                color: baseColor.withValues(alpha: 0.15),
                offset: const Offset(0, -4),
                blurRadius: 10,
              ),
            ],
          ), 
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                decoration: BoxDecoration(
                  color: baseColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: baseColor.withValues(alpha: 0.2)),
                ),
                child: const Text(
                  "SALDO TOTAL ACUMULADO", 
                  style: TextStyle(color: Colors.black87, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.2),
                ),
              ),
              const SizedBox(height: 8), 
              FittedBox(
                fit: BoxFit.scaleDown, 
                child: Text(
                  "\$${saldo.abs().toStringAsFixed(saldo.abs() % 1 == 0 ? 0 : 2)}", 
                  style: TextStyle(
                    color: listeroDebe ? Colors.green.shade700 : Colors.red.shade700, 
                    fontSize: 32, 
                    fontWeight: FontWeight.w900, 
                    letterSpacing: -1,
                    shadows: [
                      Shadow(
                        color: baseColor.withValues(alpha: 0.3),
                        offset: const Offset(0, 2),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                ),
              ), 
            ],
          ),
        );
      },
    );
  }

  Widget _dIt(BuildContext ctx, IconData i, String t, Widget? tg, {bool isSel = false}) => ListTile(leading: Icon(i, color: isSel ? _regentColor : Colors.grey.shade600), title: Text(t, style: TextStyle(color: isSel ? _regentColor : Colors.black87, fontWeight: isSel ? FontWeight.bold : FontWeight.normal)), selected: isSel, onTap: () async { Navigator.pop(ctx); if (tg != null) { await Navigator.push(ctx, MaterialPageRoute(builder: (_) => tg)); _loadInitialConfig(); } else if (t == 'LISTA') { Navigator.pushAndRemoveUntil(ctx, MaterialPageRoute(builder: (_) => const ListaScreen()), (route) => false); } });

  Widget _richTextWithRedX(String text, TextStyle baseStyle) {
    if (!text.contains('(X)')) return Text(text, style: baseStyle, overflow: TextOverflow.ellipsis);
    List<TextSpan> spans = []; List<String> parts = text.split('(X)');
    for (int i = 0; i < parts.length; i++) { if (parts[i].isNotEmpty) spans.add(TextSpan(text: parts[i], style: baseStyle)); if (i < parts.length - 1) { spans.add(TextSpan(text: '(', style: baseStyle)); spans.add(TextSpan(text: 'X', style: baseStyle.copyWith(color: Colors.red))); spans.add(TextSpan(text: ')', style: baseStyle)); } }
    return Text.rich(TextSpan(children: spans), overflow: TextOverflow.ellipsis);
  }
}
