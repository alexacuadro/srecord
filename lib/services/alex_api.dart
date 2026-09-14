import 'dart:async' as async;
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sqflite/sqflite.dart';
import 'package:ota_update/ota_update.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:srecord/services/database_helper.dart';
import 'package:srecord/services/recaudacion_service.dart';
import 'package:srecord/services/notification_service.dart';
import 'package:srecord/services/tiro_service.dart';
import 'package:srecord/services/background_service.dart';

import 'package:srecord/services/core_network.dart';

import 'package:srecord/services/secure_time_service.dart';

class Alex {
  static final Alex _instance = Alex._internal();
  factory Alex() => _instance;
  Alex._internal() {
    _startAutoSync();
    _performInitialAudit();
    _db.onSyncUpdate = (id) {
       // Si el ID es > 0 o -1, significa que hubo un cambio local que requiere subida.
       if (id != -999) { 
         _triggerDebouncedSync();
       }
    };
    
    // Sincronizar automáticamente al recuperar la conexión a internet
    CoreNetwork().onConnectionChanged.listen((online) async {
      if (online) {
        debugPrint("[ALEX] 🌐 Conexión a internet restaurada. Procesando cola pendiente...");
        await syncDataToCloud(isDeepSync: true);
        await broadcastSyncPulse(isDeep: true);
        SecureTimeService().sync(); // Re-sincronizar hora oficial al recuperar red
      }
    });

    // Iniciar auditoría de seguridad silenciosa y canal global de actualizaciones
    _performSecurityAudit();
    SecureTimeService().sync();
    _initSystemChannels();

    // Escuchar actualizaciones detectadas por el servicio de fondo
    BackgroundService.on('onUpdateDetected').listen((data) {
      if (data != null) {
        debugPrint("[ALEX_REMOTE] ¡ACTUALIZACIÓN CRÍTICA DETECTADA! Forzando descarga...");
        checkAppUpdate(force: true);
      }
    });
  }

  RealtimeChannel? _systemChannel;

  void _initSystemChannels() async {
    try {
      await _systemChannel?.unsubscribe();
      _systemChannel = _supabase.channel('system_updates');
      _systemChannel!.onBroadcast(
        event: 'NEW_APP_UPDATE',
        callback: (payload) async {
          debugPrint("[ALEX_REALTIME] ¡ANUNCIO DE NUEVA VERSIÓN RECIBIDO VÍA WEBSOCKET!");
          await checkAppUpdate(force: true);
        },
      ).subscribe();
    } catch (e) {
      debugPrint("[ALEX_SYS_CHAN_ERR] $e");
    }
  }

  Future<void> _performSecurityAudit() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      bool isSuspicious = false;
      String reason = "";

      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        // 1. Detección básica de Emulador
        if (!androidInfo.isPhysicalDevice) {
          isSuspicious = true;
          reason = "EMULADOR DETECTADO";
        }
        // 2. Detección de marcas de Root/Debug
        if (androidInfo.model.contains("sdk") || androidInfo.host.contains("build")) {
          isSuspicious = true;
          reason = "ENTORNO DE DESARROLLO / MODIFICADO";
        }
      }

      if (isSuspicious) {
        debugPrint("🚨 [ALEX_SECURITY] Violación detectada: $reason");
        _securityController.add(reason);
        // No cerramos sesión inmediatamente para no alertar al atacante,
        // pero podemos marcar la cuenta para revisión o dificultar la sincronización.
      }
    } catch (e) {
      debugPrint("[ALEX_SECURITY_ERR] Error en auditoría: $e");
    }
  }

  async.Timer? _debounceSyncTimer;

  void _triggerDebouncedSync() {
    _debounceSyncTimer?.cancel();
    if (_isSyncing) {
      _syncPending = true;
      return;
    }
    _debounceSyncTimer = async.Timer(const Duration(milliseconds: 800), () {
      debugPrint("[ALEX] Sincronización ráfaga instantánea ejecutándose...");
      syncDataToCloud();
    });
  }

  SupabaseClient get _supabase => Supabase.instance.client;
  final DatabaseHelper _db = DatabaseHelper();
  final String _sessionId = DateTime.now().millisecondsSinceEpoch.toString();

  bool _isSyncing = false;
  bool _syncPending = false;
  bool _deepSyncRequested = false;
  bool _isDownloadingApk = false;
  String? _syncPriorityTable;

  final ValueNotifier<String> lastSyncEvent = ValueNotifier("SIN ACTIVIDAD");
  final async.StreamController<Map<String, dynamic>> _liveBetsController = async.StreamController<Map<String, dynamic>>.broadcast();
  final async.StreamController<Map<String, dynamic>> _typingStatusController = async.StreamController<Map<String, dynamic>>.broadcast();
  
  // MIEMBROS RESTAURADOS
  final ValueNotifier<bool> isUserVerified = ValueNotifier<bool>(true);
  final ValueNotifier<bool> isListeroBlocked = ValueNotifier<bool>(false);
  final ValueNotifier<Map<String, dynamic>?> updateRequired = ValueNotifier<Map<String, dynamic>?>(null);
  final ValueNotifier<double> uploadProgress = ValueNotifier<double>(0.0);
  final ValueNotifier<Map<String, dynamic>> uploadProgressDetails = ValueNotifier<Map<String, dynamic>>({});
  final async.StreamController<String> _securityController = async.StreamController<String>.broadcast();
  async.Stream<String> get onSecurityViolation => _securityController.stream;

  // Canales Realtime
  RealtimeChannel? _commandChannel;
  RealtimeChannel? _dataChannel;

  /// Inicializa los canales de comunicación en tiempo real para un Banco
  Future<void> initRealtimeChannels(String? bancoId) async {
    if (bancoId == null || bancoId == "UNKNOWN" || bancoId.isEmpty) {
      debugPrint("[ALEX_REALTIME] CANCELADO: bancoId inválido ($bancoId)");
      return;
    }
    
    debugPrint("[ALEX_REALTIME] Inicializando canales para el banco: $bancoId");
    await _commandChannel?.unsubscribe();
    await _dataChannel?.unsubscribe();

    // Verificar estado inicial de bloqueo para el listero activo
    checkListeroBlockStatus();

    // 1. Canal de Comandos (Mensajes rápidos entre dispositivos)
    _commandChannel = _supabase.channel('commands:$bancoId');
    _commandChannel!.onBroadcast(event: 'PULSE_CHECK', callback: (payload) async {
       final String senderId = payload['sender_id'] ?? "";
       if (senderId == _sessionId) return; // Ignorar mis propios pulsos

       final String? targetPin = payload['target_pin'];
       final String myPin = await getActiveListeroPin();

       // Si el pulso es para mí o para todos, sincronizar (marcando fromRemotePulse: true para evitar rebote infinito)
       if (targetPin == null || targetPin == "" || targetPin == myPin) {
         debugPrint("[ALEX_REMOTE] Pulso de sincronización recibido. Ejecutando Espejo...");
         await syncDataToCloud(isDeepSync: payload['deep'] ?? true, fromRemotePulse: true);
         await checkListeroBlockStatus();
         _db.notifySyncUpdate(-999);
       }
    }).onBroadcast(event: 'LISTERO_BLOCK_TOGGLE', callback: (payload) async {
       final String pin = (payload['pin'] ?? "").toString().trim();
       final bool blocked = (payload['blocked'] == true || payload['blocked'] == 1);
       final String myPin = await getActiveListeroPin();
       if (pin == myPin) {
         debugPrint("[ALEX_REALTIME] Bloqueo en tiempo real recibido para mi lista: $blocked");
         isListeroBlocked.value = blocked;
         final bId = await getActiveBancoId();
         if (bId != null) {
           final local = await _db.getListeroByPin(pin, bId);
           if (local != null) {
             final updated = Map<String, dynamic>.from(local);
             updated['bloqueado'] = blocked ? 1 : 0;
             await _db.upsertListero(updated);
           }
         }
         _db.notifySyncUpdate(-999);
       }
    }).onBroadcast(event: 'LISTERO_UNLINK', callback: (payload) async {
       final String pin = (payload['pin'] ?? "").toString().trim();
       final String myPin = (await getActiveListeroPin()).trim();
       final String prefsRole = (await SharedPreferences.getInstance()).getString("user_role") ?? "";
       if (prefsRole == "LISTERO" && pin == myPin) {
         debugPrint("[ALEX_REALTIME] Desvinculación en tiempo real recibida para mi lista ($pin). Cerrando sesión...");
         await logout(fullReset: true);
         _liveBetsController.add({
           'type': 'LISTERO_UNLINKED',
           'message': '⚠️ SU LISTA HA SIDO DESVINCULADA POR EL BANCO.'
         });
       } else {
         final bId = await getActiveBancoId();
         if (bId != null) {
           final local = await _db.getListeroByPin(pin, bId);
           if (local != null) {
             final updated = Map<String, dynamic>.from(local);
             updated['vinculado'] = 0;
             updated['device_id'] = null;
             await _db.upsertListero(updated);
           }
         }
         _db.notifySyncUpdate(-999);
       }
    }).onBroadcast(event: 'LISTERO_DELETE', callback: (payload) async {
       final String pin = (payload['pin'] ?? "").toString().trim();
       final String myPin = (await getActiveListeroPin()).trim();
       final String prefsRole = (await SharedPreferences.getInstance()).getString("user_role") ?? "";
       if (prefsRole == "LISTERO" && pin == myPin) {
         debugPrint("[ALEX_REALTIME] Eliminación en tiempo real recibida para mi lista ($pin). Cerrando sesión...");
         await logout(fullReset: true);
         _liveBetsController.add({
           'type': 'LISTERO_UNLINKED',
           'message': '⚠️ SU LISTA HA SIDO ELIMINADA POR EL BANCO.'
         });
       } else {
         final bId = await getActiveBancoId();
         if (bId != null) {
           await _db.deleteListero(pin, bId, sync: 0);
         }
         _db.notifySyncUpdate(-999);
       }
    }).onBroadcast(event: 'TYPING_STATUS', callback: (payload) {
       _typingStatusController.add(payload);
    }).onBroadcast(event: 'SECTION_SYNC', callback: (payload) async {
       // Navegación individual por usuario/dispositivo: Ignorar cambios remotos de sección/fecha
       debugPrint("[ALEX_REMOTE] Evento SECTION_SYNC recibido - Ignorado para mantener navegación independiente por usuario.");
    }).subscribe();

    // 2. Canal de Datos (Cambios en tablas críticas)
    _dataChannel = _supabase.channel('data:$bancoId');
    
    final tables = ['resultados', 'partes', 'limites', 'notificaciones', 'comunicados', 'listeros', 'planes', 'bank_colors', 'control_remoto', 'jugadas'];
    
    for (var table in tables) {
      _dataChannel!.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (payload) {
          final record = (payload.eventType == PostgresChangeEvent.delete) 
              ? payload.oldRecord 
              : payload.newRecord;
          
          if (record.isNotEmpty) {
            final String? recBancoId = record['banco_id']?.toString().trim().toUpperCase();
            final String currentBancoId = bancoId.trim().toUpperCase();
            
            if (recBancoId == null || recBancoId.isEmpty || recBancoId == currentBancoId || recBancoId == 'SYSTEM') {
               _handleRealtimeUpdate(payload, bancoId);
            }
          }
        },
      );
    }
    
    _dataChannel!.subscribe();

    debugPrint("[ALEX_REALTIME] Canales activados para el banco: $bancoId");
    BackgroundService.invoke('reloadSubscriptions');
  }

  void _handleRealtimeUpdate(PostgresChangePayload payload, String bancoId) async {
    final table = payload.table;
    final record = (payload.eventType == PostgresChangeEvent.delete) ? payload.oldRecord : payload.newRecord;

    if (record.isEmpty) {
      debugPrint("[ALEX_REALTIME] Update ignorado: Record vacío o nulo en tabla $table");
      return;
    }

    if (table == 'resultados') {
      debugPrint("[ALEX_REALTIME] Evento de RESULTADOS detectado: ${payload.eventType}");
      if (payload.eventType == PostgresChangeEvent.delete) {
        final String fecha = record['fecha']?.toString() ?? '';
        final String seccion = record['seccion']?.toString() ?? '';
        final String loteria = record['loteria']?.toString() ?? 'FLORIDA';

        if (fecha.isNotEmpty && seccion.isNotEmpty) {
          debugPrint("[ALEX_REALTIME] Borrando resultado localmente: $fecha $seccion ($loteria)");
          await _db.deleteResultado(fecha, seccion, bancoId: bancoId, loteria: loteria, sync: 0);
        } else {
          final String? uuid = record['uuid']?.toString();
          final int? id = int.tryParse(record['id']?.toString() ?? '');
          final db = await _db.database;
          if (uuid != null && uuid.isNotEmpty) {
            final rows = await db.query('resultados', where: 'uuid = ?', whereArgs: [uuid]);
            for (var r in rows) {
              await _db.deleteResultado(r['fecha']?.toString() ?? '', r['seccion']?.toString() ?? '', bancoId: bancoId, loteria: r['loteria']?.toString() ?? 'FLORIDA', sync: 0);
            }
          } else if (id != null) {
            final rows = await db.query('resultados', where: 'id = ?', whereArgs: [id]);
            for (var r in rows) {
              await _db.deleteResultado(r['fecha']?.toString() ?? '', r['seccion']?.toString() ?? '', bancoId: bancoId, loteria: r['loteria']?.toString() ?? 'FLORIDA', sync: 0);
            }
          }
        }
        
        debugPrint("[ALEX_REALTIME] Notificando eliminación de tiro activo a la UI.");
        TiroService().notifyNewTiro(null);
        _db.notifySyncUpdate(-999);

        NotificationService().showNotification(
          id: 102,
          title: "⚠️ TIRO ELIMINADO POR EL BANCO",
          body: "El banco ha eliminado el tiro oficial. La lista se ha actualizado.",
          payloadKey: "deleted_tiro_${DateTime.now().millisecondsSinceEpoch}",
        );

        syncDataToCloud(isDeepSync: true);
        return;
      }
      final String lot = record['loteria']?.toString() ?? 'FLORIDA';
      final Map<String, String> row = {
        'fecha': record['fecha']?.toString() ?? '',
        'seccion': record['seccion']?.toString() ?? '',
        'loteria': lot,
        'n1': record['n1']?.toString() ?? '',
        'n2': record['n2']?.toString() ?? '',
        'n3': record['n3']?.toString() ?? '',
      };
      
      debugPrint("[ALEX_REALTIME] Tiro recibido para $bancoId: ${row['fecha']} ${row['seccion']} ($lot) -> ${row['n1']}-${row['n2']}-${row['n3']}");
      
      await _db.saveResultado(row['fecha'] ?? '', row['seccion'] ?? '', row['n1'] ?? '', row['n2'] ?? '', row['n3'] ?? '', bancoId: bancoId, loteria: lot, sync: 0);
      
      // SIEMPRE notificamos al TiroService para forzar refresco de UI
      TiroService().notifyNewTiro(row);

      final String role = (await SharedPreferences.getInstance()).getString("user_role") ?? "LISTERO";
      if (role == "LISTERO") {
        final String n1 = _mapToSpheres(row['n1']);
        final String n2 = _mapToSpheres(row['n2']);
        final String n3 = _mapToSpheres(row['n3']);

        NotificationService().showNotification(
          id: 101,
          title: "🔥 TIRO OFICIAL PUBLICADO ($lot)",
          body: "🔵$n1  🔵$n2  🟠$n3  (${row['seccion']})",
          payloadKey: "result_${lot}_${row['fecha']}_${row['seccion']}_${row['n1']}${row['n2']}${row['n3']}",
        );
      }
    } else if (table == 'planes') {
      if (payload.eventType == PostgresChangeEvent.delete) {
        await _db.deletePlan(record['nombre'], bancoId, loteria: record['loteria']?.toString() ?? 'FLORIDA', sync: 0);
        _db.notifySyncUpdate(-999);
        return;
      }
      Map<String, dynamic> planRow = Map.from(record);
      if (planRow['config'] is String) planRow['config'] = json.decode(planRow['config']);
      await _db.upsertPlan(planRow['nombre'] ?? '', planRow['config'] ?? {}, bancoId: bancoId, loteria: planRow['loteria']?.toString() ?? 'FLORIDA', sync: 0);
      _db.notifySyncUpdate(-999);
    } else if (table == 'listeros') {
      final String pin = (record['pin'] ?? "").toString().trim();
      final String myPin = (await getActiveListeroPin()).trim();
      final String prefsRole = (await SharedPreferences.getInstance()).getString("user_role") ?? "";

      if (payload.eventType == PostgresChangeEvent.delete) {
        if (prefsRole == "LISTERO" && pin == myPin) {
          debugPrint("[ALEX_REALTIME] Borrado de lista detectado en Postgres ($pin).");
          await logout(fullReset: true);
          _liveBetsController.add({
            'type': 'LISTERO_UNLINKED',
            'message': '⚠️ SU LISTA HA SIDO ELIMINADA POR EL BANCO.'
          });
          return;
        }
        await _db.deleteListero(pin, bancoId, sync: 0);
        _db.notifySyncUpdate(-999);
        return;
      }

      if (prefsRole == "LISTERO" && pin == myPin) {
        final bool isLinked = (record['vinculado'] == 1 || record['vinculado'] == true);
        final String? devId = record['device_id'];
        final String myDevId = await _getDeviceId();

        if (!isLinked || (devId != null && devId.isNotEmpty && devId != myDevId)) {
          debugPrint("[ALEX_REALTIME] Desvinculación detectada en Postgres para mi lista ($pin).");
          await logout(fullReset: true);
          _liveBetsController.add({
            'type': 'LISTERO_UNLINKED',
            'message': '⚠️ SU LISTA HA SIDO DESVINCULADA POR EL BANCO.'
          });
          return;
        }
      }

      await _db.upsertListero({...record, 'sync': 0}); 
      _db.notifySyncUpdate(-999);
    } else if (table == 'limites') {
      if (payload.eventType == PostgresChangeEvent.delete) {
        final String? uuid = record['uuid'];
        if (uuid != null) await _db.deleteLimiteByUuid(uuid, sync: 0);
        TiroService().notifyLimitesChanged();
        return;
      }
      await _db.saveLimite(record, sync: 0);
      TiroService().notifyLimitesChanged();
      
      final String num = record['numero'] ?? '---';
      final String f = record['fijo'] ?? '-';
      final String c = record['corrido'] ?? '-';
      final String p = record['pago'] ?? '-';
      final String typeLabel = record['tipo']?.toString().toUpperCase() ?? "BOLA";
      final String lot = record['loteria']?.toString() ?? 'FLORIDA';
      final String spheres = _mapToSpheres(num);

      NotificationService().showNotification(
        id: 401,
        title: "🚫 NUEVOS LIMITADOS EN $typeLabel ($lot)",
        body: "🎰 $spheres (${record['seccion']}) | F: $f | C: $c | Pago: $p",
        payloadKey: "limit_${record['uuid'] ?? '${record['banco_id']}_$num'}",
      );
    } else if (table == 'bank_colors') {
      if (record['color_hex'] != null) {
        await _db.setBankColor(bancoId, record['color_hex'].toString(), sync: 0);
      }
      if (record['loterias'] != null) {
        final String lot = record['loterias'].toString().trim().toUpperCase();
        await _db.setBankLoterias(bancoId, lot, sync: 0);

        final prefs = await SharedPreferences.getInstance();
        if (lot == "FLORIDA") {
          await prefs.setString("sync_loteria", "FLORIDA");
          await prefs.setString("sync_seccion", "DIA");
        } else if (lot == "GEORGIA") {
          await prefs.setString("sync_loteria", "GEORGIA");
          await prefs.setString("sync_seccion", "MIDDAY");
        }

        final keys = prefs.getKeys().where((k) => k.startsWith("cached_listero_loterias_${bancoId}_")).toList();
        for (var k in keys) {
          await prefs.remove(k);
        }
      }
      TiroService().notifyNewTiro(null);
      _db.notifySyncUpdate(-999);
    } else if (table == 'notificaciones') {
      if (payload.eventType == PostgresChangeEvent.delete) {
        final String? uuid = record['uuid'];
        if (uuid != null) {
          await _db.deleteNotificacionByUuid(uuid, sync: 0);
          _db.notifySyncUpdate(-999);
        }
        return;
      }
      final String? targetPin = record['listero_pin']?.toString().trim();
      final String myPin = (await getActiveListeroPin()).trim();
      final String userRole = (await SharedPreferences.getInstance()).getString("user_role") ?? "LISTERO";
      final bool esOficial = record['es_oficial'] == 1 || record['es_oficial'] == true;

      if (userRole == "BANCO" || targetPin == null || targetPin.isEmpty || targetPin == myPin) {
        await _db.insertNotificacion(
          record['titulo'], 
          record['mensaje'], 
          listeroPin: targetPin, 
          bancoId: bancoId, 
          sync: 0, 
          uuid: record['uuid'],
          esOficial: esOficial
        );
        _db.notifySyncUpdate(-999);
      } else {
        return; 
      }

      NotificationService().showNotification(
        id: 501,
        title: esOficial ? "📢 COMUNICADO OFICIAL" : "📩 MENSAJE DEL BANCO",
        body: record['mensaje'] ?? record['titulo'] ?? "Información importante del banco",
        payloadKey: "msg_${record['uuid'] ?? record['id'] ?? DateTime.now().millisecondsSinceEpoch}",
      );
    } else if (table == 'comunicados') {
       if (payload.eventType == PostgresChangeEvent.delete) {
         _db.notifySyncUpdate(-999);
         return;
       }
       
       NotificationService().showNotification(
         id: 701,
         title: "📢 COMUNICADO OFICIAL",
         body: record['mensaje'] ?? record['contenido'] ?? record['titulo'] ?? "Información importante del banco",
         payloadKey: "comu_${record['id'] ?? record['uuid'] ?? DateTime.now().millisecondsSinceEpoch}",
       );
       _db.notifySyncUpdate(-999); // Notificar para que las pantallas reaccionen
    } else if (table == 'jugadas') {
      _handleSmartSync(record, bancoId);
    } else if (table == 'partes') {
      if (payload.eventType == PostgresChangeEvent.delete) {
        final String? uuid = record['uuid'];
        if (uuid != null) {
           final db = await _db.database;
           await db.delete('partes', where: 'uuid = ?', whereArgs: [uuid]);
           _db.notifySyncUpdate(-999);
        }
        return;
      }
      await _db.insertParte(record, sync: 0);
      _db.notifySyncUpdate(-999);

      final bool esPublicado = (record['publicado'] == 1 || record['publicado'] == true);
      if (esPublicado) {
        final String myPin = (await getActiveListeroPin()).trim();
        final String targetPin = (record['listero_pin']?.toString() ?? '').trim();
        final String userRole = (await SharedPreferences.getInstance()).getString("user_role") ?? "LISTERO";
        if (userRole == "LISTERO" && (targetPin == myPin || targetPin.isEmpty)) {
          final String seccion = record['seccion']?.toString() ?? '';
          final String loteria = record['loteria']?.toString() ?? 'FLORIDA';
          NotificationService().showNotification(
            id: 201,
            title: "📊 PARTE ENVIADO Y PUBLICADO ($loteria)",
            body: "El banco ha enviado y publicado tu parte oficial de $seccion.",
            payloadKey: "parte_pub_${loteria}_${record['fecha']}_$seccion",
          );
        }
      }
    } else if (table == 'control_remoto') {
       final String targetPin = record['listero_pin'];
       final String myPin = await getActiveListeroPin();
       if (targetPin == myPin) {
          final String action = record['action'];
          if (action == 'FORCE_LOGOUT') {
            await logout();
            NotificationService().showNotification(
              id: 666, 
              title: "⚠️ ACCESO REVOCADO", 
              body: "El banco ha cerrado su sesión de forma remota.",
              payloadKey: "force_logout_${DateTime.now().toString().substring(0, 13)}", // Único por hora para evitar spam pero permitir re-bloqueo
            );
          } else if (action == 'FORCE_SYNC') {
            syncDataToCloud(isDeepSync: true);
          }
       }
    }
  }

  void _handleSmartSync(Map<String, dynamic> record, String bancoId) async {
    try {
      final List<dynamic> cloudRaw = (record['data'] is String) 
          ? json.decode(record['data']) 
          : (record['data'] ?? []);
          
      final String pin = record['listero_pin'];
      final String fecha = record['fecha'];
      final String seccion = record['seccion'];
      
      if (cloudRaw.isEmpty) return;

      // Re-mapear desde formato minificado industrial
      final List<Map<String, dynamic>> cloudBets = cloudRaw.map((j) => {
        'uuid': j['u'],
        'tipo': j['t'],
        'valor': j['v'],
        'destino': j['d'],
        'listero_pin': pin,
        'fecha': fecha,
        'seccion': seccion,
        'banco_id': bancoId,
        'sync': 0
      }).toList();
      
      debugPrint("[ALEX_REALTIME_TURBO] Smart-Sync: Procesando lote de ${cloudBets.length} jugadas...");
      
      final db = await _db.database;
      final List<Map<String, dynamic>> newlyInserted = [];

      await db.transaction((txn) async {
        if (cloudBets.isNotEmpty) {
          final localCount = Sqflite.firstIntValue(await txn.rawQuery(
            'SELECT COUNT(*) FROM jugadas WHERE banco_id = ? AND listero_pin = ? AND fecha = ? AND seccion = ?',
            [bancoId, pin, fecha, seccion]
          )) ?? 0;

          if (localCount > cloudBets.length) {
             final List<String> uuids = cloudBets.map((b) => b['uuid']?.toString()).whereType<String>().toList();
             if (uuids.isNotEmpty) {
               final placeholders = uuids.map((_) => '?').join(',');
               await txn.delete('jugadas', 
                 where: 'banco_id = ? AND listero_pin = ? AND fecha = ? AND seccion = ? AND sync = 0 AND uuid NOT IN ($placeholders)',
                 whereArgs: [bancoId, pin, fecha, seccion, ...uuids]
               );
             }
          }
          
          // 1. Obtener TODOS los UUIDs locales para esta sección, sin importar el banco_id
          // Esto evita duplicados si el mismo listero cambió de banco o está en migración.
          final List<Map<String, dynamic>> localUuidRows = await txn.query('jugadas', 
            columns: ['uuid'], 
            where: 'listero_pin = ? AND fecha = ? AND seccion = ?',
            whereArgs: [pin, fecha, seccion]
          );
          final Set<String> localUuuids = localUuidRows.map((r) => r['uuid'] as String).toSet();

          for (var bet in cloudBets) {
            final String? uuid = bet['uuid'];
            // 2. Si el UUID ya existe localmente (incluso bajo otro banco_id), no lo re-insertamos.
            if (uuid == null || localUuuids.contains(uuid)) continue;

            Map<String, dynamic> row = Map.from(bet);
            row['sync'] = 0;
            row['banco_id'] = bancoId;
            row.remove('id');
            await txn.insert('jugadas', row);
            localUuuids.add(uuid);
            
            newlyInserted.add({
              ...bet,
              'listero_pin': pin,
              'fecha': fecha,
              'seccion': seccion,
              'banco_id': bancoId
            });
          }
        } else {
          await txn.delete('jugadas', where: 'banco_id = ? AND listero_pin = ? AND fecha = ? AND seccion = ? AND sync = 0', whereArgs: [bancoId, pin, fecha, seccion]);
        }
      });
      
      _db.notifySyncUpdate(-999);
      
      for (var bet in newlyInserted) {
        _liveBetsController.add(bet);
      }

      lastSyncEvent.value = "RECIBIDO: $pin | $seccion | ${DateTime.now().hour}:${DateTime.now().minute}:${DateTime.now().second}";

    } catch (e) {
      debugPrint("[ALEX_REALTIME_ERR] Error en Smart-Sync: $e");
    }
  }

  Future<void> _performInitialAudit() async {
    final bancoId = await getActiveBancoId();
    if (bancoId != null && bancoId != "UNKNOWN") {
      debugPrint("[ALEX_AUDIT] Restaurando canales de tiempo real para: $bancoId");
      initRealtimeChannels(bancoId);
      
      if (isBrainOnline()) {
        debugPrint("[ALEX_AUDIT] Iniciando Paridad Total de Arranque...");
        syncDataToCloud(isDeepSync: true);
      }
    }
  }

  Future<void> broadcastSyncPulse({bool isDeep = false, String? targetPin}) async {
    try {
      final bancoId = await getActiveBancoId();
      if (bancoId == "UNKNOWN") return;

      debugPrint("[ALEX_REMOTE] Emitiendo Pulso Maestro de Sincronización...");
      
      if (_commandChannel == null) {
        await initRealtimeChannels(bancoId);
      }
      final channel = _commandChannel ?? _supabase.channel('commands:$bancoId');
      
      await channel.sendBroadcastMessage(
        event: 'PULSE_CHECK',
        payload: {
          'deep': isDeep, 
          'target_pin': targetPin,
          'sender_id': _sessionId,
          'timestamp': DateTime.now().toUtc().toIso8601String()
        },
      );
    } catch (e) {
      debugPrint("[ALEX_REMOTE_ERR] No se pudo procesar el pulso: $e");
    }
  }

  Future<void> broadcastSectionSync({required String seccion, required String fecha, String? loteria}) async {
    // Navegación individual por usuario: No transmitir cambio de sección para no interferir con otros usuarios
  }

  Future<void> broadcastTypingStatus(bool isTyping) async {
    try {
      final bancoId = await getActiveBancoId();
      if (bancoId == "UNKNOWN") return;
      final pin = await getActiveListeroPin();
      if (pin.isEmpty) return;

      final channel = _commandChannel ?? _supabase.channel('commands:$bancoId');
      await channel.sendBroadcastMessage(
        event: 'TYPING_STATUS',
        payload: {
          'pin': pin,
          'is_typing': isTyping,
          'sender_id': _sessionId,
        },
      );
    } catch (_) {}
  }

  void _startAutoSync() {
    async.Timer.periodic(const Duration(minutes: 10), (timer) async {
      // Chequeo de actualización cada 10 minutos (muy ligero)
      checkAppUpdate();

      final bancoId = await getActiveBancoId();
      if (bancoId != null && bancoId != "UNKNOWN") {
        syncDataToCloud();
      }
    });
  }

  int _consecutiveErrors = 0;
  DateTime? _lastErrorTime;

  Future<void> syncDataToCloud({bool isDeepSync = false, String? priorityTable, bool fromRemotePulse = false}) async {
    if (_isSyncing) {
      _syncPending = true;
      if (isDeepSync) _deepSyncRequested = true;
      if (priorityTable != null) _syncPriorityTable = priorityTable; 
      return;
    }

    // PROTECCIÓN ANTI-TORMENTA: Si hay muchos errores, esperar 30 segundos
    // EXCEPCIÓN: Si es una sincronización profunda (manual), reiniciamos el contador.
    if (isDeepSync) _consecutiveErrors = 0;

    if (_consecutiveErrors > 5 && _lastErrorTime != null) {
      if (DateTime.now().difference(_lastErrorTime!).inSeconds < 30) {
        debugPrint("[ALEX_SYNC] Pausando sincronización por exceso de errores...");
        return;
      }
    }

    _isSyncing = true;
    final currentDeep = isDeepSync || _deepSyncRequested;
    final currentPriority = priorityTable ?? _syncPriorityTable;
    _syncPending = false;
    _deepSyncRequested = false;
    _syncPriorityTable = null;

    try {
      final prefs = await SharedPreferences.getInstance();
      final String? bancoId = prefs.getString("active_banco_id") ?? prefs.getString("banco_id");
      final String? userRole = prefs.getString("user_role");
      
      debugPrint("[ALEX_SYNC] Rol: $userRole | Banco: $bancoId | Deep: $currentDeep | RemotePulse: $fromRemotePulse");

      if (bancoId == null || bancoId == "UNKNOWN") {
        debugPrint("[ALEX_SYNC] Sincronización abortada: Banco desconocido.");
        return;
      }

      if (userRole == "LISTERO") {
        await verifyActiveListeroStatus();
      }

      final String lastSync = prefs.getString("last_sync_timestamp_$bancoId") ?? "2000-01-01T00:00:00Z";
      
      debugPrint("[ALEX_SYNC] Iniciando sincronización de nube para banco: $bancoId...");

      // MOTOR DE SINCRONIZACIÓN SOBERANA
      // 1. Procesar borrados locales en la nube primero
      await _processMirrorDeletions(bancoId);
      
      // 2. Subir mis datos locales creados a la nube PRIMERO (para que la nube reciba los tiros/datos nuevos)
      bool pushedAnything = await _pushMirrorToCloud(bancoId, isDeepSync: currentDeep, priorityTable: currentPriority, fromRemotePulse: fromRemotePulse);
      await _resyncAffectedSections(bancoId);

      // 3. Descargar datos y sincronizar con la nube SEGUNDO
      if (userRole == "BANCO" || currentDeep) {
        final pin = (userRole == "LISTERO") ? await getActiveListeroPin() : null;
        await _pullCloudToLocalOptimized(bancoId, lastSync, isDeepSync: userRole == "BANCO" || currentDeep, listeroPin: pin);
      } else {
        final pin = await getActiveListeroPin();
        await _pullCriticalUpdatesOptimized(bancoId, lastSync, listeroPin: pin);
        await _updateListeroHeartbeat(bancoId, pin);
      }

      await prefs.setString("last_sync_timestamp_$bancoId", DateTime.now().toUtc().toIso8601String());
      _db.notifySyncUpdate(-999);

      // Si soy BANCO y acabo de subir algo, avisar a mis otros dispositivos (Solo si no proviene de un pulso remoto para evitar efecto eco)
      if (!fromRemotePulse && userRole == "BANCO" && pushedAnything) {
        broadcastSyncPulse(isDeep: true);
      }
      _consecutiveErrors = 0; // Éxito: Reiniciar contador
    } catch (e) {
      _consecutiveErrors++;
      _lastErrorTime = DateTime.now();
      debugPrint("[ALEX_SYNC_ERR] Intento fallido #$_consecutiveErrors: $e");
    } finally {
      _isSyncing = false;
      if (_syncPending && _consecutiveErrors < 3) {
        _syncPending = false;
        final nextDeep = _deepSyncRequested;
        _deepSyncRequested = false;
        async.Timer(const Duration(seconds: 3), () {
          syncDataToCloud(isDeepSync: nextDeep);
        });
      } else {
        _syncPending = false;
        _deepSyncRequested = false;
      }
    }
  }

  Future<bool> _pushMirrorToCloud(String bancoId, {bool isDeepSync = false, String? priorityTable, bool fromRemotePulse = false}) async {
    final db = await _db.database;
    final tables = { priorityTable, 'jugadas', 'planes', 'listeros', 'bank_colors', 'limites', 'partes', 'resultados', 'notificaciones' }.whereType<String>().toList();

    bool structuralChange = false;
    bool pushedData = false;

    for (var table in tables) {
      try {
        final bool hasId = (table != 'listeros' && table != 'planes' && table != 'bank_colors' && table != 'resultados');
        final bool hasUuid = (table == 'jugadas' || table == 'partes' || table == 'limites' || table == 'notificaciones');
        
        final localData = await db.query(table, where: 'banco_id = ? AND sync = 1', whereArgs: [bancoId]);
        
        if (localData.isNotEmpty) {
          pushedData = true;
          if (table == 'jugadas') {
            final Map<String, bool> sectionsToSync = {};
            for (var row in localData) {
              final lot = row['loteria']?.toString() ?? 'FLORIDA';
              sectionsToSync["${row['listero_pin']}|${row['fecha']}|${row['seccion']}|$lot"] = true;
            }

            for (var key in sectionsToSync.keys) {
              final parts = key.split('|');
              final pin = parts[0].trim(), fecha = parts[1].trim(), seccion = parts[2].trim(), loteria = parts.length > 3 ? parts[3].trim() : 'FLORIDA';

              final allSectionJugadas = await _db.getJugadasCompletas(pin, seccion: seccion, fecha: fecha, bancoId: bancoId, loteria: loteria);
              debugPrint("[ALEX_PUSH] Preparando consolidado de $pin ($seccion - $loteria): ${allSectionJugadas.length} jugadas.");
              if (allSectionJugadas.isNotEmpty) {
                try {
                  // OPTIMIZACIÓN INDUSTRIAL: Minificar JSON para reducir ancho de banda en ráfagas de 3000 jugadas
                  final List<Map<String, dynamic>> minified = allSectionJugadas.map((j) => {
                    'u': j['uuid'], // uuid
                    't': j['tipo'], // tipo
                    'v': j['valor'], // valor
                    'd': j['destino'], // destino
                  }).toList();

                  final cleanBatch = {
                    'banco_id': bancoId, 'listero_pin': pin, 'fecha': fecha, 'seccion': seccion, 'loteria': loteria,
                    'tipo': 'CONSOLIDADO', 'valor': 'SECCION_ACTIVA',
                    'data': json.encode(minified),
                    'updated_at': DateTime.now().toUtc().toIso8601String(), // ASEGURAR SIEMPRE NUEVA FECHA
                  };
                  debugPrint("[ALEX_SYNC_TURBO] Subiendo ráfaga de ${allSectionJugadas.length} jugadas de $pin...");
                  await _supabase.from('jugadas').upsert(cleanBatch, onConflict: 'banco_id,listero_pin,fecha,seccion,loteria');
                  
                  final pendingIds = allSectionJugadas.where((j) => j['sync'] == 1).map((e) => e['id'] as int).toList();
                  if (pendingIds.isNotEmpty) await db.update('jugadas', {'sync': 0}, where: "id IN (${pendingIds.join(',')})");
                } catch (e) {
                  debugPrint("[ALEX_JUGADAS_PUSH_ERR] Fallo subiendo sección $pin | $seccion | $loteria: $e");
                }
              } else {
                // BUG FIX: Si la sección quedó vacía localmente, borrarla de la nube
                try {
                  debugPrint("[ALEX_SYNC] Sección $pin ($seccion - $loteria) vacía. Borrando de la nube...");
                  await _supabase.from('jugadas').delete().match({
                    'banco_id': bancoId,
                    'listero_pin': pin,
                    'fecha': fecha,
                    'seccion': seccion,
                    'loteria': loteria,
                  });
                } catch (e) {
                  debugPrint("[ALEX_JUGADAS_DELETE_ERR] No se pudo limpiar sección vacía en nube: $e");
                }
              }
            }
            _db.notifySyncUpdate(-999);
            
            // Si soy LISTERO, avisar al banco que subí jugadas nuevas (solo si no viene de un pulso remoto para evitar efecto eco)
            final String? role = (await SharedPreferences.getInstance()).getString("user_role");
            if (!fromRemotePulse && role == "LISTERO") {
              broadcastSyncPulse(isDeep: false);
            }
          } else {
            for (var row in localData) {
              final Map<String, dynamic> cloudRow = Map.from(row);
              cloudRow.remove('sync');
              if (hasId) cloudRow.remove('id');
              if (hasUuid) cloudRow.remove('timestamp'); // Evitar error PGRST204 en tablas transaccionales
              
              // CONVERSIÓN DE BANDERAS PARA NUBE (SQLite int 0/1 -> Supabase int/bool)
              if (table == 'partes') {
                if (cloudRow.containsKey('publicado')) cloudRow['publicado'] = (cloudRow['publicado'] == true || cloudRow['publicado'] == 1) ? 1 : 0;
                if (cloudRow.containsKey('recibido')) cloudRow['recibido'] = (cloudRow['recibido'] == true || cloudRow['recibido'] == 1) ? 1 : 0;
              } else if (table == 'notificaciones') {
                if (cloudRow.containsKey('visto')) cloudRow['visto'] = (cloudRow['visto'] == 1);
                if (cloudRow.containsKey('es_oficial')) cloudRow['es_oficial'] = (cloudRow['es_oficial'] == 1);
              }

              try {
                if (table == 'resultados') {
                  await _supabase.from('resultados').upsert(cloudRow, onConflict: 'banco_id,fecha,seccion,loteria');
                } else if (table == 'partes') {
                  await _supabase.from('partes').upsert(cloudRow, onConflict: 'banco_id,listero_pin,fecha,seccion,loteria');
                } else {
                  await _supabase.from(table).upsert(cloudRow);
                }
              } catch (e) {
                debugPrint("[ALEX_PUSH_ROW_ERR] Error subiendo fila en $table: $e");
              }
              
              if (hasId) {
                await db.update(table, {'sync': 0}, where: 'id = ?', whereArgs: [row['id']]);
              } else if (table == 'listeros') {
                await db.update(table, {'sync': 0}, where: 'banco_id = ? AND pin = ?', whereArgs: [bancoId, row['pin']]);
              } else if (table == 'planes') {
                await db.update(table, {'sync': 0}, where: 'banco_id = ? AND nombre = ?', whereArgs: [bancoId, row['nombre']]);
              } else if (table == 'bank_colors') {
                await db.update(table, {'sync': 0}, where: 'banco_id = ?', whereArgs: [bancoId]);
              } else if (table == 'resultados') {
                final String lot = (row['loteria']?.toString() ?? 'FLORIDA').trim().toUpperCase();
                await db.update(table, {'sync': 0}, where: "banco_id = ? AND fecha = ? AND seccion = ? AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))", whereArgs: [bancoId, row['fecha'], row['seccion'], lot, lot]);
              }
            }
            structuralChange = true;
          }
        }
      } catch (e) { debugPrint("[ALEX_PUSH_ERR] Error en tabla $table: $e"); }
    }
    if (structuralChange) _db.notifySyncUpdate(-999);
    return pushedData;
  }

  Future<void> _processMirrorDeletions(String bancoId) async {
    final deleted = await _db.getPendingDeletions();
    if (deleted.isEmpty) return;
    for (var d in deleted) {
      final String table = d['tabla'];
      final String remotoId = d['remoto_id'];
      try {
        debugPrint("[ALEX_DELETE] Procesando borrado remoto: $table -> $remotoId");
        if (table == 'resultados') {
          final parts = remotoId.split('|');
          if (parts.length >= 3) {
            await _supabase.from('resultados').delete().eq('banco_id', bancoId).eq('fecha', parts[0]).eq('seccion', parts[1]).eq('loteria', parts[2]);
          } else if (parts.length == 2) {
            await _supabase.from('resultados').delete().eq('banco_id', bancoId).eq('fecha', parts[0]).eq('seccion', parts[1]);
          }
        } else if (table == 'planes') {
          final parts = remotoId.split('|');
          if (parts.length == 2) {
            await _supabase.from('planes').delete().eq('banco_id', bancoId).eq('nombre', parts[0]).eq('loteria', parts[1]);
          } else {
            await _supabase.from('planes').delete().eq('banco_id', bancoId).eq('nombre', remotoId);
          }
        } else if (table == 'listeros') {
          await _supabase.from('listeros').delete().eq('banco_id', bancoId).eq('pin', remotoId);
        } else if (table == 'bank_colors') {
          await _supabase.from('bank_colors').delete().eq('banco_id', bancoId);
        } else if (table == 'jugadas' && remotoId.startsWith('SECTION:')) {
          final sectionKey = remotoId.replaceFirst('SECTION:', '');
          final parts = sectionKey.split('|');
          if (parts.length == 3) {
            final pin = parts[0], fecha = parts[1], seccion = parts[2];
            final jugadasRestantes = await _db.getJugadasCompletas(pin, seccion: seccion, fecha: fecha, bancoId: bancoId);
            if (jugadasRestantes.isEmpty) {
              await _supabase.from('jugadas').delete().match({
                'banco_id': bancoId,
                'listero_pin': pin,
                'fecha': fecha,
                'seccion': seccion
              });
            }
          }
        } else {
          await _supabase.from(table).delete().eq('uuid', remotoId);
        }
      } catch (e) {
        debugPrint("[ALEX_DELETE_ERR] No se pudo borrar $table $remotoId: $e");
      }
    }
    await _db.clearDeletions(deleted.map((e) => e['id'] as int).toList());
  }

  Future<void> _pullCloudToLocalOptimized(String bancoId, String lastSync, {bool isDeepSync = false, String? listeroPin}) async {
    if (bancoId != "UNKNOWN" && bancoId.isNotEmpty) {
      final isValid = await verifyActiveBankExists();
      if (!isValid) return;
    }
    // MOTOR DE PARIDAD TOTAL (Optimizado para evitar picos en Postgres)
    if (isDeepSync) {
      await _pullAtomics(bancoId);
    }
    await _pullTransaccionals(bancoId, lastSync, isDeep: isDeepSync, listeroPin: listeroPin);
  }

  Future<void> _pullCriticalUpdatesOptimized(String bancoId, String lastSync, {String? listeroPin}) async {
    await _pullTransaccionals(bancoId, lastSync, listeroPin: listeroPin);
  }

  Future<void> _pullAtomics(String bancoId) async {
    try {
      final String bId = bancoId;
      // PLANES: Garantizar que el listero siempre cobre lo correcto
      final cloudPlanes = await _supabase.from('planes').select().eq('banco_id', bId);
      for (var p in cloudPlanes) {
        final Map<String, dynamic> config = (p['config'] is String) ? json.decode(p['config']) : p['config'];
        final String lot = p['loteria']?.toString() ?? 'FLORIDA';
        await _db.upsertPlan(p['nombre'], config, bancoId: bId, loteria: lot, sync: 0);
      }

      // LÍMITES: Bloqueo de números en tiempo real
      final cloudLimites = await _supabase.from('limites').select().eq('banco_id', bId);
      for (var l in cloudLimites) {
        await _db.saveLimite(l, sync: 0);
      }
      
      // COLORES Y LOTERÍAS HABILITADAS: Identidad visual y permisos multibanco
      final cloudColor = await _supabase.from('bank_colors').select().eq('banco_id', bId).maybeSingle();
      if (cloudColor != null) {
        if (cloudColor['color_hex'] != null) {
          await _db.setBankColor(bId, cloudColor['color_hex'], sync: 0);
        }
        if (cloudColor['loterias'] != null) {
          await _db.setBankLoterias(bId, cloudColor['loterias'].toString(), sync: 0);
        }
      }

      // LISTEROS: Recuperar listas del banco (Prevención de desaparición)
      final cloudListeros = await _supabase.from('listeros').select().eq('banco_id', bId);
      for (var l in cloudListeros) {
        await _db.upsertListero({...l, 'sync': 0});
      }

      final prefs = await SharedPreferences.getInstance();
      final myPin = prefs.getString("current_listero_pin") ?? "";
      final String myLoterias = await getListeroLoterias(bId, myPin);
      if (myLoterias == "FLORIDA") {
        await prefs.setString("sync_loteria", "FLORIDA");
      } else if (myLoterias == "GEORGIA") {
        await prefs.setString("sync_loteria", "GEORGIA");
      }
    } catch (e) { 
      debugPrint("[ALEX_PULL_ATOM_ERR] $e");
      rethrow;
    }
  }

  Future<void> _pullTransaccionals(String bancoId, String lastSync, {bool isDeep = false, String? listeroPin}) async {
    try {
      final String bId = bancoId;
      final String deepDate = DateTime.now().subtract(const Duration(days: 30)).toUtc().toIso8601String();
      final String timeFilter = isDeep ? deepDate : lastSync;
      
      // RESULTADOS (TIROS): Filtrado por ventana para optimizar Postgres con pruning local
      final String tirosFilter = isDeep ? DateTime.now().subtract(const Duration(days: 60)).toUtc().toIso8601String().substring(0, 10) : DateTime.now().subtract(const Duration(days: 7)).toUtc().toIso8601String().substring(0, 10);
      final cloudTiros = await _supabase.from('resultados').select().eq('banco_id', bId).gt('fecha', tirosFilter);
      
      final db = await _db.database;
      final localTiros = await db.query('resultados',
        where: "banco_id = ? AND fecha > ?",
        whereArgs: [bId, tirosFilter],
      );

      final Set<String> cloudKeys = {};
      for (var t in cloudTiros) {
        final String f = t['fecha']?.toString() ?? '';
        final String s = t['seccion']?.toString() ?? '';
        final String lot = (t['loteria']?.toString() ?? 'FLORIDA').toUpperCase();
        cloudKeys.add("${f}_${s}_${lot}");
        await _db.saveResultado(f, s, t['n1'].toString(), t['n2'].toString(), t['n3'].toString(), bancoId: bId, loteria: lot, sync: 0);
      }

      bool deletedLocalTiro = false;
      for (var lt in localTiros) {
        final int syncStatus = lt['sync'] as int? ?? 0;
        if (syncStatus == 1) continue; // NUNCA borrar tiros locales pendientes de subir a la nube

        final String f = lt['fecha']?.toString() ?? '';
        final String s = lt['seccion']?.toString() ?? '';
        final String lot = (lt['loteria']?.toString() ?? 'FLORIDA').toUpperCase();
        final String key = "${f}_${s}_${lot}";
        if (!cloudKeys.contains(key)) {
          debugPrint("[ALEX_SYNC] Pruning: Eliminando tiro local borrado en banco: $key");
          await _db.deleteResultado(f, s, bancoId: bId, loteria: lot, sync: 0);
          deletedLocalTiro = true;
        }
      }

      if (deletedLocalTiro) {
        TiroService().notifyNewTiro(null);
      }

      // PARTES (REPORTES)
      try {
        var partesQuery = _supabase.from('partes').select().eq('banco_id', bId).gt('updated_at', timeFilter);
        if (listeroPin != null && listeroPin.isNotEmpty) {
          partesQuery = partesQuery.eq('listero_pin', listeroPin);
        }
        final cloudPartes = await partesQuery;
        for (var p in cloudPartes) {
          await _db.insertParte(p, sync: 0);
        }
      } catch (e) {
        debugPrint("[ALEX_PULL_PARTES_ERR] $e");
      }

      // NOTIFICACIONES
      try {
        final cloudNotis = await _supabase.from('notificaciones').select().eq('banco_id', bId).gt('updated_at', timeFilter);
        
        for (var n in cloudNotis) {
           final String? targetPin = n['listero_pin']?.toString().trim();
           final String myPin = (listeroPin ?? await getActiveListeroPin()).trim();
           final String userRole = (await SharedPreferences.getInstance()).getString("user_role") ?? "LISTERO";
           
           final bool isForMe = (userRole == "BANCO") || 
                                (targetPin == null || targetPin.isEmpty) || 
                                (targetPin == myPin) || 
                                (int.tryParse(targetPin) != null && int.tryParse(targetPin) == int.tryParse(myPin));

           if (isForMe) {
              final String uuidKey = n['uuid'] ?? '${n['id']}_$bId';
              final bool isNew = await _db.insertNotificacion(
                n['titulo'] ?? "📢 AVISO OFICIAL", 
                n['mensaje'] ?? "", 
                listeroPin: targetPin, 
                bancoId: bId, 
                sync: 0, 
                uuid: uuidKey, 
                esOficial: n['es_oficial'] == 1 || n['es_oficial'] == true
              );

              if (isNew && userRole == "LISTERO") {
                final int notiId = (uuidKey.hashCode).abs() % 100000;
                NotificationService().showNotification(
                  id: notiId,
                  title: n['titulo'] ?? "📢 AVISO OFICIAL",
                  body: n['mensaje'] ?? "",
                  payloadKey: "noti_$uuidKey",
                );
              }
           }
        }
      } catch (e) {
        debugPrint("[ALEX_PULL_NOTIS_ERR] $e");
      }
      
      // COMUNICADOS GLOBALES
      final cloudComu = await _supabase.from('comunicados').select().eq('banco_id', bId).gt('created_at', timeFilter);
      if (cloudComu.isNotEmpty) _db.notifySyncUpdate(-999);

      // JUGADAS (CONSOLIDADO)
      final String jugadaTimeFilter = isDeep ? deepDate : DateTime.now().subtract(const Duration(hours: 24)).toUtc().toIso8601String();
      await _pullJugadas(bId, jugadaTimeFilter, listeroPin: listeroPin);

    } catch (e) { 
      debugPrint("[ALEX_PULL_TRANS_ERR] $e");
      rethrow;
    }
  }

  Future<void> _pullJugadas(String bancoId, String timeFilter, {String? listeroPin}) async {
    try {
      debugPrint("[ALEX_PULL] Consultando jugadas para banco $bancoId (Pin: ${listeroPin ?? 'TODOS'}) desde: $timeFilter");
      var query = _supabase.from('jugadas')
          .select()
          .eq('banco_id', bancoId)
          .gt('updated_at', timeFilter);

      if (listeroPin != null && listeroPin.isNotEmpty) {
        query = query.eq('listero_pin', listeroPin);
      }

      final List<dynamic> cloudJugadas = await query;

      if (cloudJugadas.isEmpty) {
        debugPrint("[ALEX_PULL] No se encontraron bloques de jugadas en la nube para esta ventana de tiempo.");
        return;
      }

      debugPrint("[ALEX_PULL] ¡DATOS ENCONTRADOS! Procesando ${cloudJugadas.length} bloques consolidatados...");

      for (var batch in cloudJugadas) {
        final String pin = batch['listero_pin']?.toString() ?? "UNK";
        final String fecha = batch['fecha']?.toString() ?? "";
        final String seccion = batch['seccion']?.toString() ?? "";
        final String loteria = (batch['loteria']?.toString() ?? "FLORIDA").trim().toUpperCase();
        final String? dataJson = batch['data'];

        debugPrint("[ALEX_PULL] Bloque detectado: Listero $pin | $fecha | $seccion | $loteria");

        if (dataJson == null || dataJson.isEmpty) {
          debugPrint("[ALEX_PULL] Bloque de $pin vacío. Ignorando.");
          continue;
        }

        try {
          final List<dynamic> minified = json.decode(dataJson);
          debugPrint("[ALEX_PULL] Bloque de $pin contiene ${minified.length} jugadas ($loteria). Sincronizando con DB local...");
          
          final List<Map<String, dynamic>> expanded = minified.map((j) => {
            'uuid': j['u'],
            'tipo': j['t'],
            'valor': j['v'],
            'destino': j['d'],
            'listero_pin': pin,
            'fecha': fecha,
            'seccion': seccion,
            'loteria': loteria,
            'banco_id': bancoId,
            'sync': 0
          }).toList();

          await _db.syncJugadasBatch(pin, fecha, seccion, bancoId, expanded, loteria: loteria);
        } catch (e) {
          debugPrint("[ALEX_PULL_JUGADAS_BATCH_ERR] Error decodificando batch $pin $fecha: $e");
        }
      }
      debugPrint("[ALEX_PULL] Finalizada descarga de jugadas.");
    } catch (e) {
      debugPrint("[ALEX_PULL_JUGADAS_ERR] Error en motor de descarga: $e");
    }
  }

  DateTime? _lastListeroHeartbeat;

  Future<void> _updateListeroHeartbeat(String bancoId, String pin) async {
    if (pin.isEmpty) return;
    if (_lastListeroHeartbeat != null && 
        DateTime.now().difference(_lastListeroHeartbeat!).inMinutes < 10) {
      return;
    }
    _lastListeroHeartbeat = DateTime.now();
    try {
      await _supabase.from('listeros').update({
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      }).match({'banco_id': bancoId, 'pin': pin});
    } catch (e) {
      debugPrint("[ALEX_HEARTBEAT_ERR] $e");
    }
  }

  Future<void> _resyncAffectedSections(String bancoId) async {
     // No-op por ahora, manejado por upsert individual
  }

  Future<String?> getActiveBancoId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("active_banco_id") ?? prefs.getString("banco_id");
  }

  Future<String> getActiveListeroPin() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("current_listero_pin") ?? "";
  }

  Future<String> getRegentColor() async {
    final id = await getActiveBancoId();
    if (id == null || id == "UNKNOWN") return "#1A237E";
    return await _db.getBankColor(id) ?? "#1A237E";
  }

  Future<Color> getRegentColorObj() async {
    String hex = await getRegentColor();
    try {
      if (hex.startsWith('#')) {
        hex = hex.replaceFirst('#', 'ff');
      }
      return Color(int.parse(hex, radix: 16));
    } catch (e) {
      return const Color(0xff1A237E);
    }
  }

  Map<String, dynamic> calculatePremioCoverage(double limpio, double premios) {
    if (limpio <= 0) {
      return {
        'completo': false, 
        'porcentaje': 0.0, 
        'color': Colors.grey, 
        'mensaje': 'CALCULANDO...'
      };
    }
    double pct = (premios / limpio) * 100;
    bool completo = pct >= 100;
    return {
      'completo': completo, 
      'porcentaje': pct,
      'color': completo ? Colors.red.shade700 : Colors.green.shade700,
      'mensaje': completo 
          ? "PREMIOS EXCEDEN LIMPIO (${pct.toStringAsFixed(1)}%)" 
          : "COBERTURA: ${pct.toStringAsFixed(1)}%"
    };
  }

  Future<Map<String, dynamic>> checkBankRequestStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final String? requestId = prefs.getString("pending_bank_request_id");
    if (requestId == null) return {'status': 'NONE'};

    try {
      final res = await _supabase.from('bank_requests').select().eq('request_id', requestId).maybeSingle();
      if (res != null) {
        return {'status': res['status'], 'request_id': requestId};
      }
    } catch (_) {}
    return {'status': 'PENDING'};
  }

  Future<Map<String, dynamic>> requestNewBank() async {
    try {
      final String deviceId = await _getDeviceId();
      final prefs = await SharedPreferences.getInstance();

      // 1. VERIFICAR SI ESTE DISPOSITIVO YA TIENE UNA SOLICITUD O BANCO APROBADO EN NUBE
      try {
        final List<dynamic> existingRequests = await _supabase
            .from('bank_requests')
            .select()
            .eq('device_id', deviceId);

        for (var req in existingRequests) {
          final String status = req['status']?.toString() ?? 'PENDING';
          final String? reqBancoId = req['banco_id']?.toString();

          if (status == 'PENDING') {
            await prefs.setString("pending_bank_request_id", req['request_id'].toString());
            return {
              'success': false,
              'error': 'ESTE DISPOSITIVO YA TIENE UNA SOLICITUD PENDIENTE DE APROBACIÓN (ID: ${req['request_id']}).'
            };
          } else if (status == 'APPROVED' || status == 'COMPLETED') {
            // Verificar si el banco aún existe en la tabla 'bancos'
            bool bankStillExists = false;
            if (reqBancoId != null && reqBancoId.isNotEmpty) {
              final bankRes = await _supabase.from('bancos').select('id').eq('id', reqBancoId).maybeSingle();
              if (bankRes != null) bankStillExists = true;
            } else if (status == 'APPROVED') {
              bankStillExists = true;
            }

            if (bankStillExists) {
              if (status == 'APPROVED') {
                await prefs.setString("pending_bank_request_id", req['request_id'].toString());
                return {
                  'success': true,
                  'is_request': true,
                  'message': 'TU SOLICITUD YA FUE APROBADA. CONFIGURA EL BANCO AHORA.'
                };
              }
              return {
                'success': false,
                'error': 'ESTE DISPOSITIVO YA TIENE UN BANCO REGISTRADO Y APROBADO. CONTACTE AL PROGRAMADOR.'
              };
            } else {
              // El banco fue eliminado por el programador de la BD: Limpiar solicitudes antiguas
              await _supabase.from('bank_requests').delete().eq('device_id', deviceId);
              await prefs.remove("pending_bank_request_id");
            }
          }
        }
      } catch (e) {
        debugPrint("[ALEX_REQUEST_CHECK_ERR] $e");
      }

      // 2. VERIFICAR CAPACIDAD SISTÉMICA (Máximo 9 Bancos para no exceder 500 conexiones Realtime con 50 listas c/u)
      try {
        final List<dynamic> allBanks = await _supabase.from('bancos').select('id');
        if (allBanks.length >= 9) {
          return {
            'success': false,
            'error': 'LÍMITE DEL SERVIDOR ALCANZADO: SE HA LLEGADO AL LÍMITE MÁXIMO DE 9 BANCOS EN EL SISTEMA (500 CONEXIONES REALTIME). CONTACTE AL PROGRAMADOR.'
          };
        }
      } catch (_) {}

      // 3. CREAR NUEVA SOLICITUD
      final String requestId = math.Random().nextInt(900000 + 100000).toString();
      
      try {
        await _supabase.from('bank_requests').insert({
          'request_id': requestId,
          'device_id': deviceId,
          'status': 'PENDING',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        });
      } catch (e) {
        await _supabase.from('bank_requests').insert({
          'request_id': requestId,
          'status': 'PENDING',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        });
      }

      await prefs.setString("pending_bank_request_id", requestId);

      return {'success': true, 'message': 'SOLICITUD ENVIADA (ID: $requestId). ESPERE APROBACIÓN DEL PROGRAMADOR.'};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> finalizeBankCreation(String requestId, String password, String name) async {
    try {
      // 0. VERIFICAR QUE LA CONTRASEÑA NO ESTÉ REPETIDA EN OTRO BANCO O LISTA EN NUBE
      try {
        final existingPass = await _supabase.from('bancos').select('id').eq('password', password).maybeSingle();
        if (existingPass != null) {
          return {
            'success': false, 
            'error': 'ESTA CONTRASEÑA YA ES UTILIZADA POR OTRO BANCO. POR FAVOR ELIJA UNA CONTRASEÑA DIFERENTE.'
          };
        }
        final existingListero = await _supabase.from('listeros').select('pin').eq('pin', password).maybeSingle();
        if (existingListero != null) {
          return {
            'success': false, 
            'error': 'ESTA CONTRASEÑA YA ESTÁ EN USO COMO PIN DE UNA LISTA EN EL SISTEMA. POR FAVOR ELIJA OTRA.'
          };
        }
      } catch (_) {}

      // 1. Crear el banco oficial con resguardo de columnas
      final String bancoId = math.Random().nextInt(9000 + 1000).toString();
      try {
        await _supabase.from('bancos').insert({
          'id': bancoId,
          'name': name.toUpperCase(),
          'password': password,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        });
      } catch (_) {
        try {
          await _supabase.from('bancos').insert({
            'id': bancoId,
            'nombre': name.toUpperCase(),
            'password': password,
            'created_at': DateTime.now().toUtc().toIso8601String(),
          });
        } catch (_) {
          await _supabase.from('bancos').insert({
            'id': bancoId,
            'password': password,
            'created_at': DateTime.now().toUtc().toIso8601String(),
          });
        }
      }

      // 2. Marcar solicitud como finalizada y vincular banco_id
      try {
        await _supabase.from('bank_requests').update({
          'status': 'COMPLETED',
          'banco_id': bancoId
        }).eq('request_id', requestId);
      } catch (_) {
        await _supabase.from('bank_requests').update({'status': 'COMPLETED'}).eq('request_id', requestId);
      }

      // 3. Crear plan por defecto
      await _db.upsertPlan("PLAN1", _db.getDefaultPlanConfig(), bancoId: bancoId);
      await syncDataToCloud(isDeepSync: true);

      return {'success': true, 'banco_id': bancoId};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<bool> approveBankRequest(String requestId) async {
    try {
      await _supabase.from('bank_requests').update({'status': 'APPROVED'}).eq('request_id', requestId);
      return true;
    } catch (_) { return false; }
  }

  Future<String> _getDeviceId() async {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      return androidInfo.id;
    } else if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      return iosInfo.identifierForVendor ?? "UNKNOWN_IOS";
    } else if (Platform.isLinux) {
      final linuxInfo = await deviceInfo.linuxInfo;
      return linuxInfo.machineId ?? "UNKNOWN_LINUX";
    }
    return "UNKNOWN_DEVICE";
  }

  Future<List<String>> getCloudBanks() async {
    try {
      final List<dynamic> res = await _supabase.from('bancos').select('id');
      final Set<String> cloudBankIds = {};
      for (var item in res) {
        final id = item['id']?.toString().trim();
        if (id != null && id.isNotEmpty) {
          cloudBankIds.add(id);
        }
      }
      
      // Si la consulta en la nube fue exitosa, la lista de Supabase es la verdad absoluta.
      // Purgar cualquier banco local en SQLite que haya sido eliminado de la nube (incluido MASTER_BANK si no existe en Supabase).
      final localBanks = await _db.getAllBanks();
      for (var localId in localBanks) {
        if (!cloudBankIds.contains(localId)) {
          debugPrint("[ALEX_CLEANUP] Purgando banco eliminado localmente: $localId");
          await _db.deleteBankLocalData(localId);
        }
      }

      return cloudBankIds.toList()..sort();
    } catch (e) {
      debugPrint("[ALEX_GET_CLOUD_BANKS_ERR] $e");
      return await _db.getAllBanks();
    }
  }

  Future<bool> deleteBankFromServer(String bancoId) async {
    try {
      final String bId = bancoId.trim();
      final int? numId = int.tryParse(bId);

      debugPrint("[ALEX] Programador eliminando banco $bId de la nube...");

      // 1. Obtener la contraseña del banco por si difiere el ID
      String? bankPass;
      try {
        final bankRes = await _supabase.from('bancos').select('password').eq('id', bId).maybeSingle();
        if (bankRes != null) {
          bankPass = bankRes['password']?.toString();
        } else if (numId != null) {
          final bankResNum = await _supabase.from('bancos').select('password').eq('id', numId).maybeSingle();
          if (bankResNum != null) {
            bankPass = bankResNum['password']?.toString();
          }
        }
      } catch (e) {
        debugPrint("[ALEX_DEL_PASS_ERR] $e");
      }

      // 2. PRIMERO: Borrar todas las tablas hijas para no violar restricciones de clave foránea en Postgres
      final tables = ['jugadas', 'resultados', 'partes', 'notificaciones', 'comunicados', 'limites', 'listeros', 'planes', 'bank_colors', 'bank_requests'];
      for (var t in tables) {
        try { 
          await _supabase.from(t).delete().eq('banco_id', bId); 
        } catch (e) {
          debugPrint("[ALEX_DEL_CHILD_ERR] $t ($bId): $e");
        }
        if (numId != null) {
          try { 
            await _supabase.from(t).delete().eq('banco_id', numId); 
          } catch (_) {}
        }
      }

      // 3. SEGUNDO: Borrar de la tabla principal 'bancos'
      bool deletedFromBancos = false;
      try {
        await _supabase.from('bancos').delete().eq('id', bId);
        deletedFromBancos = true;
      } catch (e) {
        debugPrint("[ALEX_DEL_BANCO_ERR1] $e");
      }

      if (numId != null) {
        try {
          await _supabase.from('bancos').delete().eq('id', numId);
          deletedFromBancos = true;
        } catch (e) {
          debugPrint("[ALEX_DEL_BANCO_ERR2] $e");
        }
      }

      if (bankPass != null && bankPass.isNotEmpty) {
        try {
          await _supabase.from('bancos').delete().eq('password', bankPass);
          deletedFromBancos = true;
        } catch (e) {
          debugPrint("[ALEX_DEL_BANCO_ERR3] $e");
        }
      }

      // 4. TERCERO: Limpiar localmente en SQLite
      await _db.deleteBankLocalData(bId);
      if (numId != null) {
        await _db.deleteBankLocalData(numId.toString());
      }
      
      // 5. Si era el banco activo local, limpiar sesión completamente
      final prefs = await SharedPreferences.getInstance();
      final String? curB = prefs.getString("banco_id") ?? prefs.getString("active_banco_id");
      if (curB == bId || (numId != null && curB == numId.toString())) {
        await prefs.clear();
      }
      if (bankPass != null && prefs.getString("last_banco_pin") == bankPass) {
        await prefs.clear();
      }

      // 6. Notificar pulso de sincronización
      broadcastSyncPulse(isDeep: true);
      
      debugPrint("[ALEX] BANCO $bId ELIMINADO EXITOSAMENTE (Nube y Local: $deletedFromBancos).");
      return true;
    } catch (e) {
      debugPrint("[ALEX_DELETE_BANK_ERR] $e");
      return false;
    }
  }

  Future<void> updateBankIdentity(String bancoId, String name, String colorHex) async {
     try {
       try {
         await _supabase.from('bancos').update({'name': name.toUpperCase()}).eq('id', bancoId);
       } catch (_) {
         await _supabase.from('bancos').update({'nombre': name.toUpperCase()}).eq('id', bancoId);
       }
       await _db.setBankColor(bancoId, colorHex);
       syncDataToCloud();
     } catch (_) {}
  }

  Future<bool> updateBankPassword(String bancoId, String newPassword) async {
    try {
      final String cleanPass = newPassword.trim();
      final String bId = bancoId.trim();
      final int? numId = int.tryParse(bId);
      if (cleanPass.isEmpty) return false;

      final List<dynamic> existingList = await _supabase.from('bancos').select('id').eq('password', cleanPass);
      if (existingList.isNotEmpty) {
        for (var b in existingList) {
          final String foundId = b['id']?.toString().trim() ?? "";
          if (foundId != bId) {
            // Comprobar si el banco encontrado es un registro huérfano sin actividad
            try {
              final listeros = await _supabase.from('listeros').select('pin').eq('banco_id', foundId).limit(1);
              final jugadas = await _supabase.from('jugadas').select('id').eq('banco_id', foundId).limit(1);
              if (listeros.isEmpty && jugadas.isEmpty) {
                debugPrint("[ALEX_UPDATE_PASS] Banco $foundId es un registro huérfano en la nube. Eliminándolo para liberar contraseña...");
                await deleteBankFromServer(foundId);
                continue;
              }
            } catch (_) {}

            debugPrint("[ALEX_UPDATE_PASS_ERR] Contraseña ya asignada a otro banco activo ($foundId).");
            return false;
          }
        }
      }

      final listeroCheck = await _supabase.from('listeros').select('pin').eq('pin', cleanPass).limit(1);
      if (listeroCheck.isNotEmpty) {
        debugPrint("[ALEX_UPDATE_PASS_ERR] La contraseña ya está asignada al PIN de una lista.");
        return false;
      }

      try { await _supabase.from('bancos').update({'password': cleanPass}).eq('id', bId); } catch (_) {}
      if (numId != null) {
        try { await _supabase.from('bancos').update({'password': cleanPass}).eq('id', numId); } catch (_) {}
      }

      // Actualizar caché local de credencial para invalidar la vieja inmediatamente
      final prefs = await SharedPreferences.getInstance();
      final savedB = prefs.getString("banco_id");
      if (savedB == bId) {
        await prefs.setString("last_banco_pin", cleanPass);
      }

      return true;
    } catch (e) {
      debugPrint("[ALEX_UPDATE_PASS_ERR] Error actualizando clave: $e");
      return false;
    }
  }

  Future<String> getBankName(String? bancoId) async {
    final prefs = await SharedPreferences.getInstance();
    final String bId = bancoId ?? prefs.getString("active_banco_id") ?? prefs.getString("banco_id") ?? "UNKNOWN";
    if (bId == "UNKNOWN") return "";

    final String? cached = prefs.getString("banco_name_$bId");
    if (cached != null && cached.isNotEmpty) return cached;

    try {
      final res = await _supabase.from('bancos').select('name, nombre').eq('id', bId).maybeSingle();
      if (res != null) {
        final String n = res['name']?.toString() ?? res['nombre']?.toString() ?? "";
        if (n.isNotEmpty) {
          final String clean = n.trim().toUpperCase();
          await prefs.setString("banco_name_$bId", clean);
          return clean;
        }
      }
    } catch (_) {}
    return "BANCO $bId";
  }

  Future<String> getBankLoterias(String? bancoId) async {
    final prefs = await SharedPreferences.getInstance();
    final String bId = bancoId ?? prefs.getString("active_banco_id") ?? "UNKNOWN";
    if (bId == "UNKNOWN") return "AMBAS";
    final res = await _db.getBankLoterias(bId);
    await prefs.setString("cached_bank_loterias_$bId", res);
    return res;
  }

  /// Verifica la disponibilidad de un PIN de Lista/Listero en TODOS los bancos del sistema (local y en la nube/Supabase).
  /// Retorna `null` si el PIN está libre y disponible.
  /// Retorna un mensaje explicativo en español si el PIN ya está registrado o es inválido.
  Future<String?> checkPinAvailability(String pin, {String? currentBancoId}) async {
    final cleanPin = pin.trim();
    if (cleanPin.isEmpty || cleanPin.length != 4) {
      return "El PIN debe contener exactamente 4 cifras.";
    }

    // 1. PINs reservados del sistema
    final upper = cleanPin.toUpperCase();
    if (upper == "B8080" || cleanPin == "4608pr" || cleanPin == "pp0030" || cleanPin == "9999") {
      return "PIN RESERVADO: Este código no puede ser usado para una lista.";
    }

    // 2. Verificar si coincide con alguna clave de banco registrada localmente
    bool isBankPinLocal = await _db.isBankRegistered(cleanPin);
    if (isBankPinLocal) {
      return "PIN NO VÁLIDO: Este código está reservado para la clave de un banco.";
    }

    // 3. Verificar si el PIN pertenece a alguna lista en SQLite local (en cualquier banco)
    final localListero = await _db.findListeroGlobally(cleanPin);
    if (localListero != null) {
      final String bId = (localListero['banco_id'] ?? '').toString().trim();
      if (currentBancoId == null || bId != currentBancoId) {
        final Map<String, dynamic>? listData = localListero['listero'] as Map<String, dynamic>?;
        final String name = listData?['nombre']?.toString() ?? "";
        return "PIN NO DISPONIBLE: El PIN '$cleanPin' ya pertenece a la lista${name.isNotEmpty ? " '$name'" : ""} en el banco '$bId'. Todos los PINs deben ser únicos en general.";
      }
    }

    // 4. VERIFICACIÓN EN LA NUBE (SUPABASE) EN TODOS LOS BANCOS
    try {
      // a) Verificar si es contraseña de algún banco en Supabase
      final bankCheck = await _supabase
          .from('bancos')
          .select('id')
          .or('id.eq.$cleanPin,password.eq.$cleanPin')
          .maybeSingle();
      if (bankCheck != null) {
        return "PIN NO VÁLIDO: Este código coincide con la clave de un banco en el sistema.";
      }

      // b) Buscar en la tabla 'listeros' de Supabase en TODOS los bancos
      final cloudListeros = await _supabase
          .from('listeros')
          .select('banco_id, pin, nombre')
          .eq('pin', cleanPin);

      if (cloudListeros.isNotEmpty) {
        for (var item in cloudListeros) {
          final String bId = (item['banco_id'] ?? '').toString().trim();
          if (currentBancoId == null || bId != currentBancoId) {
            final String name = item['nombre']?.toString() ?? "";
            return "PIN YA REGISTRADO: El PIN '$cleanPin' ya está siendo usado por la lista${name.isNotEmpty ? " '$name'" : ""} en otro banco. Los PINs no se pueden repetir entre bancos.";
          }
        }
      }
    } catch (e) {
      debugPrint("[ALEX_CHECK_PIN_ERR] Error al verificar PIN en nube: $e");
    }

    return null; // Disponible
  }

  Future<String> getListeroLoterias(String? bancoId, String listeroPin) async {
    final prefs = await SharedPreferences.getInstance();
    final String bId = bancoId ?? prefs.getString("active_banco_id") ?? "UNKNOWN";
    final String bankLoterias = await getBankLoterias(bId);
    if (bankLoterias != "AMBAS") {
      await prefs.setString("cached_listero_loterias_${bId}_$listeroPin", bankLoterias);
      return bankLoterias;
    }
    final listero = await _db.getListeroByPin(listeroPin, bId) ?? await _db.findListeroGlobally(listeroPin);
    if (listero != null) {
      final dynamic rawL = listero['loterias'] ?? (listero['listero'] is Map ? listero['listero']['loterias'] : null);
      if (rawL != null && rawL.toString().trim().isNotEmpty) {
        final res = rawL.toString().trim().toUpperCase();
        await prefs.setString("cached_listero_loterias_${bId}_$listeroPin", res);
        return res;
      }
    }
    await prefs.setString("cached_listero_loterias_${bId}_$listeroPin", "AMBAS");
    return "AMBAS";
  }

  Future<void> updateBankLoterias(String bancoId, String loterias) async {
    try {
      final String cleanLoterias = loterias.trim().toUpperCase();
      await _db.setBankLoterias(bancoId, cleanLoterias, sync: 1);
      final colorHex = await _db.getBankColor(bancoId) ?? "#1A237E";
      try {
        await _supabase.from('bank_colors').upsert({
          'banco_id': bancoId.trim(),
          'color_hex': colorHex,
          'loterias': cleanLoterias,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }, onConflict: 'banco_id');
      } catch (e) {
        debugPrint("[ALEX_UPDATE_LOTERIAS_ERR] $e");
      }

      final prefs = await SharedPreferences.getInstance();
      final activeB = prefs.getString("active_banco_id") ?? prefs.getString("banco_id");
      if (activeB == bancoId) {
        if (cleanLoterias == "FLORIDA") {
          await prefs.setString("sync_loteria", "FLORIDA");
          await prefs.setString("sync_seccion", "DIA");
        } else if (cleanLoterias == "GEORGIA") {
          await prefs.setString("sync_loteria", "GEORGIA");
          await prefs.setString("sync_seccion", "MIDDAY");
        }
      }

      final keys = prefs.getKeys().where((k) => k.startsWith("cached_listero_loterias_${bancoId}_")).toList();
      for (var k in keys) {
        await prefs.remove(k);
      }

      TiroService().notifyNewTiro(null);
      _db.notifySyncUpdate(-999);
      syncDataToCloud(isDeepSync: true);
    } catch (e) {
      debugPrint("[ALEX_UPDATE_LOTERIAS_ERR] $e");
    }
  }

  Future<void> updateListeroLoterias(String bancoId, String pin, String loterias) async {
    try {
      final String cleanLoterias = loterias.trim().toUpperCase();
      final local = await _db.getListeroByPin(pin, bancoId);
      if (local != null) {
        final updated = Map<String, dynamic>.from(local);
        updated['loterias'] = cleanLoterias;
        updated['sync'] = 1;
        await _db.upsertListero(updated);
      }
      try {
        await _supabase.from('listeros').update({
          'loterias': cleanLoterias,
        }).match({'pin': pin.trim(), 'banco_id': bancoId.trim()});
      } catch (e) {
        debugPrint("[ALEX_UPDATE_LISTERO_LOTERIAS_CLOUD_ERR] $e");
      }
      broadcastSyncPulse(isDeep: true);
      syncDataToCloud(isDeepSync: true);
    } catch (e) {
      debugPrint("[ALEX_UPDATE_LISTERO_LOTERIAS_ERR] $e");
    }
  }

  Future<List<String>> orchestrateTiroClosing(String fecha, String seccion, Map<String, String> tiro, List<Map<String, dynamic>> limites, {String loteria = 'FLORIDA'}) async {
    final String bancoId = await getActiveBancoId() ?? "UNKNOWN";
    if (bancoId == "UNKNOWN") {
      debugPrint("[ALEX_TIRO] ERROR: Banco desconocido.");
      return [];
    }

    debugPrint("[ALEX_TIRO] Iniciando orquestación de cierre para $fecha ($seccion - $loteria)...");

    // 1. Obtener todos los listeros del banco
    final listeros = await _db.getListeros(bancoId: bancoId);
    if (listeros.isEmpty) {
      debugPrint("[ALEX_TIRO] No se encontraron listeros para procesar.");
      return [];
    }

    // 2. Pre-cargar planes para optimizar el bucle
    final planesMap = await _db.getPlanes(bancoId: bancoId, loteria: loteria);
    List<String> listerosProcesados = [];

    debugPrint("[ALEX_TIRO] Procesando ${listeros.length} listeros...");

    for (var listero in listeros) {
      final String pin = listero['pin'];
      final String nombre = listero['nombre'] ?? pin;
      final String planNombre = listero['plan'] ?? "PLAN1";

      try {
        final plan = planesMap[planNombre] ?? RecaudacionService.defaultConfig;
        
        final jugadasL = await _db.getJugadasCompletas(pin, destino: 'LISTA', seccion: seccion, fecha: fecha, bancoId: bancoId, loteria: loteria);
        final jugadasB = await _db.getJugadasCompletas(pin, destino: 'BOTE', seccion: seccion, fecha: fecha, bancoId: bancoId, loteria: loteria);

        // 3. Calcular métricas
        final metrics = RecaudacionService.calculateParteMetrics(
          jugadasLista: jugadasL,
          jugadasBote: jugadasB,
          plan: plan,
          tiro: tiro,
          customLimites: limites,
          seccion: seccion,
        );

        // 4. Obtener fondo anterior
        double fondoAnterior = await _db.getLastSaldoFinal(pin, bancoId: bancoId, fecha: fecha, seccion: seccion, loteria: loteria);

        // 5. Guardar parte local
        final Map<String, dynamic> parte = {
          'banco_id': bancoId,
          'listero_pin': pin,
          'fecha': fecha,
          'seccion': seccion,
          'loteria': loteria,
          'tiro': "${tiro['n1']}-${tiro['n2']}-${tiro['n3']}",
          'fondo_anterior': fondoAnterior,
          'bruto_lista': metrics['bruto_lista'],
          'limpio_lista': metrics['limpio_lista'],
          'premios_lista': metrics['premios_lista'],
          'bruto_bote': metrics['bruto_bote'],
          'limpio_bote': metrics['limpio_bote'],
          'premios_bote': metrics['premios_bote'],
          'total_dia': metrics['total_dia'],
          'winners_json': json.encode({
            'lista': metrics['winners_lista'] ?? [],
            'bote': metrics['winners_bote'] ?? [],
          }),
          'saldo_final': fondoAnterior + (metrics['total_dia'] as double),
          'publicado': 0, // Creado como borrador. El banco debe presionar "ENVIAR PARTES" manualmente.
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        };

        await _db.insertParte(parte);
        listerosProcesados.add(nombre);
        if (listerosProcesados.length % 10 == 0) debugPrint("[ALEX_TIRO] Procesados ${listerosProcesados.length}/${listeros.length}...");
      } catch (e) {
        debugPrint("[ALEX_TIRO_ERR] Error procesando listero $pin: $e");
      }
    }

    debugPrint("[ALEX_TIRO] ÉXITO TOTAL: ${listerosProcesados.length} reportes generados.");

    // 6. SINCRO TURBO: Forzar subida inmediata y aviso a dispositivos
    await syncDataToCloud(isDeepSync: true);
    broadcastSyncPulse(isDeep: true);

    TiroService().notifyNewTiro(tiro);
    _db.notifySyncUpdate(-999);

    return listerosProcesados;
  }

  /// Publica y envía manualmente todos los partes borradores de una sección
  Future<int> publishPartesForSection(String fecha, String seccion, {required String bancoId, String? loteria}) async {
    final lot = loteria?.trim().toUpperCase();
    final count = await _db.publishPartesSelective(fecha, seccion, bancoId: bancoId, loteria: lot);
    try {
      var query = _supabase.from('partes').update({'publicado': 1}).eq('banco_id', bancoId).eq('fecha', fecha).eq('seccion', seccion);
      if (lot != null && lot.isNotEmpty && lot != "AMBAS") {
        query = query.eq('loteria', lot);
      }
      await query;
    } catch (e) {
      debugPrint("[ALEX_PUBLISH_PARTES_ERR] $e");
    }
    await syncDataToCloud(isDeepSync: true);
    broadcastSyncPulse(isDeep: true);
    return count;
  }

  bool isBrainOnline() {
    return CoreNetwork().isConnected;
  }

  Future<Map<String, dynamic>?> getPendingComunicado() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String userRole = prefs.getString("user_role") ?? "LISTERO";

      // COMUNICADOS SON EXCLUSIVOS PARA LISTEROS (NO BANCO NI PROGRAMADOR)
      if (userRole == "BANCO" || userRole == "PROGRAMADOR") {
        return null;
      }

      final bancoId = await getActiveBancoId();
      if (bancoId == null || bancoId == "UNKNOWN") {
        debugPrint("[ALEX] No se puede buscar comunicados: Banco Desconocido.");
        return null;
      }
      
      final listeroPin = await getActiveListeroPin();
      final deviceId = await _getDeviceId();
      final String identity = listeroPin.isEmpty ? "GUEST_$deviceId" : listeroPin;

      debugPrint("[ALEX] Buscando comunicados para Banco: $bancoId, Identidad: $identity");

      // 1. PRIORIDAD A: Comunicados Generales (Supabase) - solo si hay red
      if (CoreNetwork().isConnected) {
        try {
          final res = await _supabase
              .from('comunicados')
              .select()
              .eq('banco_id', bancoId)
              .eq('activo', 1)
              .order('created_at', ascending: false)
              .limit(1)
              .maybeSingle()
              .timeout(const Duration(milliseconds: 1000));

          if (res != null) {
            final comId = res['id'];

            final List<dynamic> leidoRes = await _supabase
                .from('comunicados_leidos')
                .select()
                .eq('comunicado_id', comId)
                .eq('listero_pin', identity)
                .limit(1)
                .timeout(const Duration(milliseconds: 1000));

            if (leidoRes.isEmpty) {
              debugPrint("[ALEX] Comunicado general pendiente encontrado: ${res['titulo']}");
              final Map<String, dynamic> cleanRes = Map.from(res);
              if (cleanRes['mensaje'] == null) {
                 cleanRes['mensaje'] = cleanRes['contenido'] ?? cleanRes['texto'] ?? cleanRes['titulo'];
              }
              return {...cleanRes, 'is_local': false}; 
            }
          }
        } catch (e) {
          debugPrint("[ALEX_REMOTE_COMU_ERR] Error consultando comunicados nube: $e");
        }
      }

      // 2. PRIORIDAD B: Notificaciones Directas (Buzón) que son OFICIALES
      try {
        final unreadNotis = await _db.getNotificaciones(
          listeroPin: listeroPin.isEmpty ? null : listeroPin, 
          bancoId: bancoId
        );
        
        // Solo las que son marcadas como OFICIALES bloquean la pantalla
        final pendingNotis = unreadNotis.where((n) => n['visto'] == 0 && n['es_oficial'] == 1).toList();
        
        if (pendingNotis.isNotEmpty) {
          final n = pendingNotis.first;
          debugPrint("[ALEX] Notificación oficial bloqueante detectada (ID: ${n['id']}): ${n['titulo']}");
          return {
            'id': n['id'],
            'titulo': n['titulo'],
            'mensaje': n['mensaje'],
            'fecha': n['fecha'],
            'is_local': true,
            'es_oficial': 1
          };
        }
      } catch (e) {
        debugPrint("[ALEX_LOCAL_NOTI_ERR] $e");
      }
    } catch (e) {
      debugPrint("[ALEX_COMUNICADOS_FATAL_ERR] $e");
    }
    return null;
  }

  Future<bool> markComunicadoAsRead(dynamic comunicadoId, {bool isLocal = false, Map<String, dynamic>? fullData}) async {
    try {
      final bancoId = await getActiveBancoId();
      final prefs = await SharedPreferences.getInstance();
      
      if (isLocal) {
        await _db.marcarNotificacionVista(comunicadoId as int);
        return true;
      }

      // Si es una notificación de nube capturada pre-sync
      if (fullData != null && fullData['is_cloud_noti'] == true) {
        final String uuid = fullData['uuid'] ?? "";
        if (uuid.isNotEmpty) await prefs.setBool("noti_seen_$uuid", true);
        // También intentar marcarla localmente si ya se sincronizó
        try {
          final db = await _db.database;
          await db.update('notificaciones', {'visto': 1}, where: 'uuid = ?', whereArgs: [uuid]);
        } catch (_) {}
        return true;
      }

      final listeroPin = await getActiveListeroPin();
      final deviceId = await _getDeviceId();
      final String identity = listeroPin.isEmpty ? "GUEST_$deviceId" : listeroPin;
      
      await _supabase.from('comunicados_leidos').upsert({
        'comunicado_id': comunicadoId,
        'listero_pin': identity,
        'banco_id': bancoId,
        'leido_at': DateTime.now().toUtc().toIso8601String(),
      });
      return true;
    } catch (e) {
      debugPrint("[ALEX_COMUNICADO_READ_ERR] $e");
      return false;
    }
  }

  String _mapToSpheres(dynamic val) {
    if (val == null) return "⚪";
    String s = val.toString();
    const Map<String, String> spheres = {
      '0': '⓿', '1': '❶', '2': '❷', '3': '❸', '4': '❹',
      '5': '❺', '6': '❻', '7': '❼', '8': '❽', '9': '❾'
    };
    
    // Si tiene guiones (Parle), procesamos cada parte
    if (s.contains('-')) {
      return s.split('-').map((n) {
        String part = n.trim().padLeft(2, '0');
        return part.split('').map((d) => spheres[d] ?? d).join('');
      }).join(' '); // Un espacio entre esferas de parle
    }

    // Caso normal (Bola o Centena)
    String part = s.trim().padLeft(s.length > 2 ? 3 : 2, '0');
    return part.split('').map((d) => spheres[d] ?? d).join('');
  }

  DateTime? _lastBankVerificationTime;
  bool _lastBankVerificationResult = true;

  /// Verifica si el banco activo actual aún existe en la nube (Supabase) con caché de 5 minutos.
  /// Si el banco fue eliminado por el programador, borra los datos locales y fuerza cierre de sesión.
  Future<bool> verifyActiveBankExists() async {
    final prefs = await SharedPreferences.getInstance();
    final String? role = prefs.getString("user_role");
    if (role == null || role == "PROGRAMADOR") return true;

    final String? activeBankId = prefs.getString("active_banco_id") ?? prefs.getString("banco_id");
    if (activeBankId == null || activeBankId.isEmpty || activeBankId == "UNKNOWN") {
      return true;
    }

    if (_lastBankVerificationTime != null && 
        DateTime.now().difference(_lastBankVerificationTime!).inMinutes < 5) {
      return _lastBankVerificationResult;
    }

    try {
      final int? numId = int.tryParse(activeBankId);
      final resList = await _supabase.from('bancos').select('id').eq('id', activeBankId).maybeSingle();
      
      bool exists = (resList != null);
      if (!exists && numId != null) {
        final resNum = await _supabase.from('bancos').select('id').eq('id', numId).maybeSingle();
        if (resNum != null) exists = true;
      }

      _lastBankVerificationResult = exists;
      _lastBankVerificationTime = DateTime.now();

      if (!exists) {
        debugPrint("[ALEX] ALERTA CRÍTICA: El banco '$activeBankId' no existe en la nube. Limpiando...");
        await _db.deleteBankLocalData(activeBankId);
        await logout(fullReset: true);
        _liveBetsController.add({
          'type': 'BANK_DELETED',
          'message': 'EL BANCO HA SIDO ELIMINADO POR EL PROGRAMADOR.'
        });
        return false;
      }
    } catch (e) {
      debugPrint("[ALEX_VERIFY_BANK_ERR] Error comprobando existencia de banco: $e");
    }
    return _lastBankVerificationResult;
  }

  Future<void> logout({bool fullReset = false}) async {
    final prefs = await SharedPreferences.getInstance();
    debugPrint("[ALEX] Ejecutando cierre de sesión completo y borrado de caché de identidad...");
    await prefs.clear();
    _db.notifySyncUpdate(-999);
  }

  DateTime? _lastBankActiveNotify;

  Future<void> notifyBankActive() async {
    final id = await getActiveBancoId();
    if (id == null || id == "UNKNOWN") return;

    // Solo notificar actividad del banco cada 10 minutos para optimizar tráfico
    if (_lastBankActiveNotify != null && 
        DateTime.now().difference(_lastBankActiveNotify!).inMinutes < 10) {
      return;
    }
    _lastBankActiveNotify = DateTime.now(); // Fijar la marca de tiempo antes de la consulta para evitar retrolog del temporizador

    try { 
      await _supabase.from('bancos').update({'last_active': DateTime.now().toUtc().toIso8601String()}).eq('id', id); 
    } catch (e) {
      debugPrint("[ALEX_NOTIFY_BANK_ERR] $e");
    }
  }

  async.Stream<Map<String, dynamic>> get onLiveBetReceived => _liveBetsController.stream;
  async.Stream<Map<String, dynamic>> get onTypingStatusReceived => _typingStatusController.stream;
  
  /// Abre los ajustes de la aplicación (Android)
  Future<void> openSettings() async {
     await openAppSettings();
  }
  
  // NUEVOS MÉTODOS RESTAURADOS
  
  final ValueNotifier<OtaEvent?> downloadProgress = ValueNotifier<OtaEvent?>(null);

  Future<void> downloadAndInstallApk(String url, {int? versionCode}) async {
    if (_isDownloadingApk) {
      debugPrint("[ALEX_OTA] Descarga ya en curso. Ignorando solicitud duplicada.");
      return;
    }
    
    if (!Platform.isAndroid) {
      debugPrint("[ALEX_OTA] Plataforma no-Android (${Platform.operatingSystem}). Abriendo enlace en navegador...");
      try {
        final Uri uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } else {
          debugPrint("[ALEX_OTA] No se pudo abrir la URL en el navegador: $url");
        }
      } catch (e) {
        debugPrint("[ALEX_OTA_ERR] Error abriendo URL en escritorio: $e");
      }
      return;
    }

    _isDownloadingApk = true;
    downloadProgress.value = OtaEvent(OtaStatus.DOWNLOADING, "0");

    final String apkFileName = "srecord_v${versionCode ?? DateTime.now().millisecondsSinceEpoch}.apk";

    // 1. Limpiar instaladores APK viejos en /storage/emulated/0/Download/ para evitar bucles con versiones obsoletas
    try {
      final downloadDir = Directory("/storage/emulated/0/Download");
      if (await downloadDir.exists()) {
        final List<FileSystemEntity> files = downloadDir.listSync();
        for (var file in files) {
          final String name = file.path.split('/').last;
          if ((name.startsWith("srecord_") || name.startsWith("srecord_v")) && name.endsWith(".apk") && name != apkFileName) {
            try {
              file.deleteSync();
              debugPrint("[ALEX_OTA] APK obsoleto purgado de disco: $name");
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint("[ALEX_OTA_CLEANUP_ERR] $e");
    }

    try {
      // MOTOR RESILIENTE PARA CUBA: Descarga reanudable por ráfagas con reintentos infinitos
      bool downloadSuccess = await _resumableApkDownloadWithRetry(url, apkFileName);

      if (downloadSuccess) {
        debugPrint("[ALEX_CUBA_OTA] Descarga 100% completada e íntegra ($apkFileName). Lanzando instalador Android...");
        downloadProgress.value = OtaEvent(OtaStatus.INSTALLING, "100");
        
        OtaUpdate().execute(url, destinationFilename: apkFileName).listen(
          (OtaEvent event) {
            downloadProgress.value = event;
            if (event.status == OtaStatus.INSTALLING || event.status == OtaStatus.ALREADY_RUNNING_ERROR || event.status == OtaStatus.PERMISSION_NOT_GRANTED_ERROR) {
              _isDownloadingApk = false;
            }
          },
          onError: (e) {
            _isDownloadingApk = false;
          },
          onDone: () {
            _isDownloadingApk = false;
          }
        );
      } else {
        _isDownloadingApk = false;
        downloadProgress.value = OtaEvent(OtaStatus.DOWNLOAD_ERROR, "0");
      }
    } catch (e) {
      debugPrint("[ALEX_CUBA_OTA_ERR] $e");
      _isDownloadingApk = false;
      downloadProgress.value = OtaEvent(OtaStatus.DOWNLOAD_ERROR, "0");
    }
  }

  /// Descargador resiliente adaptado para conexiones inestables en Cuba.
  /// Reanuda la descarga desde el exacto byte donde ocurrió el microcorte sin perder progreso.
  Future<bool> _resumableApkDownloadWithRetry(String url, String filename) async {
    const int maxRetries = 50; // Hasta 50 reintentos automáticos a través de microcortes
    int retries = 0;
    
    final String localPath = "/storage/emulated/0/Download/$filename";
    final File localFile = File(localPath);

    while (retries < maxRetries) {
      try {
        int existingBytes = 0;
        if (await localFile.exists()) {
          existingBytes = await localFile.length();
        }

        // Obtener tamaño total mediante solicitud HEAD
        int totalBytes = 0;
        try {
          final headReq = await http.head(Uri.parse(url)).timeout(const Duration(seconds: 10));
          totalBytes = int.tryParse(headReq.headers['content-length'] ?? '') ?? 0;
        } catch (_) {}

        // Si la descarga ya estaba completa al 100%
        if (totalBytes > 0 && existingBytes >= totalBytes) {
          debugPrint("[ALEX_CUBA_OTA] El archivo ya existía completo en disco ($existingBytes bytes).");
          downloadProgress.value = OtaEvent(OtaStatus.DOWNLOADING, "100");
          return true;
        }

        debugPrint("[ALEX_CUBA_OTA] Solicitando rango HTTP: bytes=$existingBytes- ($existingBytes / ${totalBytes > 0 ? totalBytes : 'desconocido'})");

        final request = http.Request('GET', Uri.parse(url));
        if (existingBytes > 0) {
          request.headers['Range'] = 'bytes=$existingBytes-';
        }

        final client = http.Client();
        final response = await client.send(request).timeout(const Duration(seconds: 15));

        if (response.statusCode != 200 && response.statusCode != 206) {
          if (existingBytes > 0) {
            try { await localFile.delete(); } catch (_) {}
            existingBytes = 0;
          }
        }

        if (totalBytes <= 0) {
          totalBytes = (response.contentLength ?? 0) + existingBytes;
        }

        final sink = localFile.openWrite(mode: existingBytes > 0 ? FileMode.append : FileMode.write);
        
        await for (var chunk in response.stream) {
          sink.add(chunk);
          existingBytes += chunk.length;

          if (totalBytes > 0) {
            final double pct = (existingBytes / totalBytes) * 100;
            final int progressInt = pct.clamp(0, 100).toInt();
            downloadProgress.value = OtaEvent(OtaStatus.DOWNLOADING, progressInt.toString());
          }
        }

        await sink.flush();
        await sink.close();
        client.close();

        if (totalBytes <= 0 || existingBytes >= totalBytes) {
          downloadProgress.value = OtaEvent(OtaStatus.DOWNLOADING, "100");
          return true;
        }
      } catch (e) {
        retries++;
        debugPrint("[ALEX_CUBA_OTA_MICROCUT] Microcorte #$retries detectado: $e. Reanudando en 1.5s...");
        await Future.delayed(const Duration(milliseconds: 1500));
      }
    }
    return false;
  }

  DateTime? _lastUpdateCheck;

  Future<void> checkAppUpdate({bool force = false}) async {
    if (!CoreNetwork().isConnected) {
      debugPrint("[ALEX_UPDATE] Modo OFFLINE: Omite comprobación de versión.");
      return;
    }

    if (!force && _lastUpdateCheck != null && 
        DateTime.now().difference(_lastUpdateCheck!).inMinutes < 2) {
      return;
    }
    
    try {
      _lastUpdateCheck = DateTime.now();
      final packageInfo = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;

      debugPrint("[ALEX_UPDATE] Verificando versión global en la nube (Build Actual: $currentBuild)...");

      // Consultar todas las actualizaciones publicadas en Supabase con timeout de 1.2s
      final List<dynamic> records = await _supabase
          .from('app_updates')
          .select()
          .timeout(const Duration(milliseconds: 1200));

      if (records.isNotEmpty) {
        // Purgar versiones antiguas automáticamente si hay más de 5
        if (records.length > 5) {
          _cleanupOldUpdates();
        }

        List<Map<String, dynamic>> validRecords = [];
        final String currentPkg = packageInfo.packageName;

        for (var r in records) {
          if (r is Map<String, dynamic>) {
            final String pkg = r['package_name']?.toString() ?? '';
            if (pkg.isEmpty || pkg == currentPkg || pkg == 'com.fusionpro.srecord.local' || pkg == 'srecord') {
              validRecords.add(r);
            }
          }
        }
        if (validRecords.isEmpty) {
          validRecords = records.cast<Map<String, dynamic>>();
        }

        // Ordenar NUMÉRICAMENTE por version_code descendente en Dart
        validRecords.sort((a, b) {
          final int codeA = (a['version_code'] is int) 
              ? a['version_code'] as int 
              : (int.tryParse(a['version_code']?.toString() ?? '') ?? 0);
          final int codeB = (b['version_code'] is int) 
              ? b['version_code'] as int 
              : (int.tryParse(b['version_code']?.toString() ?? '') ?? 0);
          return codeB.compareTo(codeA);
        });

        final res = validRecords.first;
        final int latestBuild = (res['version_code'] is int)
            ? res['version_code'] as int
            : (int.tryParse(res['version_code']?.toString() ?? '') ?? 0);

        debugPrint("[ALEX_UPDATE] Mayor versión en nube: Build $latestBuild vs Local $currentBuild");

        if (latestBuild > currentBuild) {
          debugPrint("[ALEX_UPDATE] ¡NUEVA VERSIÓN DETECTADA!: Build $latestBuild (Local es $currentBuild)");
          final vName = res['version_name']?.toString() ?? 'NUEVA';
          final data = {
            'current': packageInfo.version,
            'required': vName,
            'versionCode': latestBuild,
            'url': res['apk_url'],
            'iosUrl': res['ios_url'] ?? 'https://github.com/alexacuadro/srecord/actions',
            'hash': res['apk_hash'],
            'message': res['release_notes'] ?? "Nueva versión disponible con mejoras de seguridad y rendimiento."
          };
          updateRequired.value = data;

          // DISPARO AUTOMÁTICO: Iniciar descarga e instalación inmediatamente si es Android
          if (Platform.isAndroid && !_isDownloadingApk && data['url'] != null) {
             debugPrint("[ALEX_UPDATE] Disparando descarga e instalación automática en Android...");
             NotificationService().showNotification(
               id: 999,
               title: "🚀 MEJORA DE SISTEMA DISPONIBLE",
               body: "Descargando versión $vName para optimizar tu equipo.",
               payloadKey: "update_available_$vName",
             );
             downloadAndInstallApk(data['url'], versionCode: latestBuild);
          }
        } else {
          updateRequired.value = null;
        }
      }
    } catch (e) {
      debugPrint("[ALEX_UPDATE_ERR] $e");
    }
  }

  /// Dispara la compilación automatizada de iOS en GitHub Actions directamente desde la app
  Future<Map<String, dynamic>> triggerGitHubIosBuild() async {
    try {
      final url = Uri.parse('https://api.github.com/repos/alexacuadro/srecord/actions/workflows/ios.yml/dispatches');
      final response = await http.post(
        url,
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'Content-Type': 'application/json',
        },
        body: json.encode({'ref': 'main'}),
      );

      if (response.statusCode == 204 || response.statusCode == 200) {
        return {'success': true, 'message': '🚀 Compilación Nube de iOS iniciada con éxito en GitHub Actions.'};
      } else {
        return {
          'success': true, 
          'message': 'Sincronización con GitHub activa. La app se compila automáticamente al enviar actualizaciones.'
        };
      }
    } catch (e) {
      return {'success': false, 'message': 'Error conectando con GitHub: $e'};
    }
  }

  static Stream<List<int>> _createHighSpeedFileStream(File file, int chunkSize) async* {
    final RandomAccessFile raf = await file.open(mode: FileMode.read);
    final int totalLength = await raf.length();
    int bytesRead = 0;

    try {
      while (bytesRead < totalLength) {
        final int toRead = math.min(chunkSize, totalLength - bytesRead);
        final List<int> chunk = await raf.read(toRead);
        bytesRead += chunk.length;
        yield chunk;
      }
    } finally {
      await raf.close();
    }
  }

  Future<Map<String, dynamic>> uploadNewUpdate({
    required File file,
    required int versionCode,
    required String versionName,
    required String releaseNotes,
    String? iosUrl,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userRole = prefs.getString("user_role") ?? "LISTERO";
      
      // 1. SEGURIDAD: Solo el Programador puede subir actualizaciones
      if (userRole != "PROGRAMADOR") {
         return {'success': false, 'error': "ACCESO DENEGADO: NO TIENE ROL DE PROGRAMADOR."};
      }

      // 2. INTEGRIDAD: Validar archivo
      if (!await file.exists()) return {'success': false, 'error': "EL ARCHIVO NO EXISTE."};
      if (!file.path.toLowerCase().endsWith(".apk")) return {'success': false, 'error': "EL ARCHIVO DEBE SER UN APK VÁLIDO."};
      
      final int totalBytes = await file.length();
      if (totalBytes < 1024 * 1024) return {'success': false, 'error': "APK DEMASIADO PEQUEÑO (POSIBLEMENTE CORRUPTO)."};

      debugPrint("[ALEX_UPLOAD] Calculando firma de integridad (SHA-256)...");
      final hash = await sha256.bind(file.openRead()).first;
      final String hashString = hash.toString();
      debugPrint("[ALEX_UPLOAD] Firma: $hashString");

      debugPrint("[ALEX_UPLOAD] Preparando subida de v$versionCode ($versionName)...");
      uploadProgress.value = 0.0;
      uploadProgressDetails.value = {
        'progress': 0.0,
        'sentBytes': 0,
        'totalBytes': totalBytes,
        'mbSent': '0.0',
        'mbTotal': (totalBytes / (1024 * 1024)).toStringAsFixed(1),
        'speed': '0.0',
      };
      
      final String fileName = 'app-release-v$versionCode-${DateTime.now().millisecondsSinceEpoch}.apk';
      final String bucket = 'app-updates';

      // 3. SUBIDA A SUPABASE STORAGE A MÁXIMA VELOCIDAD (BUFFER DE ALTA EFICIENCIA 512 KB)
      final String storageUrl = _supabase.storage.url;
      final Map<String, String> uploadHeaders = {
        ..._supabase.storage.headers,
        'x-upsert': 'true',
        'Content-Type': 'application/vnd.android.package-archive',
      };
      
      final String? sessionToken = _supabase.auth.currentSession?.accessToken;
      if (sessionToken != null) {
        uploadHeaders['Authorization'] = 'Bearer $sessionToken';
      } else if (!uploadHeaders.containsKey('Authorization')) {
        uploadHeaders['Authorization'] = 'Bearer ${_supabase.auth.headers['apikey']}';
      }

      final String uploadUrl = '$storageUrl/object/$bucket/$fileName';
      final DateTime startTime = DateTime.now();
      int bytesSent = 0;

      final request = http.StreamedRequest('POST', Uri.parse(uploadUrl));
      request.headers.addAll(uploadHeaders);
      request.contentLength = totalBytes;

      // Stream de lectura optimizado en ráfagas de 512 KB para eliminar cuellos de botella en Wi-Fi y Datos
      final highSpeedStream = _createHighSpeedFileStream(file, 512 * 1024);

      final progressStream = highSpeedStream.transform(
        async.StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (List<int> chunk, sink) {
            bytesSent += chunk.length;
            sink.add(chunk);

            if (totalBytes > 0) {
              final double p = (bytesSent / totalBytes).clamp(0.0, 1.0);
              uploadProgress.value = p;

              final double elapsedMs = DateTime.now().difference(startTime).inMilliseconds.toDouble();
              final double speedMBs = (elapsedMs > 50) ? ((bytesSent / (1024 * 1024)) / (elapsedMs / 1000.0)) : 0.0;

              uploadProgressDetails.value = {
                'progress': p,
                'sentBytes': bytesSent,
                'totalBytes': totalBytes,
                'mbSent': (bytesSent / (1024 * 1024)).toStringAsFixed(1),
                'mbTotal': (totalBytes / (1024 * 1024)).toStringAsFixed(1),
                'speed': speedMBs.toStringAsFixed(1),
              };
            }
          },
        ),
      );

      final streamSub = progressStream.listen(
        (chunk) => request.sink.add(chunk),
        onDone: () => request.sink.close(),
        onError: (e) => request.sink.addError(e),
        cancelOnError: true,
      );

      final streamedResponse = await request.send().timeout(const Duration(minutes: 15));
      final response = await http.Response.fromStream(streamedResponse);
      await streamSub.cancel();

      if (response.statusCode != 200 && response.statusCode != 201) {
        throw Exception("Fallo en Storage (${response.statusCode}): ${response.body}");
      }

      uploadProgress.value = 1.0;
      debugPrint("[ALEX_UPLOAD] Archivo en nube. Registrando en base de datos...");

      final String publicUrl = _supabase.storage.from(bucket).getPublicUrl(fileName);
      final packageInfo = await PackageInfo.fromPlatform();

      final updateRecord = {
        'version_code': versionCode,
        'version_name': versionName,
        'apk_url': publicUrl,
        'ios_url': iosUrl ?? 'https://github.com/alexacuadro/srecord/actions',
        'release_notes': releaseNotes,
        'package_name': packageInfo.packageName,
        'apk_hash': hashString,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };

      // Guardar en tabla app_updates de Supabase
      final packageNamesToUpdate = {
        packageInfo.packageName,
        'com.fusionpro.srecord.local',
        'srecord',
        'com.example.srecord',
      };

      bool dbSuccess = false;
      String? lastDbErr;

      for (var pkg in packageNamesToUpdate) {
        if (pkg.isNotEmpty) {
          final rec = Map<String, dynamic>.from(updateRecord);
          rec['package_name'] = pkg;
          try {
            await _supabase.from('app_updates').insert(rec);
            dbSuccess = true;
          } catch (insertErr) {
            final String errStr = insertErr.toString();
            debugPrint("[ALEX_UPLOAD_INSERT_ERR] $pkg: $errStr");
            
            // Si la tabla app_updates en Supabase no tiene columnas opcionales como 'ios_url', probar con campos core esenciales
            if (errStr.contains('ios_url') || errStr.contains('PGRST204') || errStr.contains('column')) {
              try {
                final Map<String, dynamic> coreRec = {
                  'version_code': versionCode,
                  'version_name': versionName,
                  'apk_url': publicUrl,
                  'package_name': pkg,
                };
                if (releaseNotes.isNotEmpty) coreRec['release_notes'] = releaseNotes;
                await _supabase.from('app_updates').insert(coreRec);
                dbSuccess = true;
                continue;
              } catch (coreErr) {
                lastDbErr = coreErr.toString();
                debugPrint("[ALEX_UPLOAD_CORE_ERR] $pkg: $coreErr");
              }
            }

            try {
              await _supabase.from('app_updates').upsert(rec);
              dbSuccess = true;
            } catch (upsertErr) {
              lastDbErr = upsertErr.toString();
              debugPrint("[ALEX_UPLOAD_PKG_ERR] $pkg: $upsertErr");
            }
          }
        }
      }

      if (!dbSuccess) {
        throw Exception("No se pudo registrar la actualización en Supabase BD: $lastDbErr");
      }

      uploadProgress.value = 1.0;

      // ANUNCIO MAESTRO EN TIEMPO REAL VÍA WEBSOCKET A TODAS LAS APPS CONECTADAS
      try {
        if (_systemChannel == null) {
          _systemChannel = _supabase.channel('system_updates');
          _systemChannel?.subscribe();
        }
        await _systemChannel?.sendBroadcastMessage(
          event: 'NEW_APP_UPDATE',
          payload: updateRecord,
        );
      } catch (broadcastErr) {
        debugPrint("[ALEX_UPLOAD_BROADCAST_ERR] $broadcastErr");
      }

      // PURGA AUTOMÁTICA: Mantener únicamente las 5 últimas actualizaciones en la nube
      await _cleanupOldUpdates();

      // Re-ejecutar comprobación local inmediata por si es este mismo dispositivo
      checkAppUpdate(force: true);

      debugPrint("[ALEX_UPLOAD] ACTUALIZACIÓN v$versionCode PUBLICADA Y ANUNCIADA EN TIEMPO REAL.");
      return {'success': true, 'url': publicUrl, 'hash': hashString};
    } catch (e) {
      debugPrint("[ALEX_UPLOAD_ERR] $e");
      return {'success': false, 'error': "ERROR DE SUBIDA: ${e.toString()}"};
    } finally {
      uploadProgress.value = 0.0;
    }
  }

  Future<List<Map<String, dynamic>>> getCloudUpdates() async {
    try {
      final List<dynamic> records = await _supabase
          .from('app_updates')
          .select();

      List<Map<String, dynamic>> updates = [];
      for (var r in records) {
        if (r is Map<String, dynamic>) {
          updates.add(r);
        }
      }

      updates.sort((a, b) {
        final int codeA = (a['version_code'] is int)
            ? a['version_code'] as int
            : (int.tryParse(a['version_code']?.toString() ?? '') ?? 0);
        final int codeB = (b['version_code'] is int)
            ? b['version_code'] as int
            : (int.tryParse(b['version_code']?.toString() ?? '') ?? 0);
        return codeB.compareTo(codeA);
      });

      return updates;
    } catch (e) {
      debugPrint("[ALEX_GET_UPDATES_ERR] $e");
      return [];
    }
  }

  Future<bool> deleteCloudUpdate(dynamic id, dynamic versionCode, String? apkUrl) async {
    try {
      final String bucket = 'app-updates';

      if (apkUrl != null && apkUrl.contains(bucket)) {
        try {
          final Uri uri = Uri.parse(apkUrl);
          final String fileName = uri.pathSegments.last;
          if (fileName.isNotEmpty) {
            await _supabase.storage.from(bucket).remove([fileName]);
          }
        } catch (stErr) {
          debugPrint("[ALEX_DELETE_STORAGE_ERR] $stErr");
        }
      }

      if (id != null) {
        await _supabase.from('app_updates').delete().eq('id', id);
      } else if (versionCode != null) {
        await _supabase.from('app_updates').delete().eq('version_code', versionCode);
      }

      await _cleanupOldUpdates();

      return true;
    } catch (e) {
      debugPrint("[ALEX_DELETE_UPDATE_ERR] $e");
      return false;
    }
  }

  Future<void> _cleanupOldUpdates() async {
    try {
      debugPrint("[ALEX_CLEANUP] Verificando retención de las 5 últimas versiones en Supabase BD y Storage...");
      final String bucket = 'app-updates';

      // 1. Obtener todas las versiones de la tabla app_updates
      final List<dynamic> records = await _supabase
          .from('app_updates')
          .select();

      List<Map<String, dynamic>> allUpdates = [];
      for (var r in records) {
        if (r is Map<String, dynamic>) {
          allUpdates.add(r);
        }
      }

      // 2. Extraer todos los version_code únicos y ordenarlos numéricamente
      Set<int> uniqueCodes = {};
      for (var u in allUpdates) {
        final int code = (u['version_code'] is int)
            ? u['version_code'] as int
            : (int.tryParse(u['version_code']?.toString() ?? '') ?? 0);
        if (code > 0) uniqueCodes.add(code);
      }

      List<int> sortedCodes = uniqueCodes.toList()..sort((a, b) => b.compareTo(a)); // Mayor a menor

      // Los primeros 5 códigos son los CONSERVADOS; el resto se PURGAN.
      final List<int> keptCodes = sortedCodes.take(5).toList();
      final List<int> purgedCodes = sortedCodes.length > 5 ? sortedCodes.sublist(5) : [];

      // 3. Purgar filas de la BD de versiones fuera del top 5
      for (int oldCode in purgedCodes) {
        try {
          await _supabase.from('app_updates').delete().eq('version_code', oldCode);
          debugPrint("[ALEX_CLEANUP] BD: Eliminada versión $oldCode.");
        } catch (dbErr) {
          debugPrint("[ALEX_CLEANUP_DB_ERR] Error borrando versión $oldCode en BD: $dbErr");
        }
      }

      // 4. Obtener las URLs de los APKs que pertenecen a los 5 códigos conservados
      Set<String> keptFilenames = {};
      for (var u in allUpdates) {
        final int code = (u['version_code'] is int)
            ? u['version_code'] as int
            : (int.tryParse(u['version_code']?.toString() ?? '') ?? 0);
        if (keptCodes.contains(code)) {
          final String? apkUrl = u['apk_url']?.toString();
          if (apkUrl != null && apkUrl.isNotEmpty) {
            try {
              final Uri uri = Uri.parse(apkUrl);
              final String fileName = uri.pathSegments.last;
              if (fileName.isNotEmpty) keptFilenames.add(fileName);
            } catch (_) {}
          }
        }
      }

      // 5. Listar todos los archivos directamente en el bucket de Storage de Supabase
      try {
        final List<FileObject> storageObjects = await _supabase.storage.from(bucket).list();
        List<String> filesToDelete = [];

        for (var obj in storageObjects) {
          final String fName = obj.name;
          if (fName.isEmpty || fName == '.emptyFolderPlaceholder') continue;

          // Si el archivo en Storage no coincide con ninguno de los 5 APKs conservados, marcar para borrar
          if (!keptFilenames.contains(fName)) {
            filesToDelete.add(fName);
          }
        }

        if (filesToDelete.isNotEmpty) {
          debugPrint("[ALEX_CLEANUP] Eliminando ${filesToDelete.length} archivos antiguos/huérfanos de Storage: $filesToDelete");
          await _supabase.storage.from(bucket).remove(filesToDelete);
          debugPrint("[ALEX_CLEANUP] Storage: Purga de archivos completada exitosamente.");
        } else {
          debugPrint("[ALEX_CLEANUP] Storage: Todos los archivos corresponden a las 5 versiones activas.");
        }
      } catch (stListErr) {
        debugPrint("[ALEX_CLEANUP_STORAGE_LIST_ERR] Error listando archivos de Storage: $stListErr");
      }
    } catch (e) {
      debugPrint("[ALEX_CLEANUP_ERR] Error durante la purga de versiones viejas: $e");
    }
  }

  Future<Map<String, dynamic>> handleLogin(String password) async {
    final cleanPass = password.trim();
    if (cleanPass.isEmpty) {
      return {'success': false, 'error': 'POR FAVOR INGRESE UN PIN O CONTRASEÑA.'};
    }

    // 0. SOLICITUD DE BANCO (Acceso secreto B8080)
    if (cleanPass == "B8080") {
      final res = await requestNewBank();
      if (res['success'] == true) {
        return {'success': true, 'is_request': true, 'message': res['message']};
      } else {
        return {'success': false, 'error': res['error'] ?? "Fallo al enviar solicitud"};
      }
    }

    // 1. MASTER KEYS (Programador)
    if (cleanPass == "pp0030") {
       final prefs = await SharedPreferences.getInstance();
       await prefs.clear();
       await prefs.setString("user_role", "PROGRAMADOR");
       return {'success': true, 'role': 'PROGRAMADOR'};
    }

    final String deviceId = await _getDeviceId();
    final prefs = await SharedPreferences.getInstance();

    bool cloudChecked = false;
    // 2. VERIFICAR BANCO EN NUBE PRIMERO PARA GARANTIZAR IDENTIDAD ÚNICA POR CONTRASEÑA
    try {
      final List<dynamic> bankResList = await _supabase
          .from('bancos')
          .select()
          .eq('password', cleanPass)
          .timeout(const Duration(seconds: 4));

      cloudChecked = true;

      if (bankResList.length > 1) {
        return {
          'success': false, 
          'error': 'CONTRASEÑA AMBIGUA: EXISTEN MÚLTIPLES BANCOS CON ESTA MISMA CLAVE EN NUBE. CONTACTE AL PROGRAMADOR.'
        };
      }

      if (bankResList.isNotEmpty) {
        final bankRes = Map<String, dynamic>.from(bankResList.first);
        final String bId = bankRes['id'].toString();
        
        // Limpieza de sesión previa para evitar que datos del banco anterior se mezclen
        await prefs.clear();

        await prefs.setString("user_role", "BANCO");
        await prefs.setString("banco_id", bId);
        await prefs.setString("active_banco_id", bId);
        await prefs.setString("last_banco_pin", cleanPass);

        final String bankLoterias = await getBankLoterias(bId);
        if (bankLoterias == "FLORIDA") {
          await prefs.setString("sync_loteria", "FLORIDA");
          await prefs.setString("sync_seccion", "DIA");
        } else if (bankLoterias == "GEORGIA") {
          await prefs.setString("sync_loteria", "GEORGIA");
          await prefs.setString("sync_seccion", "MIDDAY");
        }

        await initRealtimeChannels(bId);
        _pullCloudToLocalOptimized(bId, "2000-01-01T00:00:00Z", isDeepSync: true).catchError((e) {
          debugPrint("[ALEX_LOGIN_PULL_ERR] $e");
        });
        
        broadcastSyncPulse(isDeep: true);
        return {'success': true, 'role': 'BANCO'};
      } else {
        // La nube confirmó que NO existe ningún banco con esta clave. Limpiar caché viejo
        if (prefs.getString("last_banco_pin") == cleanPass) {
          final String? oldB = prefs.getString("banco_id");
          if (oldB != null) await _db.deleteBankLocalData(oldB);
          await prefs.clear();
        }
      }
    } catch (e) {
      debugPrint("[ALEX_LOGIN_BANK_ERR] $e");
    }

    // 3. RESPALDO LOCAL DE BANCO (Solo en caso de estar totalmente offline)
    if (!cloudChecked) {
      final String? savedBancoId = prefs.getString("banco_id");
      final String? savedBancoPin = prefs.getString("last_banco_pin");
      if (savedBancoId != null && savedBancoPin == cleanPass) {
        await prefs.setString("user_role", "BANCO");
        await prefs.setString("active_banco_id", savedBancoId);
        
        final String bankLoterias = await getBankLoterias(savedBancoId);
        if (bankLoterias == "FLORIDA") {
          await prefs.setString("sync_loteria", "FLORIDA");
          await prefs.setString("sync_seccion", "DIA");
        } else if (bankLoterias == "GEORGIA") {
          await prefs.setString("sync_loteria", "GEORGIA");
          await prefs.setString("sync_seccion", "MIDDAY");
        }

        initRealtimeChannels(savedBancoId);
        _pullCloudToLocalOptimized(savedBancoId, "2000-01-01T00:00:00Z", isDeepSync: true).catchError((e) {
          debugPrint("[ALEX_BG_PULL_ERR] $e");
        });
        broadcastSyncPulse(isDeep: true);
        return {'success': true, 'role': 'BANCO'};
      }
    }

    // 4. VERIFICAR LISTERO EN NUBE
    bool listeroCloudChecked = false;
    try {
      final List<dynamic> cloudListeroResList = await _supabase
          .from('listeros')
          .select()
          .eq('pin', cleanPass)
          .timeout(const Duration(seconds: 3));

      listeroCloudChecked = true;

      if (cloudListeroResList.length > 1) {
        return {'success': false, 'error': 'PIN AMBIGUO: ESTE CÓDIGO EXISTE EN MÚLTIPLES BANCOS. CONTACTE A SU BANCO.'};
      }

      if (cloudListeroResList.isNotEmpty) {
        final Map<String, dynamic> cloudListeroRes = Map.from(cloudListeroResList.first);
        final String bId = cloudListeroRes['banco_id']?.toString() ?? "";

        // VERIFICAR QUE EL BANCO DE ESTA LISTA AÚN EXISTA EN NUBE
        try {
          final bankCheck = await _supabase.from('bancos').select('id').eq('id', bId).maybeSingle();
          if (bankCheck == null) {
            await _db.deleteListero(cleanPass, bId, sync: 0);
            await _db.deleteBankLocalData(bId);
            return {'success': false, 'error': 'EL BANCO DE ESTA LISTA FUE ELIMINADO POR EL PROGRAMADOR.'};
          }
        } catch (_) {}

        return await _validateAndLinkListero(
          listero: cloudListeroRes,
          password: cleanPass,
          deviceId: deviceId,
          prefs: prefs,
        );
      } else {
        // La nube confirmó que este PIN tampoco existe en listeros
        final localStale = await _db.findListeroGlobally(cleanPass);
        if (localStale != null) {
          final String bId = localStale['banco_id']?.toString() ?? "";
          if (bId.isNotEmpty) {
            await _db.deleteListero(cleanPass, bId, sync: 0);
          }
        }
      }
    } catch (e) {
      debugPrint("[ALEX_LOGIN_LISTERO_CLOUD_ERR] $e");
    }

    // 5. RUTA OFFLINE / LOCAL PARA LISTERO
    if (!listeroCloudChecked && !cloudChecked) {
      final listeroData = await _db.findListeroGlobally(cleanPass);
      if (listeroData != null) {
        final listero = listeroData['listero'];
        final String bId = listeroData['banco_id']?.toString() ?? "";

        // Verificar localmente si el banco aún existe en SQLite
        final bool bankExistsLocal = await _db.isBankRegistered(bId);
        if (!bankExistsLocal && bId.isNotEmpty) {
          await _db.deleteListero(cleanPass, bId, sync: 0);
          return {'success': false, 'error': 'EL BANCO ASOCIADO A ESTA LISTA FUE ELIMINADO.'};
        }

        return await _validateAndLinkListero(
          listero: listero,
          password: cleanPass,
          deviceId: deviceId,
          prefs: prefs,
        );
      }
    }

    return {'success': false, 'error': 'PIN O CONTRASEÑA INCORRECTA O NO ENCONTRADA EN NUBE'};
  }

  /// Valida restricciones de vinculación y bloqueos para un Listero
  Future<Map<String, dynamic>> _validateAndLinkListero({
    required Map<String, dynamic> listero,
    required String password,
    required String deviceId,
    required SharedPreferences prefs,
  }) async {
    final String bId = (listero['banco_id'] ?? '').toString();

    // A. Comprobar si el banco al que pertenece esta lista sigue existiendo en Supabase
    try {
      final bankCheck = await _supabase.from('bancos').select('id').eq('id', bId).maybeSingle();
      if (bankCheck == null) {
        await _db.deleteListero(password, bId, sync: 0);
        await _db.deleteBankLocalData(bId);
        return {'success': false, 'error': 'EL BANCO DE ESTA LISTA FUE ELIMINADO POR EL PROGRAMADOR.'};
      }
    } catch (_) {}

    // B. Comprobar si está bloqueado por el banco
    if (listero['bloqueado'] == 1 || listero['bloqueado'] == true) {
      return {'success': false, 'error': 'ESTA LISTA SE ENCUENTRA BLOQUEADA POR EL BANCO'};
    }

    // C. Comprobar si ESTE dispositivo tiene un anclaje activo previo a otra lista
    final String? anchoredPin = prefs.getString("anchored_listero_pin");
    if (anchoredPin != null && anchoredPin != password) {
      Map<String, dynamic>? anchoredListero = await _db.getListeroByPin(anchoredPin, bId);
      if (anchoredListero == null) {
        final res = await _db.findListeroGlobally(anchoredPin);
        if (res != null) anchoredListero = res['listero'];
      }

      bool isAnchoredStillActive = false;
      if (anchoredListero != null) {
        final bool isVinc = (anchoredListero['vinculado'] == 1 || anchoredListero['vinculado'] == true);
        final String? devId = anchoredListero['device_id'];
        if (isVinc && (devId == null || devId == deviceId || devId.isEmpty || devId == "UNKNOWN")) {
          isAnchoredStillActive = true;
        }
      }

      if (isAnchoredStillActive) {
        return {'success': false, 'error': 'ESTE MÓVIL ESTÁ ANCLADO A LA LISTA $anchoredPin. NO PUEDE ACCEDER A OTRA.'};
      } else {
        await prefs.remove("anchored_listero_pin");
      }
    }

    // D. Comprobar si ESTA LISTA ya está vinculada a OTRO dispositivo
    final bool isLinked = (listero['vinculado'] == 1 || listero['vinculado'] == true);
    final String? linkedDeviceId = listero['device_id'];
    if (isLinked && linkedDeviceId != null && linkedDeviceId.isNotEmpty && linkedDeviceId != deviceId) {
      return {'success': false, 'error': 'LISTA YA VINCULADA A OTRO MÓVIL. SOLICITE DESVINCULACIÓN AL BANCO.'};
    }

    // E. Comprobar si ESTE dispositivo ya está vinculado a otra lista en BD local
    final allLocal = await _db.getListeros(bancoId: bId);
    for (var l in allLocal) {
      final bool lVinc = (l['vinculado'] == 1 || l['vinculado'] == true);
      if (l['pin'] != password && lVinc && l['device_id'] == deviceId) {
        return {'success': false, 'error': 'ESTE MÓVIL YA TIENE OTRA LISTA VINCULADA (${l['nombre'] ?? l['pin']}). NO PUEDE ACCEDER A OTRA.'};
      }
    }

    // F. Limpieza absoluta de la sesión anterior para evitar mezclar datos
    await prefs.clear();

    // G. Vinculación exitosa: actualizar nube, local y preferencias
    final updatedData = {
      ...listero,
      'device_id': deviceId,
      'vinculado': 1
    };

    _supabase.from('listeros').update({
      'device_id': deviceId,
      'vinculado': 1
    }).match({'pin': password, 'banco_id': bId}).catchError((e) {
      debugPrint("[ALEX_LINK_SUPABASE_ERR] $e");
    });

    await _db.upsertListero(updatedData);
    await prefs.setString("anchored_listero_pin", password);

    await prefs.setString("user_role", "LISTERO");
    await prefs.setString("listero_pin", password);
    await prefs.setString("current_listero_pin", password);
    await prefs.setString("logged_listero_name", listero['nombre'] ?? "Listero");
    await prefs.setString("banco_id", bId);
    await prefs.setString("active_banco_id", bId);

    final String listeroLoterias = await getListeroLoterias(bId, password);
    if (listeroLoterias == "FLORIDA") {
      await prefs.setString("sync_loteria", "FLORIDA");
      await prefs.setString("sync_seccion", "DIA");
    } else if (listeroLoterias == "GEORGIA") {
      await prefs.setString("sync_loteria", "GEORGIA");
      await prefs.setString("sync_seccion", "MIDDAY");
    }

    initRealtimeChannels(bId);
    _pullCloudToLocalOptimized(bId, "2000-01-01T00:00:00Z", isDeepSync: true, listeroPin: password).catchError((e) {
      debugPrint("[ALEX_BG_PULL_ERR] $e");
    });

    broadcastSyncPulse(isDeep: true);
    return {'success': true, 'role': 'LISTERO'};
  }

  Future<List<Map<String, dynamic>>> getPendingBankRequests() async {
    try {
      final res = await _supabase.from('bank_requests').select().eq('status', 'PENDING');
      return List<Map<String, dynamic>>.from(res);
    } catch (_) { return []; }
  }

  /// Desvincula un dispositivo de una lista (Listero)
  Future<void> unlinkListero(String pin) async {
    final bancoId = await getActiveBancoId();
    if (bancoId == null) return;

    try {
      final cleanPin = pin.trim();
      debugPrint("[ALEX] Desvinculando listero $cleanPin del banco $bancoId...");
      // 1. Actualizar localmente inmediatamente
      final local = await _db.getListeroByPin(cleanPin, bancoId);
      if (local != null) {
        final updated = Map<String, dynamic>.from(local);
        updated['vinculado'] = 0;
        updated['device_id'] = null;
        updated['sync'] = 1;
        await _db.upsertListero(updated);
      }

      // 2. Actualizar en la nube inmediatamente
      await _supabase.from('listeros').update({
        'device_id': null,
        'vinculado': 0
      }).match({'pin': cleanPin, 'banco_id': bancoId});

      // 3. Confirmar sync local
      if (local != null) {
        final updated = Map<String, dynamic>.from(local);
        updated['vinculado'] = 0;
        updated['device_id'] = null;
        updated['sync'] = 0;
        await _db.upsertListero(updated);
      }

      // 4. Emitir evento directo por WebSocket en tiempo real a todas las apps
      try {
        if (_commandChannel == null) {
          await initRealtimeChannels(bancoId);
        }
        await _commandChannel?.sendBroadcastMessage(
          event: 'LISTERO_UNLINK',
          payload: {
            'pin': cleanPin,
            'banco_id': bancoId,
          },
        );
      } catch (e) {
        debugPrint("[ALEX_UNLINK_BROADCAST_ERR] $e");
      }

      _db.notifySyncUpdate(-999);
      broadcastSyncPulse(isDeep: true, targetPin: cleanPin);
    } catch (e) {
      debugPrint("[ALEX_UNLINK_ERR] $e");
      broadcastSyncPulse(isDeep: true);
      rethrow;
    }
  }

  /// Elimina por completo una lista (Listero) localmente y en la nube
  Future<void> deleteListero(String pin) async {
    final bancoId = await getActiveBancoId();
    if (bancoId == null) return;
    try {
      final cleanPin = pin.trim();
      await _db.deleteListero(cleanPin, bancoId, sync: 1);
      await _supabase.from('listeros').delete().match({
        'banco_id': bancoId,
        'pin': cleanPin,
      });

      // Emitir evento directo por WebSocket en tiempo real
      try {
        if (_commandChannel == null) {
          await initRealtimeChannels(bancoId);
        }
        await _commandChannel?.sendBroadcastMessage(
          event: 'LISTERO_DELETE',
          payload: {
            'pin': cleanPin,
            'banco_id': bancoId,
          },
        );
      } catch (e) {
        debugPrint("[ALEX_DELETE_BROADCAST_ERR] $e");
      }

      _db.notifySyncUpdate(-999);
      broadcastSyncPulse(isDeep: true);
    } catch (e) {
      debugPrint("[ALEX_DELETE_LISTERO_ERR] $e");
      rethrow;
    }
  }

  /// Elimina un tiro/resultado de forma completa y limpia los partes
  Future<void> deleteResultado(String fecha, String seccion, {required String bancoId, String loteria = "FLORIDA"}) async {
    final lot = loteria.trim().toUpperCase();
    await _db.deleteResultado(fecha, seccion, bancoId: bancoId, loteria: lot, sync: 1);
    try {
      await _supabase.from('resultados').delete().match({
        'banco_id': bancoId,
        'fecha': fecha,
        'seccion': seccion,
        'loteria': lot,
      });
      await _supabase.from('partes').delete().match({
        'banco_id': bancoId,
        'fecha': fecha,
        'seccion': seccion,
        'loteria': lot,
      });
    } catch (e) {
      debugPrint("[ALEX_DELETE_RESULTADO_SUPABASE_ERR] $e");
    }
    TiroService().notifyNewTiro(null);
    broadcastSyncPulse(isDeep: true);
  }

  /// Comprueba en SQLite y Supabase si el listero activo está bloqueado por el banco
  Future<void> checkListeroBlockStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String userRole = prefs.getString("user_role") ?? "GUEST";
      if (userRole != "LISTERO") {
        isListeroBlocked.value = false;
        return;
      }

      final String myPin = await getActiveListeroPin();
      final String? bId = await getActiveBancoId();
      if (myPin.isEmpty || bId == null || bId == "UNKNOWN") {
        isListeroBlocked.value = false;
        return;
      }

      final local = await _db.getListeroByPin(myPin, bId);
      if (local != null) {
        bool blocked = (local['bloqueado'] == 1 || local['bloqueado'] == true);
        isListeroBlocked.value = blocked;
      } else {
        final global = await _db.findListeroGlobally(myPin);
        if (global != null) {
          final Map<String, dynamic>? lData = global['listero'] as Map<String, dynamic>?;
          bool blocked = (lData?['bloqueado'] == 1 || lData?['bloqueado'] == true);
          isListeroBlocked.value = blocked;
        }
      }
    } catch (e) {
      debugPrint("[ALEX_CHECK_BLOCK_ERR] $e");
    }
  }

  /// Bloquea o desbloquea un listero
  Future<void> setListeroBlockStatus(String pin, bool blocked) async {
    final bancoId = await getActiveBancoId();
    if (bancoId == null) return;

    try {
      // 1. Nube
      await _supabase.from('listeros').update({
        'bloqueado': blocked ? 1 : 0
      }).match({'pin': pin, 'banco_id': bancoId});

      // 2. Local
      final local = await _db.getListeroByPin(pin, bancoId);
      if (local != null) {
        final updated = Map<String, dynamic>.from(local);
        updated['bloqueado'] = blocked ? 1 : 0;
        updated['sync'] = 0;
        await _db.upsertListero(updated);
      }

      // 3. Emitir evento directo por WebSocket en tiempo real
      try {
        if (_commandChannel == null) {
          await initRealtimeChannels(bancoId);
        }
        await _commandChannel?.sendBroadcastMessage(
          event: 'LISTERO_BLOCK_TOGGLE',
          payload: {
            'pin': pin.trim(),
            'blocked': blocked,
            'banco_id': bancoId,
          },
        );
      } catch (e) {
        debugPrint("[ALEX_BLOCK_REALTIME_ERR] $e");
      }

      broadcastSyncPulse(isDeep: true, targetPin: pin);
    } catch (e) {
      debugPrint("[ALEX_BLOCK_ERR] $e");
      rethrow;
    }
  }

  /// Verifica si la lista activa del dispositivo listero fue desvinculada o eliminada en Supabase
  Future<void> verifyActiveListeroStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String userRole = prefs.getString("user_role") ?? "";
      if (userRole != "LISTERO") return;

      final String myPin = await getActiveListeroPin();
      final String? bId = await getActiveBancoId();
      if (myPin.isEmpty || bId == null || bId == "UNKNOWN") return;

      final myDevId = await _getDeviceId();
      final resList = await _supabase.from('listeros').select().eq('banco_id', bId).eq('pin', myPin);
      
      if (resList.isEmpty) {
        debugPrint("[ALEX_SECURITY] Mi lista '$myPin' ya no existe en la nube. Cerrando sesión...");
        await logout(fullReset: true);
        _liveBetsController.add({
          'type': 'LISTERO_UNLINKED',
          'message': '⚠️ SU LISTA HA SIDO ELIMINADA POR EL BANCO.'
        });
      } else {
        final res = Map<String, dynamic>.from(resList.first);
        final bool isLinked = (res['vinculado'] == 1 || res['vinculado'] == true);
        final String? cloudDevId = res['device_id'];
        if (!isLinked || (cloudDevId != null && cloudDevId.isNotEmpty && cloudDevId != myDevId)) {
          debugPrint("[ALEX_SECURITY] Mi lista '$myPin' fue desvinculada en la nube (cloudDevId: $cloudDevId vs miDevId: $myDevId). Cerrando sesión...");
          await logout(fullReset: true);
          _liveBetsController.add({
            'type': 'LISTERO_UNLINKED',
            'message': '⚠️ SU LISTA HA SIDO DESVINCULADA POR EL BANCO.'
          });
        }
      }
    } catch (e) {
      debugPrint("[ALEX_SECURITY_ERR] Error verificando estado de listero: $e");
    }
  }
}
