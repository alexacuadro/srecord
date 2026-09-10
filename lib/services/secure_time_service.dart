import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SecureTimeService {
  static final SecureTimeService _instance = SecureTimeService._internal();
  factory SecureTimeService() => _instance;
  SecureTimeService._internal();

  Duration _offset = Duration.zero;
  bool _isSynced = false;
  bool get isSynced => _isSynced;

  /// Sincroniza la hora local con el servidor de Supabase
  Future<void> sync() async {
    try {
      final client = Supabase.instance.client;
      
      // Intentar obtener la hora del servidor SQL
      final List<dynamic> res = await client.rpc('get_server_time');
      final DateTime serverTime = DateTime.parse(res.first['now']).toUtc();
      final DateTime localTime = DateTime.now().toUtc();
      
      _offset = serverTime.difference(localTime);
      _isSynced = true;
      
      if (_offset.inSeconds.abs() > 30) {
        debugPrint("⚠️ [SECURE_TIME] Desvío detectado: ${_offset.inSeconds} segundos.");
      } else {
        debugPrint("[SECURE_TIME] Hora sincronizada correctamente.");
      }
    } catch (e) {
      debugPrint("[SECURE_TIME_ERR] No se pudo sincronizar hora: $e");
      // Fallback: Si no hay red, confiamos en la local temporalmente
      // Pero marcamos como no sincronizado para que la lógica de cierre sea más estricta
      _isSynced = false;
    }
  }

  /// Devuelve la hora real (corregida)
  DateTime now() {
    return DateTime.now().add(_offset);
  }

  /// Verifica si la hora del dispositivo es sospechosa (ej: movida manualmente)
  bool isTimeSuspicious() {
    // Si el desvío es mayor a 5 minutos, es muy probable que sea un intento de trampa
    return _offset.inMinutes.abs() > 5;
  }
}
