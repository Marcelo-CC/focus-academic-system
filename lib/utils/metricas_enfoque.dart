// =====================================================================
// MÉTRICAS DE ENFOQUE (tiempo fuera, concentración, rachas y puntos)
// Mismas reglas que el panel docente (index.html → sumarEventoMetricas).
// =====================================================================

/// Un evento de la clase, tal como se guarda en `alertas_inactividad`
/// (p. ej. "salio_de_app:TikTok" → tipo "salio_de_app", detalle "TikTok").
class EventoClase {
  final String tipo;
  final String detalle;
  final DateTime fecha;

  EventoClase(String evento, this.fecha)
      : tipo = evento.split(':').first,
        detalle = evento.contains(':')
            ? evento.substring(evento.indexOf(':') + 1)
            : '';
}

class MetricasEnfoque {
  static const int segundosLimite = 10; // más de 10 s fuera = periodo prolongado
  static const int puntosPorMinuto = 1;
  static const int puntosPorSalida = -5;
  static const int puntosPorFaltaGrave = -10;
  static const int puntosPorNotificacion = -2;

  static const List<String> _salidas = ['salio_de_app', 'cerro_sesion'];
  static const List<String> _retornos = [
    'regreso', 'regreso_tarde', 'ingreso', 'reabrio_app',
    'reingreso_sesion', 'pantalla_bloqueada',
  ];

  int segundosFuera = 0;
  int salidas = 0;
  int salidasLargas = 0;
  int notificaciones = 0;
  int faltasGraves = 0;
  int distracciones = 0; // mismo conteo que la nota del panel
  int rachaActual = 0; // segundos sin salir (0 si está fuera)
  int mejorRacha = 0;
  int ventana = 0; // segundos de clase observados
  bool estaFuera = false;

  int get segundosEnfoque => ventana - segundosFuera;

  int get concentracion =>
      ventana <= 0 ? 100 : ((segundosEnfoque / ventana) * 100).round();

  int get puntosEnfoque =>
      (segundosEnfoque ~/ 60) * puntosPorMinuto +
      salidas * puntosPorSalida +
      faltasGraves * puntosPorFaltaGrave +
      notificaciones * puntosPorNotificacion;

  /// % estimado por distracciones (igual que la nota /20 del panel)
  int get porcentajeNota => (100 - distracciones * 10).clamp(0, 100);

  int get notaVigesimal => ((porcentajeNota / 100) * 20).round();

  String get insignia {
    final int p = porcentajeNota;
    if (p >= 85) return '🏆 Enfoque de Acero';
    if (p >= 70) return '⚡ Atento';
    if (p >= 50) return '⚠️ Distracción Leve';
    return '🚨 En Riesgo';
  }

  /// Calcula las métricas de los [eventos] de una clase hasta [fin].
  static MetricasEnfoque calcular(List<EventoClase> eventos, DateTime fin) {
    final MetricasEnfoque m = MetricasEnfoque();
    if (eventos.isEmpty) return m;

    final List<EventoClase> lista = List<EventoClase>.from(eventos)
      ..sort((a, b) => a.fecha.compareTo(b.fecha));

    final DateTime inicio = lista.first.fecha;
    DateTime? fueraDesde;
    DateTime? rachaDesde = inicio;
    double fuera = 0;
    double mejor = 0;

    double segundos(DateTime a, DateTime b) =>
        b.difference(a).inMilliseconds.clamp(0, 1 << 62) / 1000;

    for (final EventoClase e in lista) {
      final DateTime t = e.fecha.isAfter(fin) ? fin : e.fecha;

      if (['salio_de_app', 'cambio_app', 'vio_notificaciones', 'cerro_sesion']
          .contains(e.tipo)) {
        m.distracciones++;
      }

      if (_salidas.contains(e.tipo) ||
          (e.tipo == 'cambio_app' && fueraDesde == null)) {
        if (fueraDesde == null) {
          fueraDesde = t;
          m.salidas++;
          if (rachaDesde != null) {
            final double r = segundos(rachaDesde, t);
            if (r > mejor) mejor = r;
            rachaDesde = null;
          }
        }
      } else if (_retornos.contains(e.tipo)) {
        if (fueraDesde != null) {
          final double dur = segundos(fueraDesde, t);
          fuera += dur;
          if (dur >= segundosLimite) m.salidasLargas++;
          fueraDesde = null;
        }
        rachaDesde ??= t;
      } else if (e.tipo == 'vio_notificaciones') {
        m.notificaciones++;
        if (rachaDesde != null) {
          final double r = segundos(rachaDesde, t);
          if (r > mejor) mejor = r;
          rachaDesde = t; // la racha vuelve a empezar
        }
      } else if (e.tipo == 'falta_grave') {
        m.faltasGraves++;
        m.distracciones += 2;
      }
    }

    if (fueraDesde != null) {
      final double dur = segundos(fueraDesde, fin);
      fuera += dur;
      if (dur >= segundosLimite) m.salidasLargas++;
      m.estaFuera = true;
    }
    if (rachaDesde != null) {
      final double r = segundos(rachaDesde, fin);
      m.rachaActual = r.floor();
      if (r > mejor) mejor = r;
    }

    m.ventana = segundos(inicio, fin).round().clamp(1, 1 << 31);
    m.segundosFuera = fuera.round().clamp(0, m.ventana);
    m.mejorRacha = mejor.floor();
    return m;
  }
}

/// "1 min 20 s", "45 s", "1 h 5 min"
String formatearDuracion(int segundos) {
  if (segundos < 60) return '$segundos s';
  final int h = segundos ~/ 3600;
  final int min = (segundos % 3600) ~/ 60;
  final int s = segundos % 60;
  if (h > 0) return '$h h $min min';
  return s > 0 ? '$min min $s s' : '$min min';
}
