import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  final Set<String> _sessionNotifiedKeys = {};

  Future<void> init() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/launcher_icon');

    const LinuxInitializationSettings initializationSettingsLinux =
        LinuxInitializationSettings(defaultActionName: 'Abrir S-Record');

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      linux: initializationSettingsLinux,
    );

    await _notificationsPlugin.initialize(initializationSettings);

    // Crear canal explícitamente para asegurar máxima visibilidad (V4 para forzar actualización total)
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'srecord_pro_channel_v4', 
      'Comunicados y Alertas Críticas',
      description: 'Canal de ALTA PRIORIDAD para comunicados oficiales y avisos críticos.',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    );

    final androidPlugin = _notificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    
    await androidPlugin?.createNotificationChannel(channel);
    try {
      await androidPlugin?.requestNotificationsPermission();
    } catch (e) {
      debugPrint("[NOTIFICATION_SERVICE] Permiso de notificación omitido en isolate/segundo plano: $e");
    }
  }

  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    String? bigText,
    String? payloadKey,
  }) async {
    // PROTECCIÓN CONTRA DUPLICADOS INFINITOS
    if (payloadKey != null) {
      final prefs = await SharedPreferences.getInstance();
      
      // FORZAR RECARGA: Asegura que si el Isolate de fondo envió algo, el principal lo sepa (y viceversa)
      await prefs.reload();

      // 1. Verificar en memoria de sesión (Rápido)
      if (_sessionNotifiedKeys.contains(payloadKey)) return;

      // 2. Verificar persistencia (Seguro entre reinicios e Isolates)
      final String fullKey = "noti_sent_$payloadKey";
      if (prefs.getBool(fullKey) == true) {
        _sessionNotifiedKeys.add(payloadKey);
        return;
      }

      // Registrar como enviada ANTES de mostrarla para evitar ráfagas
      _sessionNotifiedKeys.add(payloadKey);
      await prefs.setBool(fullKey, true);
      
      // Asegurar que los cambios se escriban en disco antes de que el otro Isolate intente leer
      await prefs.reload(); 
    }

    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'srecord_pro_channel_v4', 
      'Comunicados y Alertas Críticas',
      channelDescription: 'Canal de ALTA PRIORIDAD para comunicados oficiales y avisos críticos.',
      importance: Importance.max,
      priority: Priority.max,
      showWhen: true,
      playSound: true,
      enableVibration: true,
      styleInformation: bigText != null 
          ? BigTextStyleInformation(bigText, contentTitle: title, summaryText: "S-RECORD") 
          : null,
      category: AndroidNotificationCategory.message,
      icon: '@mipmap/launcher_icon',
    );

    final NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    await _notificationsPlugin.show(id, title, body, platformChannelSpecifics);
  }
}
