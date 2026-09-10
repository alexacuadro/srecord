import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:srecord/services/rent_service.dart';

class RentConfigScreen extends StatefulWidget {
  const RentConfigScreen({super.key});

  @override
  State<RentConfigScreen> createState() => _RentConfigScreenState();
}

class _RentConfigScreenState extends State<RentConfigScreen> {
  final RentService _rentService = RentService();
  double _monto = 100.0;
  RentFrequency _frecuencia = RentFrequency.quincenalDomingo;
  DateTime _fechaInicio = DateTime.now();
  String? _ultimoPago;
  List<Map<String, dynamic>> _schedule = [];
  bool _isLoading = true;

  final TextEditingController _montoController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final m = await _rentService.getMonto();
    final f = await _rentService.getFrecuencia();
    final fi = await _rentService.getFechaInicio();
    final up = await _rentService.getUltimoPagoFecha();
    final sch = await _rentService.getAnnualSchedule();

    if (mounted) {
      setState(() {
        _monto = m;
        _montoController.text = m.round().toString();
        _frecuencia = f;
        _fechaInicio = fi;
        _ultimoPago = up;
        _schedule = sch;
        _isLoading = false;
      });
    }
  }

  Future<void> _selectFechaInicio() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _fechaInicio,
      firstDate: DateTime(2024),
      lastDate: DateTime(2030),
      helpText: "SELECCIONE PRIMER DOMINGO PACTADO",
    );
    if (picked != null && picked != _fechaInicio) {
      await _rentService.setFechaInicio(picked);
      _loadConfig();
    }
  }

  Future<void> _togglePago(DateTime date, bool currentPaid) async {
    if (currentPaid) {
      await _rentService.cancelarPago();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Pago cancelado/revertido.")));
      }
    } else {
      await _rentService.registrarPago(date);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("¡Renta de \$${_monto.round()} USD registrada como LIQUIDADA!"),
          backgroundColor: Colors.green,
        ));
      }
    }
    _loadConfig();
  }

  @override
  void dispose() {
    _montoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.alarm_on, color: Colors.amberAccent),
            SizedBox(width: 8),
            Text("RENTAS Y COBROS DEL BANCO", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildConfigCard(),
                const SizedBox(height: 20),
                _sectionTitle("CALENDARIO ANUAL DE COBROS PACTADOS (${DateTime.now().year})"),
                const SizedBox(height: 8),
                _buildScheduleList(),
              ],
            ),
    );
  }

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.blue.shade900, letterSpacing: 1),
    );
  }

  Widget _buildConfigCard() {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: Start,
          children: [
            Row(
              children: [
                Icon(Icons.monetization_on, color: Colors.green.shade700, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Pacto de Renta de App", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Colors.blue.shade900)),
                      const Text("Configuración de liquidez y cobro del servicio", style: TextStyle(fontSize: 10, color: Colors.grey)),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),

            // Campo Monto USD
            Row(
              children: [
                const Expanded(child: Text("Monto Pactado (USD):", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _montoController,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      prefixText: "\$ ",
                      suffixText: " USD",
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onSubmitted: (val) async {
                      final parsed = double.tryParse(val) ?? 100.0;
                      await _rentService.setMonto(parsed);
                      _loadConfig();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Frecuencia
            Row(
              children: [
                const Expanded(child: Text("Frecuencia de Pago:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                DropdownButton<RentFrequency>(
                  value: _frecuencia,
                  onChanged: (val) async {
                    if (val != null) {
                      await _rentService.setFrecuencia(val);
                      _loadConfig();
                    }
                  },
                  items: const [
                    DropdownMenuItem(value: RentFrequency.quincenalDomingo, child: Text("Un Domingo sí, otro no (Quincenal)")),
                    DropdownMenuItem(value: RentFrequency.semanalDomingo, child: Text("Todos los Domingos (Semanal)")),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Primer Domingo Pactado
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Primer Domingo Pactado:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    Text(DateFormat('EEEE d MMMM yyyy', 'es').format(_fechaInicio), style: const TextStyle(fontSize: 11, color: Colors.blueGrey)),
                  ],
                ),
                OutlinedButton.icon(
                  onPressed: _selectFechaInicio,
                  icon: const Icon(Icons.calendar_month, size: 18),
                  label: const Text("CAMBIAR"),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScheduleList() {
    if (_schedule.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text("No se han generado fechas pactadas para este año."),
        ),
      );
    }

    return Column(
      children: _schedule.map((item) {
        final DateTime date = item['date'];
        final String status = item['status'];
        final bool isPaid = item['isPaid'];
        final String formatted = item['formatted'];

        Color badgeColor;
        String badgeText;
        IconData badgeIcon;

        switch (status) {
          case "SALDADO":
            badgeColor = Colors.green;
            badgeText = "🟢 SALDADO";
            badgeIcon = Icons.check_circle;
            break;
          case "COBRO_HOY":
            badgeColor = Colors.amber.shade800;
            badgeText = "🟡 COBRO HOY (\$${_monto.round()} USD)";
            badgeIcon = Icons.alarm;
            break;
          case "VENCIDO":
            badgeColor = Colors.red;
            badgeText = "🔴 PENDIENTE / VENCIDO";
            badgeIcon = Icons.warning;
            break;
          default:
            badgeColor = Colors.grey.shade600;
            badgeText = "⚪ FUTURO";
            badgeIcon = Icons.event;
        }

        return Card(
          elevation: status == "COBRO_HOY" ? 4 : 1,
          color: status == "COBRO_HOY" ? Colors.amber.shade50 : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: status == "COBRO_HOY" ? BorderSide(color: Colors.amber.shade700, width: 2) : BorderSide.none,
          ),
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: Icon(badgeIcon, color: badgeColor, size: 28),
            title: Text(formatted, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            subtitle: Text("Monto Pactado: \$${_monto.round()} USD", style: const TextStyle(fontSize: 11)),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: badgeColor.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                  child: Text(badgeText, style: TextStyle(color: badgeColor, fontWeight: FontWeight.w900, fontSize: 10)),
                ),
              ],
            ),
            onTap: () => _togglePago(date, isPaid),
          ),
        );
      }).toList(),
    );
  }
}
