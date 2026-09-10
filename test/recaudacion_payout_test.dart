import 'package:flutter_test/flutter_test.dart';
import 'package:srecord/services/recaudacion_service.dart';

void main() {
  group('TEST DE PAGOS Y MULTIPLICADORES POR NÚMEROS REPETIDOS EN TIRO', () {
    final plan = RecaudacionService.defaultConfig;

    test('BOLA: Fijo \$10 + Corrido \$10 (Tiro sin repetidos: 125 - 66 - 80)', () {
      final tiro = {'n1': '125', 'n2': '66', 'n3': '80'};
      // Fijo 25 ($10), Corrido 25 ($10)
      double premio = RecaudacionService.calculatePremio('BOLA', '25(10)(10)', tiro, plan, 'LISTA');
      // Fijo: 10 * 75 = 750. Corrido: (10 * 25) * 1 = 250. Total = 1000.
      expect(premio, equals(1000.0));
    });

    test('BOLA: Corrido \$10 con Número Repetido 2 Veces (Tiro: 125 - 25 - 66)', () {
      final tiro = {'n1': '125', 'n2': '25', 'n3': '66'}; // "25" sale en Fijo y en Corrido 1
      double premio = RecaudacionService.calculatePremio('BOLA', '25(0)(10)', tiro, plan, 'LISTA');
      // Corrido: (10 * 25) * 2 = 500.
      expect(premio, equals(500.0));
    });

    test('BOLA: Fijo \$10 + Corrido \$10 con Número Repetido 2 Veces (Tiro: 125 - 25 - 66)', () {
      final tiro = {'n1': '125', 'n2': '25', 'n3': '66'};
      double premio = RecaudacionService.calculatePremio('BOLA', '25(10)(10)', tiro, plan, 'LISTA');
      // Fijo: 10 * 75 = 750. Corrido: (10 * 25) * 2 = 500. Total = 1250.
      expect(premio, equals(1250.0));
    });

    test('BOLA: Corrido \$10 con Número Repetido 3 Veces (Tiro: 125 - 25 - 25)', () {
      final tiro = {'n1': '125', 'n2': '25', 'n3': '25'}; // "25" sale en las 3 posiciones
      double premio = RecaudacionService.calculatePremio('BOLA', '25(0)(10)', tiro, plan, 'LISTA');
      // Corrido: (10 * 25) * 3 = 750.
      expect(premio, equals(750.0));
    });

    test('PARLÉ SIMPLE: \$1 a Parlé 25-66 (Tiro con 25 Repetido: 125 - 25 - 66)', () {
      final tiro = {'n1': '125', 'n2': '25', 'n3': '66'};
      double premio = RecaudacionService.calculatePremio('PARLE', '25-66(1)', tiro, plan, 'LISTA');
      // "25" está solo 1 vez en la jugada del cliente -> Se cobra 1 vez = $1100
      expect(premio, equals(1100.0));
    });

    test('PARLÉ COMBINADO 9 NÚMEROS SIN REPETIR: \$1 a 05-26-28-25-30-66-24-60-12 (Tiro: 125 - 25 - 66)', () {
      final tiro = {'n1': '125', 'n2': '25', 'n3': '66'};
      double premio = RecaudacionService.calculatePremio('PARLE', '05-26-28-25-30-66-24-60-12(1)', tiro, plan, 'LISTA');
      // La combinación sólo tiene un "25" y un "66" -> Forma 1 pareja 25-66 -> Cobra 1 vez = $1100
      expect(premio, equals(1100.0));
    });

    test('PARLÉ CON NÚMERO REPETIDO EN LA JUGADA: \$1 a 25-25-66 (Tiro: 125 - 25 - 66)', () {
      final tiro = {'n1': '125', 'n2': '25', 'n3': '66'};
      // En la jugada [25, 25, 66] el cliente puso el "25" 2 veces:
      // - Forma pareja 25-25 (1 vez) -> $1100
      // - Forma pareja 25-66 (2 veces, con el 1º y 2º '25') -> $2200
      // Total = $1100 + $2200 = $3300
      double premio = RecaudacionService.calculatePremio('PARLE', '25-25-66(1)', tiro, plan, 'LISTA');
      expect(premio, equals(3300.0));
    });

    test('PARLÉ CON MÚLTIPLES REPETICIONES: \$1 a 50-25-66-80-66-25-90 (Tiro: 125 - 25 - 66)', () {
      final tiro = {'n1': '125', 'n2': '25', 'n3': '66'};
      double premio = RecaudacionService.calculatePremio('PARLE', '50-25-66-80-66-25-90(1)', tiro, plan, 'LISTA');
      // En la jugada [50, 25, 66, 80, 66, 25, 90]:
      // - Pareja 25-25 se arma 1 vez -> $1100
      // - Pareja 25-66 se arma 4 veces (con las combinaciones de los dos '25' y dos '66') -> 4 * $1100 = $4400
      // Total = $1100 + $4400 = $5500
      expect(premio, equals(5500.0));
    });

    test('CENTENA: \$10 a Centena 125 (Tiro: 125 - 25 - 66)', () {
      final tiro = {'n1': '125', 'n2': '25', 'n3': '66'};
      double premio = RecaudacionService.calculatePremio('CENTENA', '125(10)', tiro, plan, 'LISTA');
      // 10 * 500 = 5000.
      expect(premio, equals(5000.0));
    });
  });
}
