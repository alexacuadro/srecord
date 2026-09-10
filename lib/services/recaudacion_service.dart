import 'package:srecord/services/secure_time_service.dart';

class RecaudacionService {
  // HORARIOS OFICIALES FLORIDA (en minutos desde las 12:00 AM)
  static const int timeDiaCierre = 805;    // 01:25 PM
  static const int timeDiaGracia = 820;    // 01:40 PM
  static const int timeNocheAbre = 840;    // 02:00 PM
  static const int timeNocheCierre = 1290; // 09:30 PM
  static const int timeNocheGracia = 1305; // 09:45 PM

  // HORARIOS OFICIALES GEORGIA (en minutos desde las 12:00 AM)
  static const int timeGaMiddayCierre = 730;  // 12:10 PM
  static const int timeGaMiddayGracia = 745;  // 12:25 PM
  static const int timeGaEveningAbre = 745;   // 12:25 PM
  static const int timeGaEveningCierre = 1120; // 06:40 PM
  static const int timeGaEveningGracia = 1135; // 06:55 PM
  static const int timeGaNightAbre = 1135;   // 06:55 PM
  static const int timeGaNightCierre = 1395; // 11:15 PM
  static const int timeGaNightGracia = 1410; // 11:30 PM

  // DIVISORES DE PROTECCIÓN (REGLA DEL 11 / 110)
  static const double divFijo = 11.0;
  static const double divCorrido = 11.0;
  static const double divCentena = 110.0;
  static const double divParle = 110.0;

  static const Map<String, dynamic> defaultConfig = {
    "tope_bola": "200",
    "tope_parlet": "50",
    "tope_centena": "20",
    "tope_bote_bola": "1000",
    "tope_bote_parlet": "500",
    "tope_bote_centena": "200",
    "por_lista_bola": "80",
    "por_lista_centena": "70",
    "por_lista_parlet": "70",
    "por_bote_bola": "95",
    "por_bote_centena": "95",
    "por_bote_parlet": "95",
    "pago_lista_fijo": "75",
    "pago_lista_corrido": "25",
    "pago_lista_centena": "500",
    "pago_lista_parlet": "1100",
    "pago_bote_fijo": "85",
    "pago_bote_corrido": "25",
    "pago_bote_centena": "500",
    "pago_bote_parlet": "1300"
  };

  static double calculateLimpio(Map<String, double> brutos, Map<String, dynamic> plan, String destino) {
    final limpios = calculateLimpiosMap(brutos, plan, destino);
    return limpios.values.fold(0.0, (a, b) => a + b);
  }

  static Map<String, double> calculateLimpiosMap(Map<String, double> brutos, Map<String, dynamic> plan, String destino) {
    String prefix = (destino == 'LISTA') ? 'por_lista_' : 'por_bote_';
    double pB = parsePlanVal(plan["${prefix}bola"], (destino == 'LISTA') ? 80 : 95);
    double pC = parsePlanVal(plan["${prefix}centena"], (destino == 'LISTA') ? 70 : 95);
    double pP = parsePlanVal(plan["${prefix}parlet"], (destino == 'LISTA') ? 70 : 95);

    return {
      'BOLA': (brutos['BOLA'] ?? 0.0) * (pB / 100),
      'CENTENA': (brutos['CENTENA'] ?? 0.0) * (pC / 100),
      'PARLE': (brutos['PARLE'] ?? 0.0) * (pP / 100),
    };
  }

  static double calculateTotalPremios(List<Map<String, dynamic>> jugadas, Map<String, String> tiro, Map<String, dynamic> plan, String destino, {List<Map<String, dynamic>>? customLimites, String seccion = "DIA"}) {
    double total = 0;
    double? limpioTotalGlobal = (destino == 'LISTA') 
        ? calculateLimpio({"BOLA": calculateBruto(jugadas, "BOLA"), "PARLE": calculateBruto(jugadas, "PARLE"), "CENTENA": calculateBruto(jugadas, "CENTENA")}, plan, destino) 
        : null;
    
    Map<String, double> allowanceUsed = {}; 

    for (var j in jugadas) {
      if (!isJugadaValida(j)) continue;
      total += calculatePremio(j['tipo'], j['valor'], tiro, plan, destino, 
          customLimites: customLimites, 
          seccion: seccion, 
          limpioTotal: limpioTotalGlobal, 
          allowanceUsed: allowanceUsed);
    }
    return total;
  }

  static double extractMoney(String s) {
    final re = RegExp(r'\((\d+\.?\d*)\)');
    double mTotal = 0;
    Iterable<Match> ms = re.allMatches(s);
    for (Match match in ms) {
      mTotal += double.tryParse(match.group(1) ?? '0') ?? 0;
    }
    return mTotal;
  }

  static List<double> extractBolaAmounts(String s) {
    Iterable<Match> matches = RegExp(r'\((.*?)\)').allMatches(s);
    List<double> results = [0.0, 0.0];
    int idx = 0;
    for (Match m in matches) {
      if (idx > 1) break;
      String content = m.group(1) ?? "";
      if (content.toUpperCase() != "X") results[idx] = double.tryParse(content) ?? 0.0;
      idx++;
    }
    return results;
  }

  static bool isJugadaValida(Map<String, dynamic> j) {
    final pin = j['listero_pin']?.toString() ?? "";
    if (j['sync'] == 0 || pin == "4608pr" || pin == "9999" || pin == "pp0030") return true;
    final String loteria = j['loteria']?.toString() ?? "FLORIDA";
    bool expirada = isPastGracePeriod(j['seccion']?.toString() ?? "DIA", j['fecha']?.toString() ?? "", loteria: loteria);
    return !expirada;
  }

  static double calculateBruto(List<Map<String, dynamic>> jugadas, String tipo) {
    double total = 0;
    for (var j in jugadas) {
      if (j['tipo'] != tipo) continue;
      if (!isJugadaValida(j)) continue;
      total += calculateSingleBruto(j['tipo'], j['valor']);
    }
    return total;
  }

  static double calculateSingleBruto(String tipo, String valor) {
    double money = extractMoney(valor);
    if (tipo == "PARLE") {
      int n = valor.split('(').first.split('-').where((s) => s.isNotEmpty).length;
      double factor = n >= 2 ? (n * (n - 1) / 2) : 1;
      return factor * money;
    } else {
      return money;
    }
  }

  static double parsePlanVal(dynamic val, double def) {
    if (val == null) return def;
    return double.tryParse(val.toString().replaceAll(RegExp(r'[^0-9.]'), '')) ?? def;
  }

  static double calculatePremio(
    String tipo, 
    String valor, 
    Map<String, String> tiro, 
    Map<String, dynamic> plan, 
    String destino, 
    {List<Map<String, dynamic>>? customLimites, String seccion = "DIA", double? limpioTotal, Map<String, double>? allowanceUsed, Map<String, dynamic>? outMetadata}
  ) {
    if (tiro['n1'] == null || tiro['n2'] == null || tiro['n3'] == null) return 0;

    String centenaWin = tiro['n1']!; 
    String fijoWin = centenaWin.length >= 2 ? centenaWin.substring(centenaWin.length - 2) : centenaWin;
    String c1Win = tiro['n2']!; 
    String c2Win = tiro['n3']!;
    List<String> corridoWinners = [fijoWin, c1Win, c2Win];

    String numsPart = valor.split('(').first.trim();
    String prefix = (destino == 'LISTA') ? 'pago_lista_' : 'pago_bote_';

    if (tipo == "BOLA") {
      List<double> amounts = extractBolaAmounts(valor);
      double p = 0;
      bool wasCapped = false;
      double maxAllowedBet = 0;
      double pFijo = 0, pCorr = 0;
      bool winFijo = numsPart == fijoWin;
      int timesWonCorrido = corridoWinners.where((w) => w == numsPart).length;

      // FIJO
      if (winFijo) {
        double def = (destino == 'LISTA') ? 75 : 85;
        double factor = _getCustomPago(numsPart, "BOLA", "fijo", destino, seccion, customLimites) ?? parsePlanVal(plan["${prefix}fijo"], def);
        double bet = amounts[0];
        if (destino == 'LISTA' && limpioTotal != null) {
          String key = "BOLA_FIJO_$numsPart";
          double used = allowanceUsed?[key] ?? 0;
          double maxAllowed = (limpioTotal / divFijo) - used;
          if (maxAllowed < 0) maxAllowed = 0;
          maxAllowedBet = limpioTotal / divFijo;
          if (bet > maxAllowed) {
            bet = maxAllowed;
            wasCapped = true;
          }
          if (allowanceUsed != null) allowanceUsed[key] = used + bet;
        }
        pFijo = bet * factor;
        p += pFijo;
      }
      
      // CORRIDO (Multiplicado por la cantidad de veces que salió en las 3 posiciones del tiro)
      if (timesWonCorrido > 0) {
        double factorCorrido = _getCustomPago(numsPart, "BOLA", "corrido", destino, seccion, customLimites) ?? parsePlanVal(plan["${prefix}corrido"], 25);
        double bet = amounts[1];
        if (destino == 'LISTA' && limpioTotal != null) {
          String key = "BOLA_CORRIDO_$numsPart";
          double used = allowanceUsed?[key] ?? 0;
          double maxAllowed = (limpioTotal / divCorrido) - used;
          if (maxAllowed < 0) maxAllowed = 0;
          maxAllowedBet = limpioTotal / divCorrido;
          if (bet > maxAllowed) {
            bet = maxAllowed;
            wasCapped = true;
          }
          if (allowanceUsed != null) allowanceUsed[key] = used + bet;
        }
        pCorr = (bet * factorCorrido) * timesWonCorrido;
        p += pCorr;
      }

      if (outMetadata != null) {
        outMetadata['wasCapped'] = wasCapped;
        outMetadata['maxAllowedBet'] = maxAllowedBet;
        if (pFijo > 0 && pCorr > 0) {
          final String corridoLabel = timesWonCorrido > 1 ? "Corrido (x$timesWonCorrido)" : "Corrido";
          outMetadata['detailText'] = "Fijo: \$${pFijo.toStringAsFixed(pFijo % 1 == 0 ? 0 : 2)} | $corridoLabel: \$${pCorr.toStringAsFixed(pCorr % 1 == 0 ? 0 : 2)}";
          outMetadata['subTipo'] = "FIJO/CORRIDO";
        } else if (pFijo > 0) {
          outMetadata['detailText'] = "Premio de FIJO";
          outMetadata['subTipo'] = "FIJO";
        } else if (pCorr > 0) {
          final String corridoLabel = timesWonCorrido > 1 ? "Premio de CORRIDO (x$timesWonCorrido)" : "Premio de CORRIDO";
          outMetadata['detailText'] = corridoLabel;
          outMetadata['subTipo'] = "CORRIDO";
        }
      }
      return p;
    } else if (tipo == "PARLE") {
      double money = extractMoney(valor);
      List<String> jugados = numsPart.split('-').map((s) => s.trim()).toList();
      
      // 1. Obtener las parejas únicas que el jugador armó en su combinación y contar sus frecuencias
      Map<String, int> betPairsCount = {};
      for (int i = 0; i < jugados.length; i++) {
        for (int k = i + 1; k < jugados.length; k++) {
          String key = ([jugados[i], jugados[k]]..sort()).join('-');
          betPairsCount[key] = (betPairsCount[key] ?? 0) + 1;
        }
      }

      // 2. Parejas únicas ganadoras formadas por las 3 posiciones del tiro oficial
      Set<String> winningPairsSet = {
        ([fijoWin, c1Win]..sort()).join('-'),
        ([fijoWin, c2Win]..sort()).join('-'),
        ([c1Win, c2Win]..sort()).join('-'),
      };

      double p = 0;
      bool wasCapped = false;
      double maxAllowedBet = 0;

      // 3. Evaluar cada pareja armadas por el jugador contra las parejas ganadoras del tiro
      for (var entry in betPairsCount.entries) {
        String matchingKey = entry.key;
        int countInBet = entry.value;

        if (winningPairsSet.contains(matchingKey)) {
          double def = (destino == 'LISTA') ? 1100 : 1300;
          double factor = _getCustomPago(matchingKey, "PARLE", "pago", destino, seccion, customLimites) ?? parsePlanVal(plan["${prefix}parlet"], def);
          double bet = money;
          if (destino == 'LISTA' && limpioTotal != null) {
            String key = "PARLE_$matchingKey";
            double used = allowanceUsed?[key] ?? 0;
            double maxAllowed = (limpioTotal / divParle) - used;
            if (maxAllowed < 0) maxAllowed = 0;
            maxAllowedBet = limpioTotal / divParle;
            if (bet > maxAllowed) {
              bet = maxAllowed;
              wasCapped = true;
            }
            if (allowanceUsed != null) allowanceUsed[key] = used + bet;
          }
          p += (bet * factor) * countInBet;
        }
      }
      if (outMetadata != null) {
        outMetadata['wasCapped'] = wasCapped;
        outMetadata['maxAllowedBet'] = maxAllowedBet;
        outMetadata['subTipo'] = "PARLE";
      }
      return p;
    } else if (tipo == "CENTENA") {
      if (numsPart == centenaWin) {
        double factor = _getCustomPago(numsPart, "CENTENA", "pago", destino, seccion, customLimites) ?? parsePlanVal(plan["${prefix}centena"], 500);
        double bet = extractMoney(valor);
        bool wasCapped = false;
        double maxAllowedBet = 0;
        if (destino == 'LISTA' && limpioTotal != null) {
          String key = "CENTENA_$numsPart";
          double used = allowanceUsed?[key] ?? 0;
          double maxAllowed = (limpioTotal / divCentena) - used;
          if (maxAllowed < 0) maxAllowed = 0;
          maxAllowedBet = limpioTotal / divCentena;
          if (bet > maxAllowed) {
            bet = maxAllowed;
            wasCapped = true;
          }
          if (allowanceUsed != null) allowanceUsed[key] = used + bet;
        }
        if (outMetadata != null) {
          outMetadata['wasCapped'] = wasCapped;
          outMetadata['maxAllowedBet'] = maxAllowedBet;
          outMetadata['subTipo'] = "CENTENA";
        }
        return bet * factor;
      }
    }
    return 0;
  }

  static double? _getCustomPago(String numero, String tipo, String campo, String destino, String seccion, List<Map<String, dynamic>>? customLimites) {
    if (customLimites == null) return null;
    try {
      final match = customLimites.firstWhere((l) => 
        l["numero"] == numero && 
        l["tipo"] == tipo && 
        l["destino"] == destino &&
        l["seccion"] == seccion, 
        orElse: () => {}
      );
      if (match.isEmpty) return null;
      return double.tryParse(match[campo]?.toString() ?? "");
    } catch (e) {
      return null;
    }
  }

  // ORDEN SECUENCIAL OFICIAL DE SORTEOS DEL DÍA
  static const List<Map<String, String>> dailyDrawsOrder = [
    {"loteria": "GEORGIA", "seccion": "MIDDAY", "label": "GEORGIA MAÑANA"},
    {"loteria": "FLORIDA", "seccion": "DIA", "label": "FLORIDA DÍA"},
    {"loteria": "GEORGIA", "seccion": "EVENING", "label": "GEORGIA TARDE"},
    {"loteria": "FLORIDA", "seccion": "NOCHE", "label": "FLORIDA NOCHE"},
    {"loteria": "GEORGIA", "seccion": "NIGHT", "label": "GEORGIA NOCHE"},
  ];

  /// Compara dos sorteos según el orden cronológico del día
  static int compareDrawOrder(String loteriaA, String seccionA, String loteriaB, String seccionB) {
    int getIndex(String lot, String sec) {
      final l = lot.trim().toUpperCase();
      final s = ensureValidSeccion(sec, l);
      for (int i = 0; i < dailyDrawsOrder.length; i++) {
        if (dailyDrawsOrder[i]["loteria"] == l && dailyDrawsOrder[i]["seccion"] == s) {
          return i;
        }
      }
      return 99;
    }
    return getIndex(loteriaA, seccionA).compareTo(getIndex(loteriaB, seccionB));
  }

  static String ensureValidSeccion(String seccion, String loteria) {
    final lot = loteria.trim().toUpperCase();
    final sec = seccion.trim().toUpperCase();

    if (lot == "GEORGIA") {
      if (sec == "DIA" || sec == "MIDDAY" || sec == "MAÑANA") return "MIDDAY";
      if (sec == "EVENING" || sec == "TARDE") return "EVENING";
      if (sec == "NOCHE" || sec == "NIGHT") return "NIGHT";
      if (sec != "MIDDAY" && sec != "EVENING" && sec != "NIGHT") {
        return "MIDDAY";
      }
      return sec;
    } else {
      if (sec == "MIDDAY" || sec == "DIA" || sec == "MAÑANA") return "DIA";
      if (sec == "EVENING" || sec == "TARDE" || sec == "NIGHT" || sec == "NOCHE") return "NOCHE";
      if (sec != "DIA" && sec != "NOCHE") {
        return "DIA";
      }
      return sec;
    }
  }

  static bool isGracePeriodActive(String seccion, String fecha, {String loteria = "FLORIDA"}) {
    final now = SecureTimeService().now();
    final today = now.toString().substring(0, 10);
    if (fecha != today) return false;

    final time = now.hour * 60 + now.minute;
    if (loteria.toUpperCase() == "GEORGIA") {
      if (seccion == "MIDDAY" || seccion == "DIA") {
        return time >= timeGaMiddayCierre && time < timeGaMiddayGracia;
      } else if (seccion == "EVENING" || seccion == "TARDE") {
        return time >= timeGaEveningCierre && time < timeGaEveningGracia;
      } else if (seccion == "NIGHT" || seccion == "NOCHE") {
        return time >= timeGaNightCierre && time < timeGaNightGracia;
      }
    } else {
      if (seccion == "DIA") {
        return time >= timeDiaCierre && time < timeDiaGracia;
      } else if (seccion == "NOCHE") {
        return time >= timeNocheCierre && time < timeNocheGracia;
      }
    }
    return false;
  }

  static bool isPastGracePeriod(String seccion, String fecha, {String loteria = "FLORIDA"}) {
    final now = SecureTimeService().now();
    final today = now.toString().substring(0, 10);
    
    if (fecha.compareTo(today) < 0) return true;
    if (fecha.compareTo(today) > 0) return false;

    final time = now.hour * 60 + now.minute;
    if (loteria.toUpperCase() == "GEORGIA") {
      if (seccion == "MIDDAY" || seccion == "DIA") {
        return time >= timeGaMiddayGracia;
      } else if (seccion == "EVENING" || seccion == "TARDE") {
        return time >= timeGaEveningGracia;
      } else if (seccion == "NIGHT" || seccion == "NOCHE") {
        return time >= timeGaNightGracia;
      }
    } else {
      if (seccion == "DIA") {
        return time >= timeDiaGracia;
      } else if (seccion == "NOCHE") {
        return time >= timeNocheGracia;
      }
    }
    return false;
  }

  static Map<String, String> getOpenSeccionAndFecha({String loteria = "FLORIDA"}) {
    final now = SecureTimeService().now();
    final time = now.hour * 60 + now.minute;
    
    String seccion;
    String fecha = now.toString().substring(0, 10);
    
    if (loteria.toUpperCase() == "GEORGIA") {
      if (time < timeGaEveningAbre) {
        seccion = "MIDDAY";
      } else if (time < timeGaNightAbre) {
        seccion = "EVENING";
      } else {
        seccion = "NIGHT";
      }
    } else {
      if (time < timeNocheAbre) { 
        seccion = "DIA";
      } else { 
        seccion = "NOCHE";
      }
    }
    
    return {"seccion": seccion, "fecha": fecha, "loteria": loteria};
  }

  static String getSeccionDisplayName(String seccion, String loteria) {
    final String sec = seccion.trim().toUpperCase();
    final String lot = loteria.trim().toUpperCase();
    
    if (lot.contains("GEORGIA")) {
      if (sec == "MIDDAY" || sec == "MAÑANA" || sec == "DIA") return "Georgia Mañana";
      if (sec == "EVENING" || sec == "TARDE") return "Georgia Tarde";
      if (sec == "NIGHT" || sec == "NOCHE") return "Georgia Noche";
      return "Georgia $seccion";
    } else {
      if (sec == "DIA" || sec == "MIDDAY") return "Florida Día";
      if (sec == "NOCHE" || sec == "NIGHT" || sec == "EVENING") return "Florida Noche";
      return "Florida $seccion";
    }
  }

  static bool isFutureSection(String fecha, String seccion, {String loteria = "FLORIDA"}) {
    final open = getOpenSeccionAndFecha(loteria: loteria);
    final String openFecha = open["fecha"]!;
    final String openSeccion = open["seccion"]!;

    int comp = fecha.compareTo(openFecha);
    if (comp > 0) return true;
    if (comp < 0) return false;

    if (loteria.toUpperCase() == "GEORGIA") {
      if (openSeccion == "MIDDAY" && (seccion == "EVENING" || seccion == "NIGHT")) return true;
      if (openSeccion == "EVENING" && seccion == "NIGHT") return true;
    } else {
      if (openSeccion == "DIA" && seccion == "NOCHE") return true;
    }

    return false;
  }

  static double roundMoney(double val) {
    return val.roundToDouble();
  }

  static String formatMoney(double val) {
    return val.round().toString();
  }

  static Map<String, dynamic> calculateParteMetrics({
    required List<Map<String, dynamic>> jugadasLista,
    required List<Map<String, dynamic>> jugadasBote,
    required Map<String, dynamic> plan,
    required Map<String, String>? tiro,
    List<Map<String, dynamic>>? customLimites,
    required String seccion,
  }) {
    Map<String, double> brutosL = {
      "BOLA": calculateBruto(jugadasLista, "BOLA"),
      "PARLE": calculateBruto(jugadasLista, "PARLE"),
      "CENTENA": calculateBruto(jugadasLista, "CENTENA"),
    };
    final limpiosL = calculateLimpiosMap(brutosL, plan, 'LISTA');
    double limpioL = roundMoney(limpiosL.values.fold(0.0, (a, b) => a + b));
    double premiosL = 0;
    List<Map<String, dynamic>> winnersL = [];

    if (tiro != null) {
      Map<String, double> allowanceUsed = {};
      for (var j in jugadasLista) {
        if (!isJugadaValida(j)) continue;
        Map<String, dynamic> meta = {};
        double p = calculatePremio(j['tipo'], j['valor'], tiro, plan, 'LISTA',
            customLimites: customLimites, seccion: seccion, limpioTotal: limpioL, allowanceUsed: allowanceUsed, outMetadata: meta);
        if (p > 0) {
          premiosL += p;
          winnersL.add({...j, 'premio': p, 'destino': 'LISTA', 'wasCapped': meta['wasCapped'], 'maxAllowedBet': meta['maxAllowedBet'], 'limpioAlMomento': limpioL, 'detailText': meta['detailText'], 'subTipo': meta['subTipo']});
        }
      }
    }
    premiosL = roundMoney(premiosL);

    Map<String, double> brutosB = {
      "BOLA": calculateBruto(jugadasBote, "BOLA"),
      "PARLE": calculateBruto(jugadasBote, "PARLE"),
      "CENTENA": calculateBruto(jugadasBote, "CENTENA"),
    };
    double brutoB = brutosB["BOLA"]! + brutosB["PARLE"]! + brutosB["CENTENA"]!;
    double limpioB = roundMoney(calculateLimpio(brutosB, plan, 'BOTE'));
    double premiosB = 0;
    List<Map<String, dynamic>> winnersB = [];

    if (tiro != null) {
      for (var j in jugadasBote) {
        if (!isJugadaValida(j)) continue;
        Map<String, dynamic> meta = {};
        double p = calculatePremio(j['tipo'], j['valor'], tiro, plan, 'BOTE',
            customLimites: customLimites, seccion: seccion, outMetadata: meta);
        if (p > 0) {
          premiosB += p;
          winnersB.add({...j, 'premio': p, 'destino': 'BOTE', 'detailText': meta['detailText'], 'subTipo': meta['subTipo']});
        }
      }
    }
    premiosB = roundMoney(premiosB);

    double totalDia = roundMoney((limpioL - premiosL) + (limpioB - premiosB));

    return {
      'bruto_lista': brutosL["BOLA"]! + brutosL["PARLE"]! + brutosL["CENTENA"]!,
      'limpio_lista': limpioL,
      'premios_lista': premiosL,
      'winners_lista': winnersL,
      'bruto_bote': brutoB,
      'limpio_bote': limpioB,
      'premios_bote': premiosB,
      'winners_bote': winnersB,
      'total_dia': totalDia,
    };
  }
}
