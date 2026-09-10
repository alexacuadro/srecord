import 'package:flutter/material.dart';
import 'package:srecord/services/recaudacion_service.dart';
import 'package:srecord/widgets/connection_icon.dart';
import 'package:srecord/widgets/loteria_icon.dart';

class WinnersDetailScreen extends StatelessWidget {
  final String listeroNombre;
  final String seccion;
  final String fecha;
  final String loteria;
  final List<dynamic> winners;
  final Color regentColor;

  const WinnersDetailScreen({
    super.key,
    required this.listeroNombre,
    required this.seccion,
    required this.fecha,
    this.loteria = "FLORIDA",
    required this.winners,
    required this.regentColor,
  });

  @override
  Widget build(BuildContext context) {
    String displaySeccion = seccion;
    if (loteria == "GEORGIA") {
      if (seccion == "MIDDAY") displaySeccion = "MAÑANA";
      if (seccion == "EVENING") displaySeccion = "TARDE";
      if (seccion == "NIGHT") displaySeccion = "NOCHE";
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            Text(listeroNombre, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LoteriaIcon(loteria: loteria, size: 12, borderRadius: 2),
                const SizedBox(width: 4),
                Text("$loteria | $displaySeccion", style: const TextStyle(fontSize: 10, letterSpacing: 0.5)),
              ],
            ),
          ],
        ),
        centerTitle: true,
        backgroundColor: regentColor,
        foregroundColor: Colors.white,
        actions: const [
          ConnectionIcon(),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: regentColor.withValues(alpha: 0.05),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("FECHA: $fecha", style: TextStyle(fontWeight: FontWeight.bold, color: regentColor, fontSize: 12)),
                Text("TOTAL PREMIADOS: ${winners.length}", style: TextStyle(fontWeight: FontWeight.bold, color: regentColor, fontSize: 12)),
              ],
            ),
          ),
          Expanded(
            child: winners.isEmpty
                ? _buildEmptyState()
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: winners.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final w = Map<String, dynamic>.from(winners[index]);
                      return _buildWinnerCard(w);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.emoji_events_outlined, size: 80, color: Colors.grey),
          SizedBox(height: 16),
          Text("No hay premios registrados", style: TextStyle(color: Colors.grey, fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildWinnerCard(Map<String, dynamic> w) {
    bool wasCapped = w['wasCapped'] ?? false;
    double premio = (w['premio'] as num?)?.toDouble() ?? 0.0;
    String destino = w['destino'] ?? 'LISTA';
    double limpioMomento = (w['limpioAlMomento'] as num?)?.toDouble() ?? 0.0;
    double maxBet = (w['maxAllowedBet'] as num?)?.toDouble() ?? 0.0;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: wasCapped ? Colors.red.shade300 : Colors.grey.shade200, width: wasCapped ? 1.5 : 1),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 3))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: wasCapped ? Colors.red.shade50 : regentColor.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  wasCapped ? Icons.warning_amber_rounded : Icons.star_rounded,
                  color: wasCapped ? Colors.red.shade700 : regentColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: destino == 'LISTA' ? Colors.blue.shade50 : Colors.orange.shade50,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              "${w['tipo'] ?? 'JUGADA'} | $destino",
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                                color: destino == 'LISTA' ? Colors.blue.shade800 : Colors.orange.shade900,
                              ),
                            ),
                          ),
                          if (wasCapped) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.red.shade100,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                "TOPADO",
                                style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Colors.red.shade900),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      w['valor'] ?? "---",
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: Colors.black87),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (w['detailText'] != null && w['detailText'].toString().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          w['detailText'].toString(),
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: regentColor),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    wasCapped ? "PREMIO TOPADO" : "PREMIO",
                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: wasCapped ? Colors.red.shade800 : Colors.grey.shade600),
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      "\$${RecaudacionService.formatMoney(premio)}",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: wasCapped ? Colors.red.shade700 : Colors.green.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (wasCapped)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: Colors.red.shade800),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      "Protección Nivelada: Limpio Total (\$${RecaudacionService.formatMoney(limpioMomento)}) limita la apuesta permitida a \$${RecaudacionService.formatMoney(maxBet)}.",
                      style: TextStyle(color: Colors.red.shade900, fontSize: 9, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
