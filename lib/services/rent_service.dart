import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';

enum RentFrequency { quincenalDomingo, semanalDomingo, mensual }

class RentService {
  static final RentService _instance = RentService._internal();
  factory RentService() => _instance;
  RentService._internal();

  static const String keyMonto = "rent_monto_usd";
  static const String keyFrecuencia = "rent_frecuencia";
  static const String keyFechaInicio = "rent_fecha_inicio";
  static const String keyUltimoPago = "rent_ultimo_pago_fecha";

  /// Obtiene el monto pactado (ej: 100.0 USD)
  Future<double> getMonto() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(keyMonto) ?? 100.0;
  }

  /// Guarda el monto pactado
  Future<void> setMonto(double monto) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(keyMonto, monto);
  }

  /// Obtiene la frecuencia (por defecto: Quincenal Domingo)
  Future<RentFrequency> getFrecuencia() async {
    final prefs = await SharedPreferences.getInstance();
    final val = prefs.getString(keyFrecuencia) ?? "QUINCENAL_DOMINGO";
    if (val == "SEMANAL_DOMINGO") return RentFrequency.semanalDomingo;
    if (val == "MENSUAL") return RentFrequency.mensual;
    return RentFrequency.quincenalDomingo;
  }

  /// Guarda la frecuencia
  Future<void> setFrecuencia(RentFrequency freq) async {
    final prefs = await SharedPreferences.getInstance();
    String val = "QUINCENAL_DOMINGO";
    if (freq == RentFrequency.semanalDomingo) val = "SEMANAL_DOMINGO";
    if (freq == RentFrequency.mensual) val = "MENSUAL";
    await prefs.setString(keyFrecuencia, val);
  }

  /// Obtiene la fecha de inicio del pacto (primer domingo de cobro)
  Future<DateTime> getFechaInicio() async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString(keyFechaInicio);
    if (str != null) {
      try { return DateTime.parse(str); } catch (_) {}
    }
    final now = DateTime.now();
    int daysUntilSunday = (DateTime.sunday - now.weekday) % 7;
    return DateTime(now.year, now.month, now.day).add(Duration(days: daysUntilSunday));
  }

  /// Establece la fecha de inicio del pacto
  Future<void> setFechaInicio(DateTime date) async {
    final prefs = await SharedPreferences.getInstance();
    final clean = DateTime(date.year, date.month, date.day);
    await prefs.setString(keyFechaInicio, clean.toIso8601String().substring(0, 10));
  }

  /// Obtiene la fecha del último pago registrado
  Future<String?> getUltimoPagoFecha() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(keyUltimoPago);
  }

  /// Registra el pago del periodo
  Future<void> registrarPago(DateTime fechaPago) async {
    final prefs = await SharedPreferences.getInstance();
    final cleanStr = DateTime(fechaPago.year, fechaPago.month, fechaPago.day).toIso8601String().substring(0, 10);
    await prefs.setString(keyUltimoPago, cleanStr);
  }

  /// Cancela o deshace un pago registrado
  Future<void> cancelarPago() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(keyUltimoPago);
  }

  /// Verifica si HOY es un día de cobro pactado
  Future<bool> isTodayPaymentDay() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (today.weekday != DateTime.sunday) return false;

    final start = await getFechaInicio();
    final freq = await getFrecuencia();

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
  Future<bool> isCurrentPeriodPaid() async {
    final lastPaid = await getUltimoPagoFecha();
    if (lastPaid == null) return false;
    final now = DateTime.now();
    final todayStr = DateTime(now.year, now.month, now.day).toIso8601String().substring(0, 10);
    return lastPaid == todayStr;
  }

  /// Genera el calendario anual de cobros pactados
  Future<List<Map<String, dynamic>>> getAnnualSchedule({int? year}) async {
    final targetYear = year ?? DateTime.now().year;
    final start = await getFechaInicio();
    final freq = await getFrecuencia();
    final lastPaid = await getUltimoPagoFecha();

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
          "formatted": DateFormat('EEEE d, MMMM yyyy', 'es').format(currentSunday),
          "status": status,
          "isPaid": isPaid,
        });
      }

      currentSunday = currentSunday.add(const Duration(days: 7));
    }

    return schedule;
  }
}
