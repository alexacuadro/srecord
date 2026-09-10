import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/services/database_helper.dart';

class SpecialDaysService {
  static final Map<String, String> _specialDays = {
    "01-01": "¡Feliz Año Nuevo!",
    "02-14": "¡Feliz Día de San Valentín!",
    "05-01": "¡Feliz Día del Trabajador!",
    "06-01": "¡Feliz Día del Niño!",
    // Fechas variables como Día de las Madres/Padres suelen ser domingos específicos.
    // Para simplificar, añadiremos fechas fijas comunes o lógica de cálculo.
  };

  static Future<void> checkAndNotify() async {
    final now = DateTime.now();
    final String dateKey = "${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
    final String todayStr = now.toString().substring(0, 10);
    
    final prefs = await SharedPreferences.getInstance();
    final String? lastCheck = prefs.getString("last_special_day_check");
    
    if (lastCheck == todayStr) return; // Ya se comprobó hoy

    String? message = _specialDays[dateKey];

    // Lógica para Día de las Madres (Segundo domingo de Mayo)
    if (now.month == 5) {
      if (_isNthWeekdayOfMonth(now, 2, DateTime.sunday)) {
        message = "¡Feliz Día de las Madres!";
      }
    }

    // Lógica para Día de los Padres (Tercer domingo de Junio)
    if (now.month == 6) {
      if (_isNthWeekdayOfMonth(now, 3, DateTime.sunday)) {
        message = "¡Feliz Día de los Padres!";
      }
    }

    if (message != null) {
      await DatabaseHelper().insertNotificacion(
        "FECHA ESPECIAL", 
        message,
        bancoId: "SYSTEM"
      );
    }

    await prefs.setString("last_special_day_check", todayStr);
  }

  static bool _isNthWeekdayOfMonth(DateTime date, int n, int weekday) {
    if (date.weekday != weekday) return false;
    int count = 0;
    DateTime temp = DateTime(date.year, date.month, 1);
    while (temp.day <= date.day) {
      if (temp.weekday == weekday) count++;
      temp = temp.add(const Duration(days: 1));
    }
    return count == n;
  }
}
