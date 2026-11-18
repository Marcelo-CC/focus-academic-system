import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';

/// Resultado de responder una pregunta relámpago.
class ResultadoPregunta {
  final bool respondida;
  final bool correcta;
  final int puntos;

  const ResultadoPregunta({
    required this.respondida,
    this.correcta = false,
    this.puntos = 0,
  });
}

/// Ventana con la pregunta relámpago, cuenta regresiva y opciones.
/// La respuesta se corrige en el servidor (función `responder_pregunta`).
class PreguntaRelampagoDialog extends StatefulWidget {
  final String preguntaId;
  final String pregunta;
  final List<String> opciones;
  final int segundos;
  final String nombreEstudiante;

  const PreguntaRelampagoDialog({
    super.key,
    required this.preguntaId,
    required this.pregunta,
    required this.opciones,
    required this.segundos,
    required this.nombreEstudiante,
  });

  @override
  State<PreguntaRelampagoDialog> createState() =>
      _PreguntaRelampagoDialogState();
}

class _PreguntaRelampagoDialogState extends State<PreguntaRelampagoDialog> {
  static const List<String> _letras = ['A', 'B', 'C', 'D'];
  static const List<Color> _colores = [
    Color(0xFFE53935),
    Color(0xFF1E88E5),
    Color(0xFFFFA000),
    Color(0xFF43A047),
  ];

  late final DateTime _fin;
  Timer? _timer;
  int _restantes = 0;

  bool _enviando = false;
  int? _elegida;
  int? _correcta;
  ResultadoPregunta? _resultado;
  String? _mensaje;

  @override
  void initState() {
    super.initState();
    _fin = DateTime.now().add(Duration(seconds: widget.segundos));
    _restantes = widget.segundos;
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _tic());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tic() {
    if (!mounted) return;
    final int restantes =
        (_fin.difference(DateTime.now()).inMilliseconds / 1000).ceil();
    if (restantes <= 0 && _resultado == null && !_enviando) {
      _terminar(
        const ResultadoPregunta(respondida: false),
        mensaje: '⏰ Se acabó el tiempo',
      );
      return;
    }
    if (restantes != _restantes) setState(() => _restantes = restantes);
  }

  void _terminar(ResultadoPregunta resultado, {required String mensaje}) {
    _timer?.cancel();
    setState(() {
      _resultado = resultado;
      _mensaje = mensaje;
    });
    // Se cierra solo para no interrumpir la clase
    Future<void>.delayed(const Duration(milliseconds: 2600), () {
      if (mounted) Navigator.of(context).pop(resultado);
    });
  }

  Future<void> _responder(int opcion) async {
    if (_enviando || _resultado != null) return;
    setState(() {
      _enviando = true;
      _elegida = opcion;
    });

    try {
      final dynamic datos = await SupabaseConfig.client.rpc(
        'responder_pregunta',
        params: {
          'p_pregunta': widget.preguntaId,
          'p_opcion': opcion,
          'p_nombre': widget.nombreEstudiante,
        },
      );
      final Map<String, dynamic> r = Map<String, dynamic>.from(datos as Map);
      final bool ok = r['correcta'] == true;
      final int puntos = (r['puntos'] as num?)?.toInt() ?? 0;
      _correcta = (r['opcion_correcta'] as num?)?.toInt();
      if (!mounted) return;
      _terminar(
        ResultadoPregunta(respondida: true, correcta: ok, puntos: puntos),
        mensaje: ok ? '🎉 ¡Correcto! +$puntos puntos' : '❌ Incorrecto · +$puntos por participar',
      );
    } on PostgrestException catch (e) {
      if (!mounted) return;
      _terminar(
        const ResultadoPregunta(respondida: false),
        mensaje: e.message.contains('tiempo') || e.message.contains('Ya respondiste')
            ? e.message
            : 'No se pudo enviar tu respuesta.',
      );
    } catch (e) {
      if (!mounted) return;
      _terminar(
        const ResultadoPregunta(respondida: false),
        mensaje: 'Sin conexión: no se pudo enviar tu respuesta.',
      );
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  Color _colorOpcion(int i) {
    if (_resultado == null) return _colores[i % _colores.length];
    if (_correcta == i) return Colors.green.shade600;
    if (_elegida == i) return Colors.red.shade400;
    return Colors.grey.shade400;
  }

  @override
  Widget build(BuildContext context) {
    final double progreso =
        widget.segundos > 0 ? (_restantes / widget.segundos).clamp(0.0, 1.0) : 0;

    return PopScope(
      canPop: false, // no se puede cerrar sin responder o sin que acabe el tiempo
      child: Dialog(
        insetPadding: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text('⚡', style: TextStyle(fontSize: 22)),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'Pregunta relámpago',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Color(0xFFB45309),
                      ),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _restantes <= 5
                          ? Colors.red.shade50
                          : Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '⏳ ${_restantes.clamp(0, 999)} s',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _restantes <= 5
                            ? Colors.red.shade700
                            : Colors.amber.shade900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: progreso,
                  minHeight: 6,
                  backgroundColor: Colors.amber.shade100,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    _restantes <= 5 ? Colors.red : Colors.amber.shade700,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.pregunta,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              for (int i = 0; i < widget.opciones.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _colorOpcion(i),
                      disabledBackgroundColor: _colorOpcion(i),
                      foregroundColor: Colors.white,
                      disabledForegroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        vertical: 14,
                        horizontal: 12,
                      ),
                      alignment: Alignment.centerLeft,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: (_enviando || _resultado != null)
                        ? null
                        : () => _responder(i),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 13,
                          backgroundColor: Colors.white24,
                          child: Text(
                            _letras[i],
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            widget.opciones[i],
                            style: const TextStyle(fontSize: 15),
                          ),
                        ),
                        if (_enviando && _elegida == i)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              if (_mensaje != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _mensaje!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: _resultado?.correcta == true
                          ? Colors.green.shade700
                          : Colors.grey.shade800,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
