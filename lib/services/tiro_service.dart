import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srecord/services/database_helper.dart';

class TiroService {
  static final TiroService _instance = TiroService._internal();
  factory TiroService() => _instance;
  TiroService._internal();

  final DatabaseHelper _db = DatabaseHelper();
  
  final ValueNotifier<int> version = ValueNotifier(0);
  final ValueNotifier<int> versionLimites = ValueNotifier(0);
  
  Map<String, String>? latestTiro;

  Future<void> refreshTiro(String fecha, String seccion, {String? loteria}) async {
    final prefs = await SharedPreferences.getInstance();
    final bancoId = prefs.getString("active_banco_id") ?? "";
    if (bancoId.isEmpty) return;

    final lot = loteria ?? prefs.getString("sync_loteria") ?? "FLORIDA";
    final res = await _db.getResultado(fecha, seccion, bancoId: bancoId, loteria: lot);
    latestTiro = res;
    version.value++;
  }

  void notifyNewTiro(Map<String, String>? res) {
    debugPrint("[TIRO_SERVICE] Notificando nuevo tiro a listeners: ${res != null ? '${res['fecha']} ${res['seccion']}' : 'NULL'}");
    latestTiro = res;
    version.value++;
  }

  void notifyLimitesChanged() {
    versionLimites.value++;
  }
}
