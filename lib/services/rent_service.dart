import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum RentFrequency { quincenalDomingo, semanalDomingo, mensual }

class RentService {
  static final RentService _instance = RentService._internal();
  factory RentService() => _instance;
  RentService._internal();

  /// Formatea la fecha de forma nativa sin depender de locale de intl
  static String formatSpanishDate(DateTime dt) {
    const days = ["Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado", "Domingo"];
    const months = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"];
    String dayName = days[dt.weekday - 1];
    String monthName = months[dt.month - 1];
    return "$dayName ${dt.day} de $monthName, ${dt.year}";
  }

  /// Obtiene el monto pactado para un banco (ej: 100.0 USD)
  Future<double> getMonto({String? bancoId}) async {
    final prefs = await SharedPreferences.getInstance();
    final bId = bancoId ?? prefs.getString("active_banco_id") ?? "DEFAULT";
    return prefs.getDouble("rent_monto_$bId") ?? 100.0;
  }

  /// Guarda el monto pactado para un banco
  Future<void> setMonto(double monto, {String? bancoId}) async {
    final prefs = await SharedPreferences.getInstance();
    final bId = bancoId ?? prefs.getString("active_banco_id") ?? "DEFAULT";
    await prefs.setDouble("rent_monto_$bId", monto);
  }

  /// Obtiene la frecuencia de un banco
  Future<RentFrequency> getFrecuencia({String? bancoId}) async {
    final prefs = await SharedPreferences.getInstance();
    final bId = bancoId ?? prefs.getString("active_banco_id") ?? "DEFAULT";
    final val = prefs.getString("rent_frecuencia_$bId") ?? "QUINCENAL_DOMINGO";
    if (val == "SEMANAL_DOMINGO") return RentFrequency.semanalDomingo;
    if (val == "MENSUAL") return RentFrequency.mensual;
    return RentFrequency.quincenalDomingo;
  }

  /// Guarda la frecuencia de un banco
  Future<void> setFrecuencia(RentFrequency freq, {String? bancoId}) async {
    final prefs = await SharedPreferences.getInstance();
    final bId = bancoId ?? prefs.getString("active_banco_id") ?? "DEFAULT";
    String val = "QUINCENAL_DOMINGO";
    if (freq == RentFrequency.semanalDomingo) val = "SEMANAL_DOMINGO";
    if (freq == RentFrequency.mensual) val = "MENSUAL";
    await prefs.setString("rent_frecuencia_$bId", val);
  }

  /// Obtiene la fecha de inicio del pacto
  Future<DateTime> getFechaInicio({String? bancoId}) async {
    final prefs = await SharedPreferences.getInstance();
    final bId = bancoId ?? prefs.getString("active_banco_id") ?? "DEFAULT";
    final str = prefs.getString("rent_fecha_inicio_$bId");
    if (str != null) {
      try { return DateTime.parse(str); } catch (_) {}
    }
    final now = DateTime.now();
    int daysUntilSunday = (DateTime.sunday - now.weekday) % 7;
    return DateTime(now.year, now.month, now.day).add(Duration(days: daysUntilSunday));
  }

  /// Establece la fecha de inicio del pacto
  Future<void> setFechaInicio(DateTime date, {String? bancoId}) async {
    final prefs = await SharedPreferences.getInstance();
    final bId = bancoId ?? prefs.getString("active_banco_id") ?? "DEFAULT";
    final clean = DateTime(date.year, date.month, date.day);
    await prefs.setString("rent_fecha_inicio_$bId", clean.toIso8601String().substring(0, 10));
  }

  /// Obtiene la fecha del último pago registrado
  Future<String?> getUltimoPagoFecha({String? bancoId}) async {
    final prefs = await SharedPreferences.getInstance();
    final bId = bancoId ?? prefs.getString("active_banco_id") ?? "DEFAULT";
    return prefs.getString("rent_ultimo_pago_$bId");
  }

  /// Registra el pago del periodo
  Future<void> registrarPago(DateTime fechaPago, {String? bancoId}) async {
    final prefs = await SharedPreferences.getInstance();
    final bId = bancoId ?? prefs.getString("active_banco_id") ?? "DEFAULT";
    final cleanStr = DateTime(fechaPago.year, fechaPago.month, fechaPago.day).toIso8601String().substring(0, 10);
    await prefs.setString("rent_ultimo_pago_$bId", cleanStr);
  }

  /// Cancela o deshace un pago registrado
  Future<void> cancelarPago({String? bancoId}) async {
    final prefs = await SharedPreferences.getInstance();
    final bId = bancoId ?? prefs.getString("active_banco_id") ?? "DEFAULT";
    await prefs.remove("rent_ultimo_pago_$bId");
  }

  /// Verifica si HOY es un día de cobro pactado para el banco
  Future<bool> isTodayPaymentDay({String? bancoId}) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (today.weekday != DateTime.sunday) return false;

    final start = await getFechaInicio(bancoId: bancoId);
    final freq = await getFrecuencia(bancoId: bancoId);

    if (freq == RentFrequency.semanalDomingo) {
      return true;
    } else if (freq == RentFrequency.quincenalDomingo) {
      final differenceInDays = today.difference(start).inDays;
      if (differenceInDays < 0) return false;
      final weeks = (differenceInDays / 7).round();
      return weeks % 2 == 0;
    }
    return false;
  }

  /// Verifica si el cobro del día actual ya fue saldado
  Future<bool> isCurrentPeriodPaid({String? bancoId}) async {
    final lastPaid = await getUltimoPagoFecha(bancoId: bancoId);
    if (lastPaid == null) return false;
    final now = DateTime.now();
    final todayStr = DateTime(now.year, now.month, now.day).toIso8601String().substring(0, 10);
    return lastPaid == todayStr;
  }

  /// Genera el calendario anual de cobros pactados para un banco
  Future<List<Map<String, dynamic>>> getAnnualSchedule({String? bancoId, int? year}) async {
    final targetYear = year ?? DateTime.now().year;
    final start = await getFechaInicio(bancoId: bancoId);
    final freq = await getFrecuencia(bancoId: bancoId);
    final lastPaid = await getUltimoPagoFecha(bancoId: bancoId);

    List<Map<String, dynamic>> schedule = [];
    DateTime currentSunday = DateTime(targetYear, 1, 1);
    int daysUntilFirstSunday = (DateTime.sunday - currentSunday.weekday) % 7;
    currentSunday = currentSunday.add(Duration(days: daysUntilFirstSunday));

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    while (currentSunday.year == targetYear) {
      bool isPactDay = false;
      if (freq == RentFrequency.semanalDomingo) {
        isPactDay = true;
      } else if (freq == RentFrequency.quincenalDomingo) {
        final diffDays = currentSunday.difference(start).inDays;
        final weeks = (diffDays / 7).round();
        isPactDay = (weeks % 2 == 0);
      }

      if (isPactDay) {
        final dateStr = currentSunday.toIso8601String().substring(0, 10);
        bool isPaid = (lastPaid != null && lastPaid == dateStr);
        
        String status = "FUTURO";
        if (isPaid) {
          status = "SALDADO";
        } else if (currentSunday.isBefore(today)) {
          status = "VENCIDO";
        } else if (currentSunday.isAtSameMomentAs(today)) {
          status = "COBRO_HOY";
        }

        schedule.add({
          "date": currentSunday,
          "dateStr": dateStr,
          "formatted": formatSpanishDate(currentSunday),
          "status": status,
          "isPaid": isPaid,
        });
      }

      currentSunday = currentSunday.add(const Duration(days: 7));
    }

    return schedule;
  }
}
