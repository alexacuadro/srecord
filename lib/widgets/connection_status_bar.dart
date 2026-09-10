import 'package:flutter/material.dart';
import 'package:srecord/services/connectivity_service.dart';

class ConnectionStatusBar extends StatelessWidget {
  const ConnectionStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ConnectionStatus>(
      valueListenable: ConnectivityService().status,
      builder: (context, status, _) {
        Color color;
        String text;
        IconData icon;

        switch (status) {
          case ConnectionStatus.conectado:
            color = Colors.greenAccent;
            text = "CONECTADO";
            icon = Icons.wifi_rounded;
            break;
          case ConnectionStatus.debil:
            color = Colors.orangeAccent;
            text = "CONEXIÓN DÉBIL";
            icon = Icons.wifi_2_bar_rounded;
            break;
          case ConnectionStatus.sinConexion:
            color = Colors.redAccent;
            text = "SIN CONEXIÓN";
            icon = Icons.wifi_off_rounded;
            break;
        }

        return Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: 0.6), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 6,
                  offset: const Offset(0, 3),
                )
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                Text(
                  text,
                  style: TextStyle(
                    color: color,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class FloatingConnectionWrapper extends StatelessWidget {
  final Widget child;
  const FloatingConnectionWrapper({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        const Positioned(
          top: 10, // Un poco más arriba para que no tape contenido
          right: 15,
          child: SafeArea(child: ConnectionStatusBar()),
        ),
      ],
    );
  }
}
