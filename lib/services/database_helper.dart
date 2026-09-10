import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;

  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  static final Map<String, String> _defaultPlanConfig = {
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

  Map<String, String> getDefaultPlanConfig() => _defaultPlanConfig;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    if (!kIsWeb && (Platform.isLinux || Platform.isWindows)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    String path = join(await getDatabasesPath(), 'srecord_local.db');
    return await openDatabase(
      path,
      version: 30,
      onOpen: (db) async {
        // SEGURIDAD DE ESQUEMA: Asegurar columnas críticas si la migración falló
        await _ensureSchemaIntegrity(db);
      },
      onCreate: (db, version) async {
        await db.execute('''CREATE TABLE jugadas(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            banco_id TEXT,
            listero_pin TEXT, tipo TEXT, valor TEXT, destino TEXT DEFAULT 'LISTA',
            seccion TEXT DEFAULT 'DIA', fecha TEXT, 
            sync INTEGER DEFAULT 1,
            uuid TEXT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
          )''');
        await db.execute('''CREATE TABLE resultados(
            banco_id TEXT, fecha TEXT, seccion TEXT, loteria TEXT DEFAULT 'FLORIDA', n1 TEXT, n2 TEXT, n3 TEXT,
            sync INTEGER DEFAULT 1,
            PRIMARY KEY (banco_id, fecha, seccion, loteria)
          )''');
        await db.execute('''CREATE TABLE partes(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            banco_id TEXT, listero_pin TEXT, fecha TEXT, seccion TEXT, tiro TEXT,
            fondo_anterior REAL, bruto_lista REAL, limpio_lista REAL, premios_lista REAL,
            bruto_bote REAL, limpio_bote REAL, premios_bote REAL, total_dia REAL, 
            liquidacion REAL DEFAULT 0.0, saldo_final REAL,
            winners_json TEXT,
            publicado INTEGER DEFAULT 0,
            recibido INTEGER DEFAULT 0,
            sync INTEGER DEFAULT 1,
            uuid TEXT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(banco_id, listero_pin, fecha, seccion)
          )''');
        await db.execute('''CREATE TABLE notificaciones(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            banco_id TEXT,
            listero_pin TEXT,
            titulo TEXT, mensaje TEXT, fecha TEXT, 
            visto INTEGER DEFAULT 0,
            es_oficial INTEGER DEFAULT 0,
            sync INTEGER DEFAULT 1,
            uuid TEXT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
          )''');
        await db.execute('''CREATE TABLE limites(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            banco_id TEXT,
            tipo TEXT, numero TEXT, destino TEXT, seccion TEXT, fecha TEXT,
            fijo TEXT, corrido TEXT, pago TEXT,
            sync INTEGER DEFAULT 1,
            uuid TEXT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
          )''');
        await db.execute('''CREATE TABLE listeros(
            banco_id TEXT,
            pin TEXT,
            nombre TEXT, plan TEXT, 
            bloqueado INTEGER DEFAULT 0, 
            vinculado INTEGER DEFAULT 0,
            device_id TEXT,
            last_seen TEXT,
            last_sync_count INTEGER DEFAULT 0,
            sync INTEGER DEFAULT 1,
            PRIMARY KEY (banco_id, pin)
          )''');
        await db.execute('''CREATE TABLE planes(
            banco_id TEXT,
            nombre TEXT,
            config TEXT,
            updated_at TEXT,
            sync INTEGER DEFAULT 1,
            PRIMARY KEY (banco_id, nombre)
          )''');
        await db.execute('''CREATE TABLE sync_deletions(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            tabla TEXT,
            remoto_id TEXT,
            banco_id TEXT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
          )''');
        await db.execute('''CREATE TABLE bank_colors(
            banco_id TEXT PRIMARY KEY,
            color_hex TEXT,
            bank_name TEXT,
            updated_at TEXT,
            sync INTEGER DEFAULT 1
          )''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 19) {
          debugPrint("[DB MIGRATION] Evolucionando a Multi-tenant Real (v19)...");
          // EVITAR DROP SI ES POSIBLE: Solo crear si no existen, o renombrar para backup
          await db.execute('CREATE TABLE IF NOT EXISTS listeros(banco_id TEXT, pin TEXT, nombre TEXT, plan TEXT, bloqueado INTEGER DEFAULT 0, vinculado INTEGER DEFAULT 0, sync INTEGER DEFAULT 1, PRIMARY KEY (banco_id, pin))');
          await db.execute('CREATE TABLE IF NOT EXISTS planes(banco_id TEXT, nombre TEXT, config TEXT, updated_at TEXT, sync INTEGER DEFAULT 1, PRIMARY KEY (banco_id, nombre))');
          
          final tables = ['jugadas', 'resultados', 'partes', 'notificaciones', 'limites'];
          for (var table in tables) {
            try { await db.execute('ALTER TABLE $table ADD COLUMN banco_id TEXT'); } catch (_) {}
          }
        }
        if (oldVersion < 21) {
          debugPrint("[DB MIGRATION] Activando Soberanía Cromática (v21)...");
          try {
            await db.execute('''CREATE TABLE bank_colors(
              banco_id TEXT PRIMARY KEY,
              color_hex TEXT
            )''');
          } catch (_) {}
        }
        if (oldVersion < 24) {
          debugPrint("[DB MIGRATION] Supervisión de Listeros (v24)...");
          try { await db.execute('ALTER TABLE listeros ADD COLUMN last_seen TEXT'); } catch (_) {}
          try { await db.execute('ALTER TABLE listeros ADD COLUMN last_sync_count INTEGER DEFAULT 0'); } catch (_) {}
        }
        if (oldVersion < 25) {
          debugPrint("[DB MIGRATION] Anclaje de Hardware (v25)...");
          try { await db.execute('ALTER TABLE listeros ADD COLUMN device_id TEXT'); } catch (_) {}
        }
        if (oldVersion < 26) {
          debugPrint("[DB MIGRATION] Diario de Borrados Sincronizados (v26)...");
          try {
            await db.execute('''CREATE TABLE sync_deletions(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              tabla TEXT,
              remoto_id TEXT,
              banco_id TEXT,
              timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
            )''');
          } catch (_) {}
        }
        if (oldVersion < 27) {
          debugPrint("[DB MIGRATION] Identidad Unívoca para Mirroring (v27)...");
          final tables = ['jugadas', 'partes', 'limites', 'notificaciones'];
          for (var table in tables) {
            try { await db.execute('ALTER TABLE $table ADD COLUMN uuid TEXT'); } catch (_) {}
          }
        }
        if (oldVersion < 28) {
          debugPrint("[DB MIGRATION] Sincronización Temporal de Planes (v28)...");
          try { await db.execute('ALTER TABLE planes ADD COLUMN updated_at TEXT'); } catch (_) {}
        }
        if (oldVersion < 29) {
          debugPrint("[DB MIGRATION] Paridad Total de Esquema (v29)...");
          try { await db.execute('ALTER TABLE partes ADD COLUMN updated_at TEXT'); } catch (_) {}
          try { await db.execute('ALTER TABLE limites ADD COLUMN updated_at TEXT'); } catch (_) {}
        }
        if (oldVersion < 30) {
          debugPrint("[DB MIGRATION] Avisos Oficiales (v30)...");
          try { await db.execute('ALTER TABLE notificaciones ADD COLUMN es_oficial INTEGER DEFAULT 0'); } catch (_) {}
        }
      },
    );
  }

  Future<void> _ensureSchemaIntegrity(Database db) async {
    try {
      // 0. Verificar tabla notificaciones
      var columnsNotis = await db.rawQuery("PRAGMA table_info(notificaciones)");
      if (!columnsNotis.any((c) => c['name'] == 'es_oficial')) {
        await db.execute("ALTER TABLE notificaciones ADD COLUMN es_oficial INTEGER DEFAULT 0");
      }

      // 1. Verificar tabla listeros
      var columnsListeros = await db.rawQuery("PRAGMA table_info(listeros)");
      if (!columnsListeros.any((c) => c['name'] == 'device_id')) {
        await db.execute("ALTER TABLE listeros ADD COLUMN device_id TEXT");
      }
      if (!columnsListeros.any((c) => c['name'] == 'updated_at')) {
        await db.execute("ALTER TABLE listeros ADD COLUMN updated_at TEXT");
      }
      if (!columnsListeros.any((c) => c['name'] == 'loterias')) {
        await db.execute("ALTER TABLE listeros ADD COLUMN loterias TEXT DEFAULT 'AMBAS'");
      }

      // 1.1 Verificar tabla planes (Recuperación Crítica)
      var columnsPlanes = await db.rawQuery("PRAGMA table_info(planes)");
      if (!columnsPlanes.any((c) => c['name'] == 'updated_at')) {
        await db.execute("ALTER TABLE planes ADD COLUMN updated_at TEXT");
      }
      if (!columnsPlanes.any((c) => c['name'] == 'loteria')) {
        await db.execute("ALTER TABLE planes ADD COLUMN loteria TEXT DEFAULT 'FLORIDA'");
      }

      // 2. Verificar tabla jugadas
      var columnsJugadas = await db.rawQuery("PRAGMA table_info(jugadas)");
      if (!columnsJugadas.any((c) => c['name'] == 'is_whatsapp')) {
        await db.execute("ALTER TABLE jugadas ADD COLUMN is_whatsapp INTEGER DEFAULT 0");
      }
      if (!columnsJugadas.any((c) => c['name'] == 'timestamp')) {
        await db.execute("ALTER TABLE jugadas ADD COLUMN timestamp DATETIME DEFAULT CURRENT_TIMESTAMP");
      }

      // 3. Verificar tabla bank_colors
      var columnsColors = await db.rawQuery("PRAGMA table_info(bank_colors)");
      if (!columnsColors.any((c) => c['name'] == 'sync')) {
        await db.execute("ALTER TABLE bank_colors ADD COLUMN sync INTEGER DEFAULT 1");
      }
      if (!columnsColors.any((c) => c['name'] == 'bank_name')) {
        await db.execute("ALTER TABLE bank_colors ADD COLUMN bank_name TEXT");
      }
      if (!columnsColors.any((c) => c['name'] == 'updated_at')) {
        await db.execute("ALTER TABLE bank_colors ADD COLUMN updated_at TEXT");
      }
      if (!columnsColors.any((c) => c['name'] == 'loterias')) {
        await db.execute("ALTER TABLE bank_colors ADD COLUMN loterias TEXT DEFAULT 'AMBAS'");
      }

      // 4. Verificar tabla limites y partes (Asegurar paridad con nube)
      var columnsLimites = await db.rawQuery("PRAGMA table_info(limites)");
      if (!columnsLimites.any((c) => c['name'] == 'updated_at')) {
        await db.execute("ALTER TABLE limites ADD COLUMN updated_at TEXT");
      }
      var columnsPartes = await db.rawQuery("PRAGMA table_info(partes)");
      if (!columnsPartes.any((c) => c['name'] == 'updated_at')) {
        await db.execute("ALTER TABLE partes ADD COLUMN updated_at TEXT");
      }
      if (!columnsPartes.any((c) => c['name'] == 'winners_json')) {
        await db.execute("ALTER TABLE partes ADD COLUMN winners_json TEXT");
      }

      // 5. Verificar existencia de sync_deletions
      var tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='sync_deletions'");
      if (tables.isEmpty) {
        await db.execute('''CREATE TABLE sync_deletions(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            tabla TEXT,
            remoto_id TEXT,
            banco_id TEXT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
          )''');
      }

      // 6. Verificar integridad de UUID en tablas transaccionales
      final txTables = ['jugadas', 'partes', 'limites', 'notificaciones'];
      for (var table in txTables) {
        var cols = await db.rawQuery("PRAGMA table_info($table)");
        if (!cols.any((c) => c['name'] == 'uuid')) {
          await db.execute("ALTER TABLE $table ADD COLUMN uuid TEXT");
        }
      }

      // 7. OPTIMIZACIÓN TURBO: Índices de alto rendimiento
      await db.execute("CREATE INDEX IF NOT EXISTS idx_jugadas_turbo ON jugadas(banco_id, listero_pin, fecha, seccion)");
      await db.execute("CREATE INDEX IF NOT EXISTS idx_partes_turbo ON partes(banco_id, listero_pin, fecha, seccion)");
      await db.execute("CREATE INDEX IF NOT EXISTS idx_resultados_turbo ON resultados(banco_id, fecha, seccion, loteria)");
      await db.execute("CREATE INDEX IF NOT EXISTS idx_limites_turbo ON limites(banco_id, seccion, fecha)");

      // 8. SOPORTE MULTI-LOTERÍA (Florida y Georgia)
      final loteriaTables = ['jugadas', 'resultados', 'partes', 'limites'];
      for (var table in loteriaTables) {
        var cols = await db.rawQuery("PRAGMA table_info($table)");
        if (!cols.any((c) => c['name'] == 'loteria')) {
          await db.execute("ALTER TABLE $table ADD COLUMN loteria TEXT DEFAULT 'FLORIDA'");
        }
      }

      // Migración específica para corregir la PRIMARY KEY de 'resultados' si no incluye 'loteria'
      var resCols = await db.rawQuery("PRAGMA table_info(resultados)");
      bool loteriaIsPk = resCols.any((c) => c['name'] == 'loteria' && (c['pk'] as int? ?? 0) > 0);
      if (!loteriaIsPk) {
        debugPrint("[DB_FIX] Migrando tabla resultados para incluir loteria en la PRIMARY KEY...");
        await db.execute('''CREATE TABLE IF NOT EXISTS resultados_new (
            banco_id TEXT, fecha TEXT, seccion TEXT, loteria TEXT DEFAULT 'FLORIDA', n1 TEXT, n2 TEXT, n3 TEXT,
            sync INTEGER DEFAULT 1,
            PRIMARY KEY (banco_id, fecha, seccion, loteria)
        )''');
        await db.execute('''INSERT OR REPLACE INTO resultados_new (banco_id, fecha, seccion, loteria, n1, n2, n3, sync)
            SELECT banco_id, fecha, seccion, COALESCE(loteria, 'FLORIDA'), n1, n2, n3, sync FROM resultados;''');
        await db.execute("DROP TABLE resultados");
        await db.execute("ALTER TABLE resultados_new RENAME TO resultados");
        await db.execute("CREATE INDEX IF NOT EXISTS idx_resultados_turbo ON resultados(banco_id, fecha, seccion, loteria)");
      }
    } catch (e) {
      debugPrint("[DB_FIX_ERR] $e");
    }
  }

  Future<void> _logDeletion(String tabla, String remotoId, String bancoId, {Transaction? txn}) async {
    final executor = txn ?? (await database);
    
    String finalId = remotoId;
    final tablesWithId = {'jugadas', 'partes', 'limites', 'notificaciones'};
    
    // SI es un ID numérico y la tabla soporta UUID, buscamos el UUID
    if (tablesWithId.contains(tabla) && int.tryParse(remotoId) != null) {
      try {
        final List<Map<String, dynamic>> res = await executor.query(tabla, columns: ['uuid'], where: 'id = ?', whereArgs: [remotoId]);
        if (res.isNotEmpty && res.first['uuid'] != null) {
          finalId = res.first['uuid'];
        }
      } catch (_) {}
    }

    debugPrint("[DB_DELETE_LOG] Registrando borrado: $tabla -> $finalId");
    await executor.insert('sync_deletions', {
      'tabla': tabla,
      'remoto_id': finalId,
      'banco_id': bancoId
    });
  }

  Future<List<Map<String, dynamic>>> getPendingDeletions() async {
    final db = await database;
    return await db.query('sync_deletions');
  }

  Future<void> clearDeletions(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    await db.delete('sync_deletions', where: 'id IN (${ids.join(',')})');
  }

  Future<void> updateListeroDevice(String pin, String bancoId, String? deviceId) async {
    final db = await database;
    await db.update('listeros', {'device_id': deviceId, 'vinculado': deviceId != null ? 1 : 0, 'sync': 1}, 
      where: 'pin = ? AND banco_id = ?', whereArgs: [pin, bancoId]);
  }

  Future<void> insertJugadasBatch(List<Map<String, dynamic>> rows, {String? bancoId}) async {
    if (rows.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      for (var row in rows) {
        final Map<String, dynamic> mutableRow = Map.from(row);
        if (bancoId != null) mutableRow['banco_id'] = bancoId;
        mutableRow['sync'] = 1;
        if (mutableRow['uuid'] == null) {
          mutableRow['uuid'] = _generateUuid();
        }
        await txn.insert('jugadas', mutableRow);
      }
    });
    _notifySync(-1); // Disparar sincronización inmediata tras el lote
  }

  String _generateUuid() {
    final random = Random();
    return '${DateTime.now().millisecondsSinceEpoch}-${random.nextInt(100000)}';
  }

  Future<int> insertJugada(String listeroPin, String tipo, String valor, {String destino = 'LISTA', String seccion = 'DIA', String? fecha, String? bancoId, String loteria = 'FLORIDA'}) async {
    final db = await database;
    String dateStr = (fecha ?? DateTime.now().toString().substring(0, 10)).trim();
    
    Map<String, dynamic> row = {
      'banco_id': bancoId?.trim(),
      'listero_pin': listeroPin.trim(),
      'tipo': tipo.trim(),
      'valor': valor.trim(),
      'destino': destino.trim(),
      'seccion': seccion.trim(),
      'fecha': dateStr,
      'loteria': loteria.trim().toUpperCase(),
      'sync': 1,
      'uuid': _generateUuid()
    };
    int id = await db.insert('jugadas', row);
    _notifySync(id);
    return id;
  }

  final List<Function(int)> _syncListeners = [];

  set onSyncUpdate(Function(int) listener) {
    if (!_syncListeners.contains(listener)) {
      _syncListeners.add(listener);
    }
  }

  void notifySyncUpdate(int id) {
    // Clonamos la lista para evitar errores si alguien se remueve durante la notificación
    final listeners = List<Function(int)>.from(_syncListeners);
    for (var listener in listeners) {
      try {
        listener(id);
      } catch (e) {
        debugPrint("[DB_HELPER] Error notificando a listener: $e");
      }
    }
  }

  void removeSyncUpdate(Function(int) listener) {
    _syncListeners.remove(listener);
  }

  void _notifySync(int id) => notifySyncUpdate(id);

  Future<List<Map<String, dynamic>>> getJugadasCompletas(String listeroPin, {String? destino, String seccion = 'DIA', String? fecha, String? bancoId, String? loteria}) async {
    final db = await database;
    String dateStr = (fecha ?? DateTime.now().toString().substring(0, 10)).trim();
    
    String whereClause = 'seccion = ? AND fecha = ?';
    List<dynamic> whereArgs = [seccion.trim(), dateStr];

    if (loteria != null && loteria.isNotEmpty) {
      whereClause += " AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))";
      whereArgs.add(loteria.trim().toUpperCase());
      whereArgs.add(loteria.trim().toUpperCase());
    }
    
    if (listeroPin.isNotEmpty) {
      whereClause += ' AND listero_pin = ?';
      whereArgs.add(listeroPin.trim());
    }
    
    if (bancoId != null && bancoId != "UNKNOWN") {
      whereClause += ' AND banco_id = ?';
      whereArgs.add(bancoId.trim());
    } else if (bancoId == "UNKNOWN") {
      whereClause += " AND (banco_id IS NULL OR banco_id = 'UNKNOWN')";
    }

    if (destino != null) {
      whereClause += ' AND destino = ?';
      whereArgs.add(destino.trim());
    }
    return await db.query('jugadas', where: whereClause, whereArgs: whereArgs, orderBy: 'id ASC');
  }

  Future<List<Map<String, dynamic>>> getJugadas(String listeroPin, String tipo, {String? destino, String seccion = 'DIA', String? fecha, String? bancoId, String? loteria}) async {
    final db = await database;
    String dateStr = (fecha ?? DateTime.now().toString().substring(0, 10)).trim();
    String whereClause = 'listero_pin = ? AND tipo = ? AND seccion = ? AND fecha = ?';
    List<dynamic> whereArgs = [listeroPin.trim(), tipo.trim(), seccion.trim(), dateStr];

    if (loteria != null && loteria.isNotEmpty) {
      whereClause += " AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))";
      whereArgs.add(loteria.trim().toUpperCase());
      whereArgs.add(loteria.trim().toUpperCase());
    }
    
    if (bancoId != null && bancoId != "UNKNOWN") {
      whereClause += ' AND banco_id = ?';
      whereArgs.add(bancoId.trim());
    } else if (bancoId == "UNKNOWN") {
      whereClause += " AND (banco_id IS NULL OR banco_id = 'UNKNOWN')";
    }

    if (destino != null) {
      whereClause += ' AND destino = ?';
      whereArgs.add(destino.trim());
    }
    return await db.query('jugadas', where: whereClause, whereArgs: whereArgs, orderBy: 'id ASC');
  }

  Future<int> deleteJugada(int id) async {
    final db = await database;
    final data = await db.query('jugadas', columns: ['banco_id', 'listero_pin', 'fecha', 'seccion'], where: 'id = ?', whereArgs: [id]);
    if (data.isNotEmpty) {
      final pin = data.first['listero_pin'] as String;
      final fecha = data.first['fecha'] as String;
      final seccion = data.first['seccion'] as String;
      final bancoId = data.first['banco_id'] as String;
      
      await _logDeletion('jugadas', "SECTION:$pin|$fecha|$seccion", bancoId);
      await markSectionAsPendingSync(pin, fecha, seccion, bancoId);
    }
    int count = await db.delete('jugadas', where: 'id = ?', whereArgs: [id]);
    _notifySync(-1);
    return count;
  }

  Future<void> markSectionAsPendingSync(String pin, String fecha, String seccion, String bancoId) async {
    final db = await database;
    await db.update('jugadas', {'sync': 1}, 
      where: 'listero_pin = ? AND fecha = ? AND seccion = ? AND banco_id = ?',
      whereArgs: [pin, fecha, seccion, bancoId]
    );
  }

  Future<int> deleteJugadas(List<int> ids) async {
    if (ids.isEmpty) return 0;
    final db = await database;
    
    // Capturamos las secciones afectadas antes de borrar
    final Set<String> affectedSections = {};
    String? bancoId;

    for (var id in ids) {
      final data = await db.query('jugadas', columns: ['banco_id', 'listero_pin', 'fecha', 'seccion'], where: 'id = ?', whereArgs: [id]);
      if (data.isNotEmpty) {
        bancoId ??= data.first['banco_id'] as String;
        final pin = data.first['listero_pin'];
        final fecha = data.first['fecha'];
        final seccion = data.first['seccion'];
        affectedSections.add("SECTION:$pin|$fecha|$seccion");
      }
    }

    if (bancoId != null) {
      for (var sectionKey in affectedSections) {
        await _logDeletion('jugadas', sectionKey, bancoId);
        final parts = sectionKey.replaceFirst('SECTION:', '').split('|');
        if (parts.length == 3) {
          await markSectionAsPendingSync(parts[0], parts[1], parts[2], bancoId);
        }
      }
    }

    int count = await db.delete('jugadas', where: 'id IN (${ids.join(',')})');
    _notifySync(-1);
    return count;
  }

  Future<List<Map<String, dynamic>>> getRecentResultados({required String bancoId, String? loteria, int limit = 5}) async {
    final db = await database;
    String whereClause = 'banco_id = ?';
    List<dynamic> whereArgs = [bancoId.trim()];
    if (loteria != null && loteria.isNotEmpty) {
      whereClause += " AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))";
      whereArgs.add(loteria.trim().toUpperCase());
      whereArgs.add(loteria.trim().toUpperCase());
    }
    return await db.query('resultados', where: whereClause, whereArgs: whereArgs, orderBy: 'fecha DESC, seccion DESC', limit: limit);
  }

  Future<bool> saveResultado(String fecha, String seccion, String n1, String n2, String n3, {required String bancoId, String loteria = 'FLORIDA', int sync = 1}) async {
    final db = await database;
    debugPrint("[DB_HELPER] Guardando resultado local: $fecha | $seccion ($loteria) -> $n1-$n2-$n3 (Sync: $sync)");
    
    final row = {
      'banco_id': bancoId.trim(), 
      'fecha': fecha.trim(), 
      'seccion': seccion.trim(), 
      'loteria': loteria.trim().toUpperCase(), 
      'n1': n1.trim(), 
      'n2': n2.trim(), 
      'n3': n3.trim(), 
      'sync': sync
    };
    await db.insert('resultados', row, conflictAlgorithm: ConflictAlgorithm.replace);
    _notifySync(sync == 0 ? -999 : -1);
    return true;
  }

  Future<Map<String, String>?> getResultado(String fecha, String seccion, {required String bancoId, String? loteria}) async {
    final db = await database;
    String whereClause = 'banco_id = ? AND fecha = ? AND seccion = ?';
    List<dynamic> whereArgs = [bancoId.trim(), fecha.trim(), seccion.trim()];
    if (loteria != null && loteria.isNotEmpty) {
      whereClause += " AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))";
      whereArgs.add(loteria.trim().toUpperCase());
      whereArgs.add(loteria.trim().toUpperCase());
    }
    final List<Map<String, dynamic>> maps = await db.query('resultados', where: whereClause, whereArgs: whereArgs);
    if (maps.isEmpty) return null;
    return {'n1': maps[0]['n1'], 'n2': maps[0]['n2'], 'n3': maps[0]['n3']};
  }

  Future<void> deleteResultado(String fecha, String seccion, {required String bancoId, String loteria = 'FLORIDA', int sync = 1}) async {
    final db = await database;
    final f = fecha.trim();
    final s = seccion.trim();
    final b = bancoId.trim();
    final l = loteria.trim().toUpperCase();

    debugPrint("[DB_DELETE] Intentando borrar tiro: $f | $s ($l) (Banco: $b, Sync: $sync)");

    final List<Map<String, dynamic>> affected = await db.query('partes', 
      columns: ['listero_pin', 'uuid'], 
      where: "banco_id = ? AND fecha = ? AND seccion = ? AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))", 
      whereArgs: [b, f, s, l, l]
    );
    
    await db.transaction((txn) async {
      if (sync == 1) {
        await _logDeletion('resultados', "$f|$s|$l", b, txn: txn);
        for (var row in affected) {
          if (row['uuid'] != null) {
            await _logDeletion('partes', row['uuid'] as String, b, txn: txn);
          }
        }
      }
      int resCount = await txn.delete('resultados', where: "banco_id = ? AND fecha = ? AND seccion = ? AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))", whereArgs: [b, f, s, l, l]);
      int partCount = await txn.delete('partes', where: "banco_id = ? AND fecha = ? AND seccion = ? AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))", whereArgs: [b, f, s, l, l]);
      
      debugPrint("[DB_DELETE] Borrados: $resCount resultados, $partCount partes.");

      for (var row in affected) {
        await _fullRecalculate(txn, row['listero_pin'], b, loteria: l);
      }
    });
    _notifySync(-999);
  }

  Future<int> insertParte(Map<String, dynamic> data, {int sync = 1}) async {
    final db = await database;
    final Map<String, dynamic> cleanData = Map.from(data);
    cleanData['sync'] = sync;
    if (cleanData['uuid'] == null) cleanData['uuid'] = _generateUuid();
    final String lot = (cleanData['loteria']?.toString() ?? 'FLORIDA').trim().toUpperCase();
    cleanData['loteria'] = lot;
    cleanData.remove('id'); // Remover 'id' importado para permitir AUTOINCREMENT local en SQLite

    await db.delete('partes',
      where: "banco_id = ? AND listero_pin = ? AND fecha = ? AND seccion = ? AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))",
      whereArgs: [cleanData['banco_id'], cleanData['listero_pin'], cleanData['fecha'], cleanData['seccion'], lot, lot]
    );
    
    int id = await db.insert('partes', cleanData);

    await db.transaction((txn) async {
      await _fullRecalculate(txn, cleanData['listero_pin'], cleanData['banco_id'], loteria: lot);
    });
    
    _notifySync(sync == 0 ? -999 : id);
    return id;
  }

  Future<List<Map<String, dynamic>>> getPartesCompletos({required String bancoId, String? loteria}) async {
    final db = await database;
    String whereClause = 'banco_id = ?';
    List<dynamic> whereArgs = [bancoId.trim()];
    if (loteria != null && loteria.isNotEmpty) {
      whereClause += " AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))";
      whereArgs.add(loteria.trim().toUpperCase());
      whereArgs.add(loteria.trim().toUpperCase());
    }
    return await db.query(
      'partes', 
      where: whereClause, 
      whereArgs: whereArgs, 
      orderBy: "fecha DESC, CASE seccion WHEN 'NIGHT' THEN 3 WHEN 'EVENING' THEN 2 WHEN 'NOCHE' THEN 2 WHEN 'MIDDAY' THEN 1 WHEN 'DIA' THEN 1 ELSE 0 END DESC"
    );
  }

  Future<Map<String, dynamic>?> getParte(String pin, String fecha, String seccion, {required String bancoId, String? loteria}) async {
    final db = await database;
    String whereClause = 'banco_id = ? AND listero_pin = ? AND fecha = ? AND seccion = ?';
    List<dynamic> whereArgs = [bancoId.trim(), pin.trim(), fecha.trim(), seccion.trim()];
    if (loteria != null && loteria.isNotEmpty) {
      whereClause += " AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))";
      whereArgs.add(loteria.trim().toUpperCase());
      whereArgs.add(loteria.trim().toUpperCase());
    }
    final List<Map<String, dynamic>> res = await db.query('partes', 
      where: whereClause, 
      whereArgs: whereArgs,
      limit: 1
    );
    return res.isEmpty ? null : res.first;
  }

  Future<List<Map<String, dynamic>>> getPartesByListero(String listeroPin, {required String bancoId, bool soloPublicados = false, String? loteria}) async {
    final db = await database;
    String where = 'banco_id = ? AND listero_pin = ?';
    List<dynamic> args = [bancoId.trim(), listeroPin.trim()];
    if (soloPublicados) {
      where += ' AND (publicado = 1 OR recibido = 1)';
    }
    if (loteria != null && loteria.isNotEmpty && loteria.trim().toUpperCase() != "AMBAS") {
      where += " AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))";
      args.add(loteria.trim().toUpperCase());
      args.add(loteria.trim().toUpperCase());
    }
    return await db.query(
      'partes',
      where: where, 
      orderBy: "fecha DESC, CASE WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'GEORGIA' AND UPPER(seccion) = 'NIGHT') THEN 5 WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'FLORIDA' AND UPPER(seccion) = 'NOCHE') THEN 4 WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'GEORGIA' AND UPPER(seccion) = 'EVENING') THEN 3 WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'FLORIDA' AND UPPER(seccion) = 'DIA') THEN 2 WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'GEORGIA' AND UPPER(seccion) = 'MIDDAY') THEN 1 ELSE 0 END DESC", 
      whereArgs: args
    );
  }

  Future<int> publishPartesSelective(String fecha, String seccion, {required String bancoId, String? loteria}) async {
    final db = await database;
    String where = 'banco_id = ? AND fecha = ? AND seccion = ? AND publicado = 0';
    List<dynamic> args = [bancoId.trim(), fecha.trim(), seccion.trim()];
    if (loteria != null && loteria.isNotEmpty) {
      where += " AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))";
      args.add(loteria.trim().toUpperCase());
      args.add(loteria.trim().toUpperCase());
    }
    return await db.update('partes', {'publicado': 1}, where: where, whereArgs: args);
  }

  Future<int> publishPartes(String fecha, String seccion, {required String bancoId, String? loteria}) async {
    final db = await database;
    String where = 'banco_id = ? AND fecha = ? AND seccion = ?';
    List<dynamic> args = [bancoId.trim(), fecha.trim(), seccion.trim()];
    if (loteria != null && loteria.isNotEmpty) {
      where += " AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))";
      args.add(loteria.trim().toUpperCase());
      args.add(loteria.trim().toUpperCase());
    }
    return await db.update('partes', {'publicado': 1}, where: where, whereArgs: args);
  }

  Future<bool> arePartesPublicados(String fecha, String seccion, {required String bancoId, String? loteria}) async {
    final db = await database;
    String where = 'banco_id = ? AND fecha = ? AND seccion = ? AND publicado = 1';
    List<dynamic> args = [bancoId.trim(), fecha.trim(), seccion.trim()];
    if (loteria != null && loteria.isNotEmpty) {
      where += " AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))";
      args.add(loteria.trim().toUpperCase());
      args.add(loteria.trim().toUpperCase());
    }
    final res = await db.query('partes', where: where, whereArgs: args, limit: 1);
    return res.isNotEmpty;
  }

  Future<bool> hasUnpublishedPartes(String fecha, String seccion, {required String bancoId, String? loteria}) async {
    final db = await database;
    String where = 'banco_id = ? AND fecha = ? AND seccion = ? AND publicado = 0';
    List<dynamic> args = [bancoId.trim(), fecha.trim(), seccion.trim()];
    if (loteria != null && loteria.isNotEmpty) {
      where += " AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))";
      args.add(loteria.trim().toUpperCase());
      args.add(loteria.trim().toUpperCase());
    }
    final res = await db.query('partes', where: where, whereArgs: args, limit: 1);
    return res.isNotEmpty;
  }

  Future<List<Map<String, dynamic>>> getPartesByFechaSeccion(String fecha, String seccion, {required String bancoId, String? loteria}) async {
    final db = await database;
    String where = 'banco_id = ? AND fecha = ? AND seccion = ?';
    List<dynamic> args = [bancoId.trim(), fecha.trim(), seccion.trim()];
    if (loteria != null && loteria.isNotEmpty) {
      where += " AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))";
      args.add(loteria.trim().toUpperCase());
      args.add(loteria.trim().toUpperCase());
    }
    return await db.query('partes', where: where, whereArgs: args);
  }

  Future<int> markParteAsReceived(int id) async {
    final db = await database;
    return await db.update('partes', {'recibido': 1}, 
      where: 'id = ?', whereArgs: [id]);
  }

  Future<double> getLastSaldoFinal(String listeroPin, {required String bancoId, String? fecha, String? seccion, String? loteria}) async {
    final db = await database;
    final String cleanLot = (loteria ?? 'FLORIDA').trim().toUpperCase();
    final String cleanSec = (seccion ?? 'DIA').trim().toUpperCase();

    // Rango de orden cronológico secuencial unificado de los 5 sorteos diarios:
    // 1. GEORGIA MIDDAY (Georgia Mañana)
    // 2. FLORIDA DIA (Florida Día)
    // 3. GEORGIA EVENING (Georgia Tarde)
    // 4. FLORIDA NOCHE (Florida Noche)
    // 5. GEORGIA NIGHT (Georgia Noche)
    int targetRank = 2; // Por defecto Florida Día
    if (cleanLot == "GEORGIA") {
      if (cleanSec == "MIDDAY") targetRank = 1;
      if (cleanSec == "EVENING") targetRank = 3;
      if (cleanSec == "NIGHT") targetRank = 5;
    } else {
      if (cleanSec == "DIA" || cleanSec == "MIDDAY") targetRank = 2;
      if (cleanSec == "NOCHE" || cleanSec == "EVENING" || cleanSec == "NIGHT") targetRank = 4;
    }

    String where = "banco_id = ? AND listero_pin = ?";
    List<dynamic> args = [bancoId.trim(), listeroPin.trim()];

    if (fecha != null) {
      where += " AND (fecha < ? OR (fecha = ? AND (CASE WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'GEORGIA' AND UPPER(seccion) = 'MIDDAY') THEN 1 WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'FLORIDA' AND UPPER(seccion) = 'DIA') THEN 2 WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'GEORGIA' AND UPPER(seccion) = 'EVENING') THEN 3 WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'FLORIDA' AND UPPER(seccion) = 'NOCHE') THEN 4 WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'GEORGIA' AND UPPER(seccion) = 'NIGHT') THEN 5 ELSE 0 END) < ?))";
      args.addAll([fecha.trim(), fecha.trim(), targetRank]);
    }

    final List<Map<String, dynamic>> res = await db.query(
      'partes',
      where: where,
      orderBy: "fecha DESC, (CASE WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'GEORGIA' AND UPPER(seccion) = 'MIDDAY') THEN 1 WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'FLORIDA' AND UPPER(seccion) = 'DIA') THEN 2 WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'GEORGIA' AND UPPER(seccion) = 'EVENING') THEN 3 WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'FLORIDA' AND UPPER(seccion) = 'NOCHE') THEN 4 WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'GEORGIA' AND UPPER(seccion) = 'NIGHT') THEN 5 ELSE 0 END) DESC",
      limit: 1,
      whereArgs: args,
    );
    return res.isEmpty ? 0.0 : (res[0]['saldo_final'] as num).toDouble();
  }

  Future<void> updateFondoAndRecalculate(String pin, String bancoId, String fecha, String seccion, double nuevoFondo, {String? loteria}) async {
    final db = await database;
    final String cleanLot = (loteria ?? 'FLORIDA').trim().toUpperCase();
    await db.transaction((txn) async {
      await txn.update('partes', {'fondo_anterior': nuevoFondo}, 
        where: "banco_id = ? AND listero_pin = ? AND fecha = ? AND seccion = ? AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))", 
        whereArgs: [bancoId.trim(), pin.trim(), fecha.trim(), seccion.trim(), cleanLot, cleanLot]);
      await _fullRecalculate(txn, pin.trim(), bancoId.trim(), loteria: cleanLot);
    });
  }

  Future<void> updateLiquidacionAndRecalculate(String pin, String bancoId, String fecha, String seccion, double nuevaLiq, {String? loteria}) async {
    final db = await database;
    final String cleanLot = (loteria ?? 'FLORIDA').trim().toUpperCase();
    await db.transaction((txn) async {
      await txn.update('partes', {'liquidacion': nuevaLiq}, 
        where: "banco_id = ? AND listero_pin = ? AND fecha = ? AND seccion = ? AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))", 
        whereArgs: [bancoId.trim(), pin.trim(), fecha.trim(), seccion.trim(), cleanLot, cleanLot]);
      await _fullRecalculate(txn, pin.trim(), bancoId.trim(), loteria: cleanLot);
    });
  }

  Future<void> updateParteMetricsAndRecalculate(String pin, String bancoId, String fecha, String seccion, Map<String, double> metrics, {String? loteria}) async {
    final db = await database;
    final String cleanLot = (loteria ?? 'FLORIDA').trim().toUpperCase();
    await db.transaction((txn) async {
      await txn.update('partes', metrics, 
        where: "banco_id = ? AND listero_pin = ? AND fecha = ? AND seccion = ? AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))", 
        whereArgs: [bancoId.trim(), pin.trim(), fecha.trim(), seccion.trim(), cleanLot, cleanLot]);
      await _fullRecalculate(txn, pin.trim(), bancoId.trim(), loteria: cleanLot);
    });
  }

  Future<void> _fullRecalculate(Transaction txn, String pin, String bancoId, {String? loteria}) async {
    // Recálculo unificado continuo a través de la secuencia cronológica de los 5 sorteos diarios
    List<Map<String, dynamic>> partes = await txn.query(
      'partes', 
      where: "banco_id = ? AND listero_pin = ?", 
      orderBy: "fecha ASC, (CASE WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'GEORGIA' AND UPPER(seccion) = 'MIDDAY') THEN 1 WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'FLORIDA' AND UPPER(seccion) = 'DIA') THEN 2 WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'GEORGIA' AND UPPER(seccion) = 'EVENING') THEN 3 WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'FLORIDA' AND UPPER(seccion) = 'NOCHE') THEN 4 WHEN (UPPER(COALESCE(loteria,'FLORIDA')) = 'GEORGIA' AND UPPER(seccion) = 'NIGHT') THEN 5 ELSE 0 END) ASC",
      whereArgs: [bancoId.trim(), pin.trim()]
    );

    if (partes.isEmpty) return;

    double runningFondo = (partes[0]['fondo_anterior'] as num?)?.toDouble() ?? 0.0;

    for (int i = 0; i < partes.length; i++) {
      var p = partes[i];
      if (i == 0) {
        runningFondo = (p['fondo_anterior'] as num?)?.toDouble() ?? 0.0;
      }

      double totalDia = (p['total_dia'] as num?)?.toDouble() ?? 0.0;
      double liq = (p['liquidacion'] as num?)?.toDouble() ?? 0.0;
      double nuevoSaldoFinal = runningFondo + totalDia - liq;

      await txn.update('partes', {
        'fondo_anterior': runningFondo,
        'saldo_final': nuevoSaldoFinal
      }, where: 'id = ?', whereArgs: [p['id']]);

      runningFondo = nuevoSaldoFinal;
    }
  }

  Future<bool> insertNotificacion(String titulo, String mensaje, {String? listeroPin, String? bancoId, int sync = 1, String? uuid, bool esOficial = false}) async {
    final db = await database;
    
    // 1. Limpieza periódica (Aumentada a 7 días para evitar desapariciones prematuras)
    await db.delete('notificaciones', where: "timestamp <= datetime('now', '-7 days')");
    
    // 2. Verificar duplicados por UUID si existe
    if (uuid != null && uuid.isNotEmpty) {
      final List<Map<String, dynamic>> existing = await db.query('notificaciones', where: 'uuid = ?', whereArgs: [uuid]);
      if (existing.isNotEmpty) return false;
    }

    final Map<String, dynamic> row = {
      'banco_id': bancoId,
      'listero_pin': listeroPin,
      'titulo': titulo,
      'mensaje': mensaje,
      'fecha': DateTime.now().toString().substring(0, 16),
      'visto': 0,
      'es_oficial': esOficial ? 1 : 0,
      'sync': sync,
      'uuid': uuid ?? _generateUuid()
    };
    
    await db.insert('notificaciones', row);
    _notifySync(sync == 0 ? -999 : -1);
    return true;
  }

  Future<List<Map<String, dynamic>>> getNotificaciones({String? listeroPin, String? bancoId, bool all = false}) async {
    final db = await database;
    await db.delete('notificaciones', where: "timestamp <= datetime('now', '-7 days')");
    
    String whereClause = '';
    List<dynamic> whereArgs = [];

    if (bancoId != null) {
      whereClause = "(banco_id = ? OR banco_id = 'SYSTEM')";
      whereArgs.add(bancoId);
    } else {
      whereClause = "banco_id IS NULL OR banco_id = 'SYSTEM'";
    }

    if (all) {
      return await db.query('notificaciones', where: whereClause, whereArgs: whereArgs, orderBy: 'id DESC');
    }

    if (listeroPin == null) {
      whereClause += ' AND listero_pin IS NULL';
    } else {
      whereClause += ' AND (listero_pin IS NULL OR listero_pin = ?)';
      whereArgs.add(listeroPin);
    }

    return await db.query('notificaciones', where: whereClause, whereArgs: whereArgs, orderBy: 'id DESC');
  }

  Future<void> deleteNotificacion(int id, {required String bancoId, int sync = 1}) async {
    final db = await database;
    if (sync == 1) {
      await _logDeletion('notificaciones', id.toString(), bancoId);
    }
    await db.delete('notificaciones', where: 'id = ?', whereArgs: [id]);
    _notifySync(sync == 0 ? -999 : -1);
  }

  Future<void> deleteNotificacionByUuid(String uuid, {String? bancoId, int sync = 1}) async {
    final db = await database;
    if (sync == 1 && bancoId != null) {
      await _logDeletion('notificaciones', uuid, bancoId);
    }
    await db.delete('notificaciones', where: 'uuid = ?', whereArgs: [uuid]);
    _notifySync(sync == 0 ? -999 : -1);
  }

  Future<void> marcarNotificacionVista(int id) async {
    final db = await database;
    debugPrint("[DB] Marcando notificación $id como VISTA...");
    await db.update('notificaciones', {'visto': 1, 'sync': 1}, where: 'id = ?', whereArgs: [id]);
    _notifySync(-1); // Disparar subida inmediata del estado de lectura
  }

  Future<bool> saveLimite(Map<String, dynamic> data, {int sync = 1}) async {
    final db = await database;
    final Map<String, dynamic> row = Map.from(data);
    
    final bancoId = row['banco_id'];
    final tipo = row['tipo'];
    final numero = row['numero'];
    final destino = row['destino'];
    final seccion = row['seccion'];
    final loteria = (row['loteria']?.toString() ?? 'FLORIDA').trim().toUpperCase();
    final uuid = row['uuid'];

    row['loteria'] = loteria;

    // 1. Verificar si el UUID ya existe
    if (uuid != null && uuid.toString().isNotEmpty) {
      final List<Map<String, dynamic>> existing = await db.query('limites', where: 'uuid = ?', whereArgs: [uuid]);
      if (existing.isNotEmpty) return false;
    }

    // 2. LIMPIEZA DE DUPLICADOS: Eliminar regla previa equivalente para evitar ruido
    await db.delete('limites', 
      where: "banco_id = ? AND tipo = ? AND numero = ? AND destino = ? AND seccion = ? AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))",
      whereArgs: [bancoId, tipo, numero, destino, seccion, loteria, loteria]
    );

    // 3. ASEGURAR IDENTIDAD: Generar UUID si no existe
    if (row['uuid'] == null || row['uuid'].toString().isEmpty) {
      row['uuid'] = _generateUuid();
    }
    
    row['sync'] = sync;
    
    await db.insert('limites', row);
    _notifySync(sync == 0 ? -999 : -1); 
    return true;
  }

  Future<List<Map<String, dynamic>>> getLimites({required String bancoId, String? loteria}) async {
    final db = await database;
    String whereClause = 'banco_id = ?';
    List<dynamic> whereArgs = [bancoId.trim()];

    if (loteria != null && loteria.isNotEmpty) {
      whereClause += " AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))";
      whereArgs.add(loteria.trim().toUpperCase());
      whereArgs.add(loteria.trim().toUpperCase());
    }

    return await db.query('limites', 
      where: whereClause, 
      whereArgs: whereArgs, 
      orderBy: 'id DESC'
    );
  }

  Future<void> deleteLimite(int id, {int sync = 1}) async {
    final db = await database;
    final data = await db.query('limites', columns: ['banco_id', 'uuid'], where: 'id = ?', whereArgs: [id]);
    if (data.isNotEmpty) {
      if (sync == 1) await _logDeletion('limites', data.first['uuid'] as String, data.first['banco_id'] as String);
    }
    await db.delete('limites', where: 'id = ?', whereArgs: [id]);
    _notifySync(sync == 0 ? -999 : -1);
  }

  Future<void> deleteLimiteByUuid(String uuid, {int sync = 1}) async {
    final db = await database;
    await db.delete('limites', where: 'uuid = ?', whereArgs: [uuid]);
    _notifySync(sync == 0 ? -999 : -1);
  }

  Future<void> deletePlan(String nombre, String bancoId, {String? loteria, int sync = 1}) async {
    final db = await database;
    final String cleanLot = (loteria ?? 'FLORIDA').trim().toUpperCase();
    if (sync == 1) await _logDeletion('planes', "${nombre.trim()}|$cleanLot", bancoId.trim());
    await db.delete('planes', 
      where: "nombre = ? AND banco_id = ? AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))", 
      whereArgs: [nombre.trim(), bancoId.trim(), cleanLot, cleanLot]
    );
    _notifySync(sync == 0 ? -999 : -1);
  }

  Future<void> upsertListero(Map<String, dynamic> data) async {
    final db = await database;
    final bancoId = data['banco_id'];
    final pin = data['pin'];
    
    // RESTRICCIÓN DE SEGURIDAD: Un Listero no puede tener el PIN de un Banco o Master Key.
    if (pin.toUpperCase() == "B8080" || pin == "4608pr") {
      throw Exception("PIN RESERVADO: Este código no puede ser usado para una lista.");
    }

    bool isBankPin = await isBankRegistered(pin);
    if (isBankPin) {
      throw Exception("PIN NO VÁLIDO: Este código está reservado para uso bancario.");
    }
    
    // Check if listero already exists for this bank
    final existing = await getListeroByPin(pin, bancoId);
    
    if (existing == null) {
      // It's a new listero, check the 100 limit
      final countResult = await db.rawQuery('SELECT COUNT(*) as total FROM listeros WHERE banco_id = ?', [bancoId]);
      int count = Sqflite.firstIntValue(countResult) ?? 0;
      if (count >= 100) {
        throw Exception("Límite alcanzado: Un banco no puede tener más de 100 listas.");
      }
    }

    final row = {
      'banco_id': bancoId.trim(),
      'pin': pin.trim(),
      'nombre': data['nombre'],
      'plan': data['plan'],
      'loterias': data['loterias'] ?? 'AMBAS',
      'bloqueado': (data['bloqueado'] == true || data['bloqueado'] == 1) ? 1 : 0,
      'vinculado': (data['vinculado'] == true || data['vinculado'] == 1) ? 1 : 0,
      'device_id': data['device_id'],
      'sync': data['sync'] ?? 1
    };
    await db.insert('listeros', row, conflictAlgorithm: ConflictAlgorithm.replace);
    _notifySync(data['sync'] == 0 ? -999 : -1);
  }

  Future<List<Map<String, dynamic>>> getListeros({required String bancoId}) async {
    final db = await database;
    return await db.query('listeros', where: 'banco_id = ?', whereArgs: [bancoId]);
  }

  Future<Map<String, dynamic>?> getListeroByPin(String pin, String bancoId) async {
    final db = await database;
    final res = await db.query('listeros', where: 'pin = ? AND banco_id = ?', whereArgs: [pin.trim(), bancoId.trim()], limit: 1);
    return res.isNotEmpty ? res.first : null;
  }

  Future<Map<String, dynamic>?> findListeroGlobally(String pin) async {
    final db = await database;
    final res = await db.query('listeros', where: 'pin = ?', whereArgs: [pin.trim()], limit: 1);
    if (res.isNotEmpty) {
      return {'listero': res.first, 'banco_id': res.first['banco_id']};
    }
    return null;
  }

  Future<void> deleteListero(String pin, String bancoId, {int sync = 1}) async {
    final db = await database;
    if (sync == 1) await _logDeletion('listeros', pin.trim(), bancoId.trim());
    await db.delete('listeros', where: 'pin = ? AND banco_id = ?', whereArgs: [pin.trim(), bancoId.trim()]);
    _notifySync(sync == 0 ? -999 : -1);
  }

  Future<void> deleteBankLocalData(String bancoId) async {
    final db = await database;
    final id = bancoId.trim();
    final tables = ['jugadas', 'resultados', 'partes', 'notificaciones', 'limites', 'listeros', 'planes', 'bank_colors'];
    
    await db.transaction((txn) async {
      for (var table in tables) {
        await txn.delete(table, where: 'banco_id = ?', whereArgs: [id]);
      }
      // Limpiar también el registro de borrados para ese banco
      await txn.delete('sync_deletions', where: 'banco_id = ?', whereArgs: [id]);
    });
    _notifySync(-999);
  }

  Future<void> upsertPlan(String nombre, Map<String, dynamic> config, {required String bancoId, String loteria = 'FLORIDA', int sync = 1}) async {
    final db = await database;
    String configJson = json.encode(config);
    final String cleanLot = loteria.trim().toUpperCase();

    // Eliminar plan existente para esta lotería previa
    await db.delete('planes',
      where: "nombre = ? AND banco_id = ? AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))",
      whereArgs: [nombre.trim(), bancoId.trim(), cleanLot, cleanLot]
    );

    final row = {
      'banco_id': bancoId.trim(),
      'nombre': nombre.trim(),
      'config': configJson,
      'loteria': cleanLot,
      'sync': sync
    };
    await db.insert('planes', row, conflictAlgorithm: ConflictAlgorithm.replace);
    _notifySync(sync == 0 ? -999 : -1);
  }

  Future<Map<String, dynamic>> getPlanes({required String bancoId, String? loteria}) async {
    final db = await database;
    String whereClause = 'banco_id = ?';
    List<dynamic> whereArgs = [bancoId.trim()];

    if (loteria != null && loteria.isNotEmpty) {
      whereClause += " AND (loteria = ? OR (loteria IS NULL AND ? = 'FLORIDA'))";
      whereArgs.add(loteria.trim().toUpperCase());
      whereArgs.add(loteria.trim().toUpperCase());
    }

    final List<Map<String, dynamic>> res = await db.query('planes', where: whereClause, whereArgs: whereArgs);
    if (res.isEmpty) {
      final String targetLot = (loteria ?? 'FLORIDA').trim().toUpperCase();
      await upsertPlan("PLAN1", _defaultPlanConfig, bancoId: bancoId.trim(), loteria: targetLot);
      return {"PLAN1": _defaultPlanConfig};
    }
    Map<String, dynamic> planes = {};
    for (var row in res) {
      planes[row['nombre']] = json.decode(row['config']);
    }
    return planes;
  }

  /// Verifica si un banco_id ya tiene entorno inicializado.
  Future<bool> isBankRegistered(String bancoId) async {
    final db = await database;
    final res = await db.query('planes', where: 'banco_id = ?', whereArgs: [bancoId.trim()], limit: 1);
    return res.isNotEmpty;
  }

  Future<void> setBankColor(String bancoId, String colorHex, {int sync = 1}) async {
    final db = await database;
    String cleanColor = colorHex.replaceAll('#', '');
    String finalColor = '#$cleanColor';
    
    await db.insert('bank_colors', {
      'banco_id': bancoId.trim(), 
      'color_hex': finalColor,
      'sync': sync
    }, 
      conflictAlgorithm: ConflictAlgorithm.replace);
    _notifySync(sync == 0 ? -999 : -1);
  }

  Future<String?> getBankColor(String bancoId) async {
    final db = await database;
    final res = await db.query('bank_colors', where: 'banco_id = ?', whereArgs: [bancoId.trim()]);
    return res.isNotEmpty ? res.first['color_hex'] as String : null;
  }

  Future<void> setBankLoterias(String bancoId, String loterias, {int sync = 1}) async {
    final db = await database;
    final String cleanLoterias = loterias.trim().toUpperCase();
    final String bId = bancoId.trim();

    final existing = await db.query('bank_colors', where: 'banco_id = ?', whereArgs: [bId]);
    if (existing.isNotEmpty) {
      await db.update(
        'bank_colors',
        {
          'loterias': cleanLoterias,
          'sync': sync,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'banco_id = ?',
        whereArgs: [bId],
      );
    } else {
      await db.insert(
        'bank_colors',
        {
          'banco_id': bId,
          'color_hex': '#1A237E',
          'loterias': cleanLoterias,
          'sync': sync,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    _notifySync(sync == 0 ? -999 : -1);
  }

  Future<String> getBankLoterias(String bancoId) async {
    final db = await database;
    final res = await db.query('bank_colors', where: 'banco_id = ?', whereArgs: [bancoId.trim()]);
    if (res.isNotEmpty && res.first['loterias'] != null) {
      final String val = (res.first['loterias'] as String).trim().toUpperCase();
      if (val.isNotEmpty) return val;
    }
    return "AMBAS";
  }

  Future<List<String>> getUsedColors() async {
    final db = await database;
    final res = await db.query('bank_colors', columns: ['color_hex']);
    return res.map((e) => e['color_hex'] as String).toList();
  }

  Future<List<String>> getAllBanks() async {
    final db = await database;
    final res = await db.rawQuery('SELECT DISTINCT banco_id FROM planes UNION SELECT DISTINCT banco_id FROM listeros UNION SELECT DISTINCT banco_id FROM bank_colors');
    return res
        .map((e) => e['banco_id'] as String? ?? "")
        .where((e) => e.isNotEmpty && e != "UNKNOWN" && e != "SYSTEM")
        .toList();
  }

  Future<void> migrateFromPrefs(dynamic prefs, String bancoId) async {
    try {
      if (prefs.getBool("migration_v17_done_$bancoId") == true) return;
      
      final String? listerosJson = prefs.getString("banco_listeros_data");
      if (listerosJson != null) {
        final List<dynamic> list = json.decode(listerosJson);
        for (var l in list) {
          final Map<String, dynamic> data = Map.from(l);
          data['banco_id'] = bancoId;
          await upsertListero(data);
        }
      }

      final String? planesJson = prefs.getString("banco_planes_data");
      if (planesJson != null) {
        final Map<String, dynamic> data = json.decode(planesJson);
        for (var entry in data.entries) {
          await upsertPlan(entry.key, Map<String, dynamic>.from(entry.value), bancoId: bancoId);
        }
      }

      final String? limitesJson = prefs.getString("banco_limites_pago_v4");
      if (limitesJson != null) {
        final List<dynamic> list = json.decode(limitesJson);
        for (var l in list) {
          final Map<String, dynamic> data = Map.from(l);
          data['banco_id'] = bancoId;
          await saveLimite(data);
        }
      }
      
      await prefs.setBool("migration_v17_done_$bancoId", true);
    } catch (e) {
      debugPrint("⛔ ERROR CRÍTICO EN MIGRACIÓN: $e");
    }
  }

  Future<void> syncPendingData() async {
    // No-op
  }

  /// Reemplaza las jugadas de una sección con el bloque consolidado de la nube (Paridad Total)
  Future<void> syncJugadasBatch(String pin, String fecha, String seccion, String bancoId, List<Map<String, dynamic>> rows, {String? loteria}) async {
    if (rows.isEmpty) return;
    final db = await database;
    final String cleanLot = (loteria ?? 'FLORIDA').trim().toUpperCase();
    try {
      await db.transaction((txn) async {
        // 0. VERIFICACIÓN DE SOBERANÍA LOCAL:
        final sectionDirtyEntry = await txn.query('sync_deletions',
          where: "tabla = 'jugadas' AND remoto_id = ? AND banco_id = ?",
          whereArgs: ["SECTION:$pin|$fecha|$seccion", bancoId],
          limit: 1
        );
        
        final hasPendingLocal = await txn.query('jugadas',
          where: 'banco_id = ? AND listero_pin = ? AND fecha = ? AND seccion = ? AND (loteria = ? OR (loteria IS NULL AND ? = \'FLORIDA\')) AND sync = 1',
          whereArgs: [bancoId, pin, fecha, seccion, cleanLot, cleanLot],
          limit: 1
        );

        if (sectionDirtyEntry.isNotEmpty || hasPendingLocal.isNotEmpty) {
           debugPrint("[DB_SYNC] Sección $pin ($seccion - $cleanLot) tiene cambios locales pendientes. Saltando reconciliación.");
           return;
        }

        final receivedUuuids = rows.map((e) => e['uuid']?.toString()).whereType<String>().toList();
        
        if (receivedUuuids.isNotEmpty) {
          String placeholders = receivedUuuids.map((_) => '?').join(',');
          int deleted = await txn.delete('jugadas', 
            where: 'banco_id = ? AND listero_pin = ? AND fecha = ? AND seccion = ? AND (loteria = ? OR (loteria IS NULL AND ? = \'FLORIDA\')) AND sync = 0 AND uuid NOT IN ($placeholders)',
            whereArgs: [bancoId, pin, fecha, seccion, cleanLot, cleanLot, ...receivedUuuids]
          );
          if (deleted > 0) debugPrint("[DB_SYNC] Borradas $deleted jugadas obsoletas para $pin ($seccion - $cleanLot)");
        }

        int inserted = 0;
        for (var row in rows) {
          final String? uuid = row['uuid'];
          if (uuid == null) continue;

          final existing = await txn.query('jugadas', 
            columns: ['id'], 
            where: 'uuid = ?', 
            whereArgs: [uuid], 
            limit: 1
          );

          if (existing.isEmpty) {
            final Map<String, dynamic> cleanRow = Map.from(row);
            cleanRow['loteria'] = cleanLot;
            cleanRow['banco_id'] = bancoId;
            int id = await txn.insert('jugadas', cleanRow);
            if (id > 0) inserted++;
          }
        }
        if (inserted > 0) debugPrint("[DB_SYNC] Insertadas $inserted jugadas nuevas para $pin ($seccion - $cleanLot)");
      });
      _notifySync(-999);
    } catch (e) {
      debugPrint("[DB_SYNC_ERR] Error en transacción de lote: $e");
    }
  }

  /// Inserta jugadas descargadas de la nube (evitando duplicados por UUID)
  Future<void> insertJugadasFromCloud(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      for (var row in rows) {
        final String? uuid = row['uuid'];
        if (uuid == null) continue;
        
        final existing = await txn.query('jugadas', where: 'uuid = ?', whereArgs: [uuid], limit: 1);
        if (existing.isEmpty) {
          await txn.insert('jugadas', row);
        }
      }
    });
    _notifySync(-999);
  }
}
