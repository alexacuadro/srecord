import 'package:flutter/material.dart';

/// Servicio de Escaneo de Pantalla y Adaptabilidad Anti-Desbordamientos
class ResponsiveUiService {
  static final ResponsiveUiService _instance = ResponsiveUiService._internal();
  factory ResponsiveUiService() => _instance;
  ResponsiveUiService._internal();

  double screenWidth = 360.0;
  double screenHeight = 800.0;
  double devicePixelRatio = 1.0;
  bool isSmallScreen = false;
  bool isTablet = false;

  /// Escanea las métricas físicas del dispositivo al iniciar o cambiar orientación
  void scanDeviceScreen(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    screenWidth = mediaQuery.size.width;
    screenHeight = mediaQuery.size.height;
    devicePixelRatio = mediaQuery.devicePixelRatio;
    isSmallScreen = screenWidth < 380;
    isTablet = screenWidth >= 600;
  }

  /// Envuelve un conjunto de widgets en una fila adaptativa con scroll horizontal si es necesario
  static Widget safeRow({
    required List<Widget> children,
    MainAxisAlignment mainAxisAlignment = MainAxisAlignment.start,
    CrossAxisAlignment crossAxisAlignment = CrossAxisAlignment.center,
  }) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        mainAxisAlignment: mainAxisAlignment,
        crossAxisAlignment: crossAxisAlignment,
        children: children,
      ),
    );
  }

  /// Escala proporcionalmente el tamaño según la densidad del dispositivo
  double scale(double baseSize) {
    if (isSmallScreen) return baseSize * 0.88;
    if (isTablet) return baseSize * 1.15;
    return baseSize;
  }
}
