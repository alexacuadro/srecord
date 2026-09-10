import 'package:flutter/material.dart';
import 'package:srecord/services/alex_api.dart';
import 'package:srecord/screens/login_screen.dart';
import 'package:srecord/screens/lista_screen.dart';
import 'package:srecord/screens/banco_screen.dart';

class ComunicadosScreen extends StatefulWidget {
  final Map<String, dynamic> comunicado;
  final String userRole;
  const ComunicadosScreen({super.key, required this.comunicado, required this.userRole});

  @override
  State<ComunicadosScreen> createState() => _ComunicadosScreenState();
}

class _ComunicadosScreenState extends State<ComunicadosScreen> {
  bool _isAcknowledging = false;

  Future<void> _onEnterado() async {
    setState(() => _isAcknowledging = true);
    
    final bool isLocal = widget.comunicado['is_local'] == true;
    final success = await Alex().markComunicadoAsRead(widget.comunicado['id'], isLocal: isLocal, fullData: widget.comunicado);
    
    if (success) {
      if (!mounted) return;
      
      // Si podemos hacer pop (viniendo de ListaScreen), lo hacemos.
      // Si no, navegamos según el rol (viniendo de Login/Update).
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
        return;
      }

      Widget nextScreen;
      if (widget.userRole == "BANCO") {
        nextScreen = const BancoScreen();
      } else if (widget.userRole == "LISTERO") {
        nextScreen = const ListaScreen();
      } else {
        nextScreen = const LoginScreen();
      }
      
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => nextScreen));
    } else {
      setState(() => _isAcknowledging = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Error de conexión. Intente de nuevo."), backgroundColor: Colors.red)
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool esNotiOficial = widget.comunicado['es_oficial'] == 1 || widget.comunicado['es_oficial'] == true;
    
    return Scaffold(
      backgroundColor: esNotiOficial ? const Color(0xFFF1F8FF) : const Color(0xFFE3F2FD),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            children: [
              const SizedBox(height: 20),
              Icon(
                esNotiOficial ? Icons.gavel_rounded : Icons.campaign, 
                size: 60, 
                color: const Color(0xFF0D47A1)
              ),
              const SizedBox(height: 10),
              Text(
                esNotiOficial ? "RESOLUCIÓN OFICIAL DEL BANCO" : "COMUNICADO OFICIAL",
                style: TextStyle(
                  fontWeight: FontWeight.w900, 
                  color: Colors.blue.shade900, 
                  letterSpacing: 2.0, 
                  fontSize: 14
                ),
              ),
              const SizedBox(height: 30),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(25),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08), 
                        blurRadius: 20, 
                        offset: const Offset(0, 10)
                      )
                    ],
                    border: Border.all(
                      color: esNotiOficial ? Colors.blue.shade300 : Colors.blue.shade100,
                      width: esNotiOficial ? 2 : 1
                    )
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (esNotiOficial)
                          Center(
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 20),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade900,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: const Text(
                                "IMPORTANCIA: ALTA",
                                style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        Text(
                          widget.comunicado['titulo']?.toString().toUpperCase() ?? "SIN TÍTULO",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w900, 
                            fontSize: 22, 
                            color: Colors.blue.shade900,
                            letterSpacing: -0.5
                          ),
                        ),
                        const SizedBox(height: 15),
                        const Divider(thickness: 1.5),
                        const SizedBox(height: 15),
                        Text(
                          (widget.comunicado['mensaje'] ?? widget.comunicado['contenido'] ?? widget.comunicado['texto'] ?? "").toString(),
                          style: const TextStyle(
                            fontSize: 17, 
                            color: Colors.black87, 
                            height: 1.6,
                            fontWeight: FontWeight.w400
                          ),
                        ),
                        const SizedBox(height: 50),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text("EMITIDO POR:", style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.grey)),
                                Text("GERENCIA DEL BANCO", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.blue.shade800)),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                const Text("FECHA DE EMISIÓN:", style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.grey)),
                                Text(widget.comunicado['fecha'] ?? "", style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black54)),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 30),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.shade50,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  "AL PRESIONAR EL BOTÓN CONFIRMA QUE HA LEÍDO Y ENTENDIDO EL MENSAJE.",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10, color: Colors.blueGrey, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 15),
              SizedBox(
                width: double.infinity,
                height: 65,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0D47A1),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    elevation: 8,
                    shadowColor: Colors.blue.withValues(alpha: 0.5)
                  ),
                  onPressed: _isAcknowledging ? null : _onEnterado,
                  child: _isAcknowledging 
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check_circle_outline),
                          SizedBox(width: 12),
                          Text("CONFIRMAR LECTURA", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 1.5)),
                        ],
                      ),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}
