import 'package:flutter_test/flutter_test.dart';
import 'package:srecord/services/recaudacion_service.dart';

void main() {
  test('Strict 11x Prize Protection for BOLA with aggregate tickets', () {
    final tiro = {'n1': '122', 'n2': '33', 'n3': '44'};
    final plan = {
      'por_lista_bola': '100', // 100% limpio to simplify
      'pago_lista_fijo': '75',
    };
    
    // Total played in BOLA: $100 (10 tickets of $10)
    // Limpio BOLA: $100 * 1.0 = $100
    // Max bet allowed by rule 11x: 100 / 11 = 9.09
    // Max prize allowed: 9.09 * 75 = 681.81
    
    final jugadas = List.generate(10, (i) => {
      'id': i,
      'tipo': 'BOLA',
      'valor': '22(10)(0)', // $10 fixed, $0 corrido
      'listero_pin': 'TEST',
      'sync': 0,
      'seccion': 'DIA',
      'fecha': '2026-09-01',
      'destino': 'LISTA'
    });

    final totalPremios = RecaudacionService.calculateTotalPremios(jugadas, tiro, plan, 'LISTA');
    expect(totalPremios, closeTo(681.81, 0.01));
  });

  test('Parle Protection (Divisor 110): Capped when Limpio is insufficient', () {
    final tiro = {'n1': '122', 'n2': '33', 'n3': '44'}; // Winning pair: 22-33
    final plan = {
      'por_lista_parlet': '100',
      'pago_lista_parlet': '1100',
    };
    
    // Parlet bet: $200 on 22-33. Limpio = $1900.
    // Required clean for full payment = 200 * 110 = $22,000.
    // Since 1900 < 22000, allowed bet = 1900 / 110 = 17.2727...
    // Prize = 17.2727... * 1100 = $19,000.00
    final jugadaParle = {
      'tipo': 'PARLE',
      'valor': '22-33(200)',
      'listero_pin': 'TEST',
      'sync': 0,
      'seccion': 'DIA',
      'fecha': '2026-09-01',
      'destino': 'LISTA'
    };

    // To simulate $1900 total clean: $1900 played at 100%
    final jugadas = [
      jugadaParle,
      {
        'tipo': 'PARLE',
        'valor': '99-88(1700)', // Not a winner, adds $1700 to clean
        'listero_pin': 'TEST',
        'sync': 0,
        'seccion': 'DIA',
        'fecha': '2026-09-01',
        'destino': 'LISTA'
      }
    ];

    final totalPremios = RecaudacionService.calculateTotalPremios(jugadas, tiro, plan, 'LISTA');
    expect(totalPremios, closeTo(19000.0, 0.01));
  });

  test('Parle Protection (Divisor 110): Paid in FULL when Limpio is sufficient', () {
    final tiro = {'n1': '122', 'n2': '33', 'n3': '44'}; // Winning pair: 22-33
    final plan = {
      'por_lista_parlet': '100',
      'pago_lista_parlet': '1100',
    };
    
    // Parlet bet: $10 on 22-33. Limpio Total = $1900.
    // Required clean for full payment = 10 * 110 = $1,100.
    // Since 1900 >= 1100, bet is paid in FULL: $10 * 1100 = $11,000.00.
    final jugadas = [
      {
        'tipo': 'PARLE',
        'valor': '22-33(10)',
        'listero_pin': 'TEST',
        'sync': 0,
        'seccion': 'DIA',
        'fecha': '2026-09-01',
        'destino': 'LISTA'
      },
      {
        'tipo': 'PARLE',
        'valor': '99-88(1890)', // Adds clean to reach $1900
        'listero_pin': 'TEST',
        'sync': 0,
        'seccion': 'DIA',
        'fecha': '2026-09-01',
        'destino': 'LISTA'
      }
    ];

    final totalPremios = RecaudacionService.calculateTotalPremios(jugadas, tiro, plan, 'LISTA');
    expect(totalPremios, closeTo(11000.0, 0.01));
  });

  test('Centena Protection (Divisor 110): Capped when Limpio is insufficient', () {
    final tiro = {'n1': '122', 'n2': '33', 'n3': '44'}; // Centena win: 122
    final plan = {
      'por_lista_centena': '100',
      'pago_lista_centena': '500',
    };
    
    // Centena bet: $20 on 122. Limpio Total = $1900.
    // Required clean = 20 * 110 = $2200.
    // Since 1900 < 2200, allowed bet = 1900 / 110 = 17.2727...
    // Prize = 17.2727... * 500 = $8636.36
    final jugadas = [
      {
        'tipo': 'CENTENA',
        'valor': '122(20)',
        'listero_pin': 'TEST',
        'sync': 0,
        'seccion': 'DIA',
        'fecha': '2026-09-01',
        'destino': 'LISTA'
      },
      {
        'tipo': 'CENTENA',
        'valor': '999(1880)', // Adds clean
        'listero_pin': 'TEST',
        'sync': 0,
        'seccion': 'DIA',
        'fecha': '2026-09-01',
        'destino': 'LISTA'
      }
    ];

    final totalPremios = RecaudacionService.calculateTotalPremios(jugadas, tiro, plan, 'LISTA');
    expect(totalPremios, closeTo(8636.36, 0.01));
  });
}
