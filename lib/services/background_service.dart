import 'dart:async' as dart_async;
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:srecord/services/notification_service.dart';
import 'package:srecord/services/database_helper.dart';
import 'package:srecord/services/core_network.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/services/recaudacion_service.dart';
import 'package:srecord/services/sovereign_shield.dart';

@pragma('vm:entry-point')
class BackgroundService {
  static Future<void> initializeService() async {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      debugPrint("⚠️ BackgroundService: No soportado en esta plataforma.");
      return;
    }

    final service = FlutterBackgroundService();

    /// CONFIGURACIÓN DE NOTIFICACIONES PARA EL SERVICIO (FOREGROUND) - SILENCIOSO
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'foreground_service_channel_v3', // Cambiado a V3 para resetear estado en el sistema
      'S-Record Nervio Central',
      description: 'Protección de datos y sincronización silenciosa 24/7',
      importance: Importance.low, // Cambiado a LOW para eliminar sonido y avisos molestos
    );

    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: true,
        isForegroundMode: true,
        notificationChannelId: 'foreground_service_channel_v3',
        initialNotificationTitle: 'S-RECORD NERVIO CENTRAL',
        initialNotificationContent: 'Escucha activa en segundo plano 24/7',
        foregroundServiceNotificationId: 888,
        foregroundServiceTypes: [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );

    service.startService();
  }

  static void invoke(String method, [Map<String, dynamic>? args]) {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      debugPrint("⚠️ BackgroundService.invoke: Ignorado en esta plataforma.");
      return;
    }
    FlutterBackgroundService().invoke(method, args);
  }

  static Stream<Map<String, dynamic>?> on(String method) {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      return const Stream.empty();
    }
    return FlutterBackgroundService().on(method);
  }

  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();
    WidgetsFlutterBinding.ensureInitialized();

    final notificationService = NotificationService();
    await notificationService.init();

    // 1. Asegurar Túnel en Isolate de Fondo (Protocolo de Evasión)
    final coreNetwork = CoreNetwork();
    await coreNetwork.initializeTunnel();

    // 2. Inicializar Supabase en el Isolate
    await Supabase.initialize(
      url: 'https://vonuhrbjchufqzqygqgt.supabase.co',
      publishableKey: SovereignShield.getMasterKey(),
    );

    final supabase = Supabase.instance.client;
    final prefs = await SharedPreferences.getInstance();

    debugPrint("[BG_SERVICE] Iniciando Escucha Realtime (Nervio Central)...");

    // 3. Obtener Identidad para Filtrado
    final String bancoId = prefs.getString("active_banco_id") ?? "UNKNOWN";
    final String userRole = prefs.getString("user_role") ?? "LISTERO";
    final String listeroPin = prefs.getString("current_listero_pin") ?? "";

    // CACHÉ DE EVASIÓN DE DUPLICADOS (Soberanía de Isolate)
    final Set<String> notifiedUuids = {};

    RealtimeChannel? cmdChan;
    RealtimeChannel? resChan;
    RealtimeChannel? parteChan;
    RealtimeChannel? limChan;
    RealtimeChannel? notiChan;
    RealtimeChannel? comuChan;
    RealtimeChannel? updateChan;

    bool isSettingUp = false;

    Future<void> setupSubscriptions() async {
      if (isSettingUp) return;
      isSettingUp = true;

      try {
        await prefs.reload();
        final String bancoId = prefs.getString("active_banco_id") ?? prefs.getString("banco_id") ?? "UNKNOWN";
        final String userRole = prefs.getString("user_role") ?? "LISTERO";
        final String listeroPin = prefs.getString("current_listero_pin") ?? prefs.getString("listero_pin") ?? "";

        debugPrint("[BG_SERVICE] Configurando suscripciones Realtime para Banco: $bancoId (Rol: $userRole, PIN: $listeroPin)");

        await supabase.removeAllChannels();
        cmdChan = null;
        resChan = null;
        parteChan = null;
        limChan = null;
        notiChan = null;
        comuChan = null;
        updateChan = null;

        if (bancoId == "UNKNOWN" || bancoId.isEmpty) {
          debugPrint("[BG_SERVICE] Banco no asignado aún. Esperando inicio de sesión.");
          return;
        }

        // --- ESCUCHA DE COMANDOS (PULSO MAESTRO) ---
        cmdChan = supabase.channel('commands:$bancoId');
        cmdChan!.onBroadcast(event: 'PULSE_CHECK', callback: (payload) async {
          debugPrint("[BG_SERVICE] Pulso maestro recibido en segundo plano.");
          await Alex().syncDataToCloud(isDeepSync: payload['deep'] ?? false);
        }).subscribe();

        // --- ESCUCHA DE RESULTADOS (TIROS OFICIALES) ---
        resChan = supabase.channel('public:resultados:banco_$bancoId');
        resChan!.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'resultados',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'banco_id', value: bancoId),
          callback: (payload) async {
            if (payload.eventType == PostgresChangeEvent.delete) return;
            
            final data = payload.newRecord;
            final String date = data['fecha']?.toString() ?? '';
            final String section = data['seccion']?.toString() ?? '';
            final String loteria = data['loteria']?.toString() ?? 'FLORIDA';
            final String n1 = data['n1']?.toString() ?? '';
            final String n2 = data['n2']?.toString() ?? '';
            final String n3 = data['n3']?.toString() ?? '';

            final String uuid = "${date}_${section}_${loteria}_$bancoId";
            
            if (notifiedUuids.contains(uuid)) return;
            notifiedUuids.add(uuid);

            final dbHelper = DatabaseHelper();
            await dbHelper.saveResultado(date, section, n1, n2, n3, bancoId: bancoId, loteria: loteria, sync: 0);

            final String s1 = mapToLargeSpheres(n1);
            final String s2 = mapToLargeSpheres(n2);
            final String s3 = mapToLargeSpheres(n3);
            
            final String bigTextStr = "🎰 TIRO GANADOR OFICIAL ($loteria - $section)\n"
                "-----------------------------------------\n"
                "🟡 CENTENA:   [ $s1 ]\n"
                "🔵 CORRIDO 1: [ $s2 ]\n"
                "🟠 CORRIDO 2: [ $s3 ]\n"
                "-----------------------------------------\n"
                "📅 FECHA: $date";

            final int notiId = (uuid.hashCode).abs() % 100000;
            await notificationService.showNotification(
              id: notiId,
              title: "🎰 TIRO OFICIAL PUBLICADO ($loteria)",
              body: "🟡 C: $s1  |  🔵 C1: $s2  |  🟠 C2: $s3",
              bigText: bigTextStr,
              payloadKey: "result_${loteria}_${date}_${section}_$n1$n2$n3",
            );
            if (Alex().isBrainOnline()) await Alex().syncDataToCloud(isDeepSync: true);
          },
        ).subscribe();

        // --- ESCUCHA DE PARTES (CIERRES Y PUBLICACIONES) ---
        parteChan = supabase.channel('public:partes:banco_$bancoId');
        parteChan!.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'partes',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'banco_id', value: bancoId),
          callback: (payload) async {
            final data = payload.newRecord;
            final String? uuid = data['uuid'];

            if (uuid != null) {
              if (notifiedUuids.contains(uuid)) return;
              notifiedUuids.add(uuid);
            }
            
            if (userRole == "LISTERO" && data['listero_pin'] == listeroPin) {
              final bool esPublicado = (data['publicado'] == 1 || data['publicado'] == true || data['publicado'] == '1');
              
              if (esPublicado) {
                final double balance = (data['total_dia'] as num?)?.toDouble() ?? 0.0;
                final double fondoAnt = (data['fondo_anterior'] as num?)?.toDouble() ?? 0.0;
                final double liq = (data['liquidacion'] as num?)?.toDouble() ?? 0.0;
                final double saldoFin = (data['saldo_final'] as num?)?.toDouble() ?? 0.0;
                final double limL = (data['limpio_lista'] as num?)?.toDouble() ?? 0.0;
                final double prL = (data['premios_lista'] as num?)?.toDouble() ?? 0.0;
                final double limB = (data['limpio_bote'] as num?)?.toDouble() ?? 0.0;
                final double prB = (data['premios_bote'] as num?)?.toDouble() ?? 0.0;

                final String secName = data['seccion']?.toString() ?? '';
                final String lotName = data['loteria']?.toString() ?? 'FLORIDA';

                final String bigTextStr = "📊 PARTE OFICIAL DETALLADO ($lotName - $secName)\n"
                    "-----------------------------------------\n"
                    "💵 Limpio Lista:   \$${RecaudacionService.formatMoney(limL)}\n"
                    "🏆 Premios Lista: \$${RecaudacionService.formatMoney(prL)}\n"
                    "-----------------------------------------\n"
                    "📦 Limpio Bote:    \$${RecaudacionService.formatMoney(limB)}\n"
                    "🎁 Premios Bote:  \$${RecaudacionService.formatMoney(prB)}\n"
                    "-----------------------------------------\n"
                    "📈 UTILIDAD DÍA:  \$${RecaudacionService.formatMoney(balance.abs())} ${balance >= 0 ? "(GANA BANCO)" : "(GANA LISTERO)"}\n"
                    "🏛️ FONDO PREVIO:  \$${RecaudacionService.formatMoney(fondoAnt.abs())}\n"
                    "💳 LIQUIDACIÓN:   \$${RecaudacionService.formatMoney(liq.abs())}\n"
                    "💰 SALDO ACUMULADO: \$${RecaudacionService.formatMoney(saldoFin.abs())} ${saldoFin >= 0 ? "(LISTERO DEBE)" : "(BANCO DEBE)"}";

                final int notiId = (data['uuid']?.hashCode ?? 202).abs() % 100000;
                await notificationService.showNotification(
                  id: notiId,
                  title: "✅ PARTE OFICIAL ENVIADO Y PUBLICADO ($lotName - $secName)",
                  body: "💰 Acumulado: \$${RecaudacionService.formatMoney(saldoFin.abs())} | Utilidad: \$${RecaudacionService.formatMoney(balance.abs())}",
                  bigText: bigTextStr,
                  payloadKey: "parte_pub_${data['uuid']}_${data['publicado']}",
                );
              }
            } 
            else if (userRole == "BANCO") {
              if (payload.eventType == PostgresChangeEvent.update && data['recibido'] == 1) {
                final int notiId = (data['uuid']?.hashCode ?? 301).abs() % 100000;
                await notificationService.showNotification(
                  id: notiId,
                  title: "👀 LISTERO NOTIFICADO",
                  body: "El listero ${data['listero_pin']} ha visto su parte de la ${data['seccion']}.",
                  payloadKey: "parte_seen_${data['uuid']}_${data['recibido']}",
                );
              }
            }
          },
        ).subscribe();

        // --- ESCUCHA DE LÍMITES (RESTRICCIONES EN TIEMPO REAL) ---
        limChan = supabase.channel('public:limites:banco_$bancoId');
        limChan!.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'limites',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'banco_id', value: bancoId),
          callback: (payload) async {
            if (payload.eventType == PostgresChangeEvent.delete) return;
            final data = payload.newRecord;
            final String uuidKey = data['uuid'] ?? '${data['banco_id']}_${data['numero']}';

            if (notifiedUuids.contains(uuidKey)) return;
            notifiedUuids.add(uuidKey);

            if (userRole == "LISTERO" || userRole == "BANCO") {
              final String num = data['numero'] ?? '---';
              final String f = data['fijo'] ?? '-';
              final String c = data['corrido'] ?? '-';
              final String typeLabel = data['tipo']?.toString().toUpperCase() ?? "BOLA";
              final String spheres = _mapToSpheres(num);
              final int notiId = (uuidKey.hashCode).abs() % 100000;
              await notificationService.showNotification(
                id: notiId,
                title: "🚫 NUEVO LIMITADO EN $typeLabel",
                body: "🎰 $spheres (${data['seccion']}) | F: $f | C: $c",
                payloadKey: "limit_$uuidKey",
              );
            }
          },
        ).subscribe();

        // --- ESCUCHA DE COMUNICADOS Y NOTIFICACIONES BANCARIAS ---
        notiChan = supabase.channel('public:notificaciones:banco_$bancoId');
        notiChan!.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notificaciones',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'banco_id', value: bancoId),
          callback: (payload) async {
            if (payload.eventType == PostgresChangeEvent.delete) return;
            final data = payload.newRecord;
            final String uuidKey = data['uuid'] ?? '${data['id']}_$bancoId';

            if (notifiedUuids.contains(uuidKey)) return;
            notifiedUuids.add(uuidKey);

            await prefs.reload();
            final String myRole = prefs.getString("user_role") ?? "LISTERO";
            final String myPin = (prefs.getString("current_listero_pin") ?? prefs.getString("listero_pin") ?? "").trim();
            final String targetPin = (data['listero_pin']?.toString() ?? "").trim();

            final bool isForMe = (myRole == "BANCO") || 
                                 (targetPin.isEmpty) || 
                                 (targetPin == myPin) || 
                                 (int.tryParse(targetPin) != null && int.tryParse(targetPin) == int.tryParse(myPin));

            if (isForMe) {
              final String titulo = data['titulo']?.toString() ?? "📢 AVISO OFICIAL";
              final String mensaje = data['mensaje']?.toString() ?? "";
              
              // Guardar localmente en SQLite
              final dbHelper = DatabaseHelper();
              await dbHelper.insertNotificacion(
                titulo, 
                mensaje, 
                listeroPin: targetPin, 
                bancoId: bancoId, 
                sync: 0, 
                uuid: uuidKey, 
                esOficial: data['es_oficial'] == 1 || data['es_oficial'] == true
              );

              final int notiId = (uuidKey.hashCode).abs() % 100000;
              await notificationService.showNotification(
                id: notiId,
                title: titulo,
                body: mensaje,
                payloadKey: "noti_$uuidKey",
              );
            }
          },
        ).subscribe();

        comuChan = supabase.channel('public:comunicados:banco_$bancoId');
        comuChan!.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'comunicados',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'banco_id', value: bancoId),
          callback: (payload) async {
            if (payload.eventType == PostgresChangeEvent.delete) return;
            if (userRole == "BANCO" || userRole == "PROGRAMADOR") return; // SOLO PARA LISTEROS
            final data = payload.newRecord;
            final String uuidKey = "${data['id'] ?? data['uuid']}_comu";

            if (notifiedUuids.contains(uuidKey)) return;
            notifiedUuids.add(uuidKey);

            final int notiId = (uuidKey.hashCode).abs() % 100000;
            await notificationService.showNotification(
              id: notiId,
              title: "📢 COMUNICADO OFICIAL",
              body: data['mensaje'] ?? data['contenido'] ?? data['titulo'] ?? "Información importante del banco.",
              payloadKey: "comu_$uuidKey",
            );
          },
        ).subscribe();

        // --- ESCUCHA DE ACTUALIZACIONES CRÍTICAS ---
        updateChan = supabase.channel('public:app_updates');
        updateChan!.onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'app_updates',
          callback: (payload) async {
            final data = payload.newRecord;
            final String vName = data['version_name']?.toString() ?? 'NEW';
            await notificationService.showNotification(
              id: 999,
              title: "🚀 MEJORA DE SISTEMA DISPONIBLE",
              body: "Versión $vName lista. Toca para optimizar tu equipo.",
              payloadKey: "update_available_$vName",
            );
            service.invoke('onUpdateDetected', data);
          },
        ).subscribe();
      } catch (e) {
        debugPrint("[BG_SERVICE_SETUP_ERR] $e");
      } finally {
        isSettingUp = false;
      }
    };

    service.on('reloadSubscriptions').listen((_) async {
      debugPrint("[BG_SERVICE] Evento reloadSubscriptions recibido.");
      await setupSubscriptions();
    });

    service.on('stopService').listen((event) {
      service.stopSelf();
    });

    await setupSubscriptions();

    // CENTINELA REALTIME Y SINCRONIZACIÓN DE FONDO 24/7
    dart_async.Timer.periodic(const Duration(seconds: 25), (timer) async {
      await prefs.reload();
      final String bancoId = prefs.getString("active_banco_id") ?? prefs.getString("banco_id") ?? "UNKNOWN";
      
      if (bancoId != "UNKNOWN" && bancoId.isNotEmpty) {
        // 1. Verificar si el socket Realtime perdió conexión y restaurar suscripciones si es necesario
        if (!supabase.realtime.isConnected) {
          debugPrint("[BG_SERVICE_WATCHDOG] Realtime desconectado en segundo plano. Restaurando...");
          await setupSubscriptions();
        } else {
          // Heartbeat ligero para mantener el túnel WebSocket activo en segundo plano
          try {
            cmdChan?.sendBroadcastMessage(event: 'HEARTBEAT', payload: {'ts': DateTime.now().millisecondsSinceEpoch});
          } catch (_) {}
        }
      }
    });
  }

  static String mapToLargeSpheres(String? input) {
    if (input == null || input.trim().isEmpty) return "⚪";
    const Map<String, String> keycaps = {
      '0': '0️⃣', '1': '1️⃣', '2': '2️⃣', '3': '3️⃣', '4': '4️⃣',
      '5': '5️⃣', '6': '6️⃣', '7': '7️⃣', '8': '8️⃣', '9': '9️⃣'
    };
    
    if (input.contains('-')) {
      return input.split('-').map((n) {
        String part = n.trim().padLeft(2, '0');
        return part.split('').map((d) => keycaps[d] ?? d).join('');
      }).join(' ');
    }

    String part = input.trim();
    return part.split('').map((d) => keycaps[d] ?? d).join('');
  }

  static String _mapToSpheres(String? input) {
    return mapToLargeSpheres(input);
  }
}
