import 'package:estudiante_app/utils/metricas_enfoque.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final DateTime inicio = DateTime.utc(2026, 11, 17, 13, 0, 0);
  DateTime min(double m) => inicio.add(Duration(milliseconds: (m * 60000).round()));

  test('sin salidas: 100 % de concentración y racha = toda la clase', () {
    final MetricasEnfoque m = MetricasEnfoque.calcular(
      [EventoClase('ingreso', min(0))],
      min(30),
    );
    expect(m.segundosFuera, 0);
    expect(m.concentracion, 100);
    expect(m.rachaActual, 30 * 60);
    expect(m.puntosEnfoque, 30); // +1 por minuto
    expect(m.insignia, '🏆 Enfoque de Acero');
  });

  test('salida con falta grave: suma el tiempo fuera y descuenta puntos', () {
    final MetricasEnfoque m = MetricasEnfoque.calcular(
      [
        EventoClase('ingreso', min(0)),
        EventoClase('salio_de_app:TikTok', min(10)),
        EventoClase('cambio_app:Instagram', min(10 + 5 / 60)),
        EventoClase('falta_grave', min(10 + 10 / 60)),
        EventoClase('regreso_tarde:60', min(11)),
      ],
      min(30),
    );
    expect(m.segundosFuera, 60);
    expect(m.salidas, 1); // cambiar de app estando fuera no es otra salida
    expect(m.salidasLargas, 1);
    expect(m.faltasGraves, 1);
    expect(m.distracciones, 4); // salió + cambió + falta grave (×2)
    expect(m.mejorRacha, 19 * 60); // de 11 a 30 min
    expect(m.rachaActual, 19 * 60);
    // 29 min concentrado − 5 (salida) − 10 (falta grave)
    expect(m.puntosEnfoque, 29 - 5 - 10);
  });

  test('bloquear el celular no cuenta como tiempo fuera', () {
    final MetricasEnfoque m = MetricasEnfoque.calcular(
      [
        EventoClase('ingreso', min(0)),
        EventoClase('pantalla_bloqueada', min(5)),
        EventoClase('regreso', min(8)),
      ],
      min(20),
    );
    expect(m.segundosFuera, 0);
    expect(m.salidas, 0);
    expect(m.concentracion, 100);
  });

  test('si sigue fuera, el tiempo cuenta hasta ahora y la racha es 0', () {
    final MetricasEnfoque m = MetricasEnfoque.calcular(
      [
        EventoClase('ingreso', min(0)),
        EventoClase('salio_de_app:YouTube', min(9.5)),
      ],
      min(10),
    );
    expect(m.estaFuera, isTrue);
    expect(m.segundosFuera, 30);
    expect(m.rachaActual, 0);
    expect(m.concentracion, 95);
  });

  test('ver notificaciones reinicia la racha y resta 2 puntos', () {
    final MetricasEnfoque m = MetricasEnfoque.calcular(
      [
        EventoClase('ingreso', min(0)),
        EventoClase('vio_notificaciones', min(12)),
      ],
      min(15),
    );
    expect(m.mejorRacha, 12 * 60);
    expect(m.rachaActual, 3 * 60);
    expect(m.puntosEnfoque, 15 - 2);
  });

  test('formatearDuracion', () {
    expect(formatearDuracion(45), '45 s');
    expect(formatearDuracion(80), '1 min 20 s');
    expect(formatearDuracion(120), '2 min');
    expect(formatearDuracion(3900), '1 h 5 min');
  });
}
