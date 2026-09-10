import 'dart:async' as async;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:srecord/services/database_helper.dart';

enum ConnectionStatus { conectado, debil, sinConexion }

class ConnectivityService {
  static final ConnectivityService _instance = ConnectivityService._internal();
  factory ConnectivityService() => _instance;
  ConnectivityService._internal();

  final ValueNotifier<ConnectionStatus> status = ValueNotifier(ConnectionStatus.conectado);
  async.Timer? _timer;

  void startMonitoring() {
    _timer?.cancel();
    _checkConnection();
    _timer = async.Timer.periodic(const Duration(seconds: 10), (timer) => _checkConnection());
  }

  Future<void> _checkConnection() async {
    try {
      final stopwatch = Stopwatch()..start();
      // Verificación ligera de conectividad de red general
      final result = await InternetAddress.lookup('google.com').timeout(const Duration(seconds: 5));
      stopwatch.stop();

      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        ConnectionStatus oldStatus = status.value;
        if (stopwatch.elapsedMilliseconds > 1500) {
          status.value = ConnectionStatus.debil;
        } else {
          status.value = ConnectionStatus.conectado;
        }
        
        // Si recuperamos conexión, sincronizar datos pendientes
        if (oldStatus == ConnectionStatus.sinConexion && (status.value == ConnectionStatus.conectado || status.value == ConnectionStatus.debil)) {
          DatabaseHelper().syncPendingData();
        }
      } else {
        status.value = ConnectionStatus.sinConexion;
      }
    } catch (_) {
      status.value = ConnectionStatus.sinConexion;
    }
  }

  void stopMonitoring() {
    _timer?.cancel();
  }
}
