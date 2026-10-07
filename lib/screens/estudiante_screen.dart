import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../config/supabase_config.dart';
import 'login_screen.dart';

class EstudianteScreen extends StatefulWidget {
  final String nombreEstudiante;

  const EstudianteScreen({
    super.key,
    required this.nombreEstudiante,
  });

  @override
  State<EstudianteScreen> createState() => _EstudianteScreenState();
}

class _EstudianteScreenState extends State<EstudianteScreen>
    with WidgetsBindingObserver {
  String? qrDetectado;

  bool _guardandoAsistencia = false;
  bool _sesionIniciada = false;

  // ============================================================
  // TEMPORIZADOR DEL MODO ENFOQUE
  // ============================================================
  int _duracionTotalSegundos = 45 * 60; // 45 minutos por defecto
  int _segundosRestantes = 0;
  DateTime? _horaFinEnfoque; // Almacena el timestamp exacto de finalización
  Timer? _timerEnfoque;
  String _nombreAsignatura = '';
  String _grupoAula = '';

  // ============================================================
  // CANAL NATIVO PARA DETECTAR BLOQUEO / DESBLOQUEO
  // ============================================================

  static const EventChannel _screenChannel =
      EventChannel('com.example.estudiante_app/screen_events');

  StreamSubscription? _screenSubscription;

  bool _isScreenLockedOrOff = false;
  bool _estaEnSegundoPlano = false;
  bool _posibleNotificacion = false;

  // Evita registrar el desbloqueo más de una vez
  bool _desbloqueoRegistrado = false;

  // Evita registrar "salio_de_app" más de una vez por ausencia
  bool _salioRegistrado = false;

  Timer? _timerBloqueo;
  Timer? _timerNotificacion;
  Timer? _timerGracia;

  // Segundos que tiene el estudiante para volver a la app
  static const int _segundosGracia = 10;

  // Hora límite para volver a la app (desbloqueo + 10 s)
  DateTime? _limiteGracia;

  // Alertas que no se pudieron enviar (sin red en segundo plano)
  final List<Map<String, dynamic>> _alertasPendientes = [];

  // ============================================================
  // INIT STATE
  // ============================================================

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _initScreenStateListener();
  }

  // ============================================================
  // LÓGICA DEL TEMPORIZADOR Y SINCRONIZACIÓN
  // ============================================================

  Future<void> _obtenerYIniciarModoEnfoque() async {
    int minutos = 45; // Valor fallback por si falla la red
    DateTime? creadoEn;

    try {
      final data = await SupabaseConfig.client
          .from('configuracion_sesion')
          .select('duracion, asignatura, grupo, creado_en')
          .eq('estado', 'ACTIVA')
          .order('creado_en', ascending: false)
          .limit(1)
          .maybeSingle();

      if (data != null) {
        if (data['duracion'] != null) {
          minutos = int.tryParse(data['duracion'].toString()) ?? 45;
        }
        _nombreAsignatura = data['asignatura'] ?? '';
        _grupoAula = data['grupo'] ?? '';

        if (data['creado_en'] != null) {
          creadoEn = DateTime.tryParse(data['creado_en'].toString());
        }
      }
    } catch (e) {
      debugPrint('Error al consultar duración de sesión: $e');
    }

    if (!mounted) return;

    final int duracionTotal = minutos * 60;
    int segundosCalculados = duracionTotal;

    // Sincronización con la hora exacta en la que el docente inició la sesión
    if (creadoEn != null) {
      final int transcurridos =
          DateTime.now().difference(creadoEn.toLocal()).inSeconds;
      segundosCalculados = duracionTotal - transcurridos;

      if (segundosCalculados <= 0) {
        segundosCalculados = 0;
      }
    }

    setState(() {
      _duracionTotalSegundos = duracionTotal;
      _segundosRestantes = segundosCalculados;
      // Guardamos la hora de finalización absoluta de la sesión
      _horaFinEnfoque = DateTime.now().add(Duration(seconds: segundosCalculados));
    });

    if (_segundosRestantes > 0) {
      _iniciarCronometroEnfoque();
    } else {
      setState(() {
        _sesionIniciada = false;
      });
    }
  }

  void _iniciarCronometroEnfoque() {
    _timerEnfoque?.cancel();

    _timerEnfoque = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;

      if (_segundosRestantes > 0) {
        setState(() {
          _segundosRestantes--;
        });
      } else {
        _timerEnfoque?.cancel();
        setState(() {
          _sesionIniciada = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('¡Has completado el Modo Enfoque exitosamente! 🎉'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 5),
          ),
        );
      }
    });
  }

  String _formatearTiempo(int totalSegundos) {
    final int minutos = totalSegundos ~/ 60;
    final int segundos = totalSegundos % 60;
    return '${minutos.toString().padLeft(2, '0')}:${segundos.toString().padLeft(2, '0')}';
  }

  // ============================================================
  // TIEMPO DE GRACIA (10 SEGUNDOS PARA VOLVER A LA APP)
  // ============================================================

  void _iniciarTiempoGracia() {
    _timerGracia?.cancel();

    _limiteGracia =
        DateTime.now().add(const Duration(seconds: _segundosGracia));

    // Cada conteo de 10 s empieza limpio
    _salioRegistrado = false;

    _timerGracia = Timer(const Duration(seconds: _segundosGracia), () {
      if (!mounted || !_sesionIniciada) return;

      final bool enLaApp = WidgetsBinding.instance.lifecycleState ==
          AppLifecycleState.resumed;

      // La pantalla está desbloqueada, pero la app no volvió a primer plano
      if (!enLaApp && !_isScreenLockedOrOff && !_salioRegistrado) {
        _salioRegistrado = true;
        _registrarAlerta('salio_de_app', fecha: _limiteGracia);
      }
    });
  }

  // ============================================================
  // EVENTOS NATIVOS DE PANTALLA
  // ============================================================

  void _initScreenStateListener() {
    _screenSubscription = _screenChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (!_sesionIniciada) return;

        final bool appEnPrimerPlano =
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed;

        // ------------------------------------------------------
        // PANTALLA BLOQUEADA / APAGADA
        // ------------------------------------------------------
        if (event == 'pantalla_bloqueada') {
          _isScreenLockedOrOff = true;
          _posibleNotificacion = false;
          _desbloqueoRegistrado = false;
          _salioRegistrado = false;
          _limiteGracia = null;

          _timerBloqueo?.cancel();
          _timerNotificacion?.cancel();
          _timerGracia?.cancel();

          _registrarAlerta('pantalla_bloqueada');
        }

        // ------------------------------------------------------
        // PANTALLA ENCENDIDA
        // ------------------------------------------------------
        else if (event == 'pantalla_encendida') {
          _isScreenLockedOrOff = false;

          if (!appEnPrimerPlano) {
            _estaEnSegundoPlano = true;
          }
        }

        // ------------------------------------------------------
        // DESBLOQUEO REAL (PIN / huella)
        // ------------------------------------------------------
        else if (event == 'pantalla_desbloqueada') {
          _isScreenLockedOrOff = false;

          if (!appEnPrimerPlano && !_desbloqueoRegistrado) {
            _desbloqueoRegistrado = true;
            _estaEnSegundoPlano = true;
            _registrarAlerta('desbloqueo');
            _iniciarTiempoGracia();
          }
        }
      },
      onError: (dynamic error) {
        debugPrint('Error en canal de pantalla: $error');
      },
    );
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    _timerBloqueo?.cancel();
    _timerNotificacion?.cancel();
    _timerGracia?.cancel();
    _timerEnfoque?.cancel();

    WidgetsBinding.instance.removeObserver(this);

    _screenSubscription?.cancel();

    super.dispose();
  }

  // ============================================================
  // CICLO DE VIDA DE LA APP
  // ============================================================

  @override
  void didChangeAppLifecycleState(
    AppLifecycleState state,
  ) {
    if (!_sesionIniciada) return;

    if (state == AppLifecycleState.inactive) {
      if (!_estaEnSegundoPlano && !_isScreenLockedOrOff) {
        _posibleNotificacion = true;

        _timerNotificacion?.cancel();
        _timerNotificacion = Timer(const Duration(milliseconds: 1000), () {
          if (_posibleNotificacion &&
              !_estaEnSegundoPlano &&
              !_isScreenLockedOrOff) {
            _registrarAlerta('vio_notificaciones');
            _posibleNotificacion = false;
          }
        });
      }
    } else if (state == AppLifecycleState.paused) {
      _estaEnSegundoPlano = true;
      _posibleNotificacion = false;

      _timerNotificacion?.cancel();
      _timerBloqueo?.cancel();

      if (!_isScreenLockedOrOff) {
        _timerBloqueo = Timer(
          const Duration(milliseconds: 1500),
          () {
            if (!_isScreenLockedOrOff &&
                _estaEnSegundoPlano &&
                !_salioRegistrado) {
              _salioRegistrado = true;
              _registrarAlerta('salio_de_app');
            }
          },
        );
      }
    } else if (state == AppLifecycleState.resumed) {
      // ------------------------------------------------------
      // RECALCULAR TIEMPO REAL AL REGRESAR DE SEGUNDO PLANO
      // ------------------------------------------------------
      if (_horaFinEnfoque != null) {
        final int diferenciaSegundos =
            _horaFinEnfoque!.difference(DateTime.now()).inSeconds;

        setState(() {
          _segundosRestantes = diferenciaSegundos > 0 ? diferenciaSegundos : 0;
        });

        if (_segundosRestantes == 0) {
          _timerEnfoque?.cancel();
          _sesionIniciada = false;
        }
      }

      _timerBloqueo?.cancel();
      _timerNotificacion?.cancel();
      _timerGracia?.cancel();
      _desbloqueoRegistrado = false;

      _enviarPendientes();

      final DateTime? limite = _limiteGracia;
      if (limite != null &&
          !_salioRegistrado &&
          DateTime.now().isAfter(limite)) {
        _salioRegistrado = true;
        _registrarAlerta('salio_de_app', fecha: limite);
      }
      _limiteGracia = null;
      _salioRegistrado = false;

      if (_estaEnSegundoPlano || _isScreenLockedOrOff) {
        _estaEnSegundoPlano = false;
        _posibleNotificacion = false;

        _registrarAlerta('regreso');

        _isScreenLockedOrOff = false;
      } else {
        _posibleNotificacion = false;
      }
    }
  }

  // ============================================================
  // REGISTRAR ALERTA EN SUPABASE
  // ============================================================

  Future<bool> _registrarAlerta(
    String evento, {
    DateTime? fecha,
  }) async {
    final Map<String, dynamic> registro = {
      'estudiante_nombre': widget.nombreEstudiante,
      'evento': evento,
      'fecha_hora': (fecha ?? DateTime.now()).toIso8601String(),
    };

    try {
      await SupabaseConfig.client.from('alertas_inactividad').insert(registro);

      debugPrint('[ALERTA] ${widget.nombreEstudiante} -> $evento');
      return true;
    } catch (e) {
      debugPrint('Error registrando alerta "$evento", queda pendiente: $e');
      _alertasPendientes.add(registro);
      return false;
    }
  }

  Future<void> _enviarPendientes() async {
    if (_alertasPendientes.isEmpty) return;

    final List<Map<String, dynamic>> lista =
        List<Map<String, dynamic>>.from(_alertasPendientes);
    _alertasPendientes.clear();

    for (final Map<String, dynamic> registro in lista) {
      try {
        await SupabaseConfig.client
            .from('alertas_inactividad')
            .insert(registro);

        debugPrint('[ALERTA PENDIENTE ENVIADA] ${registro['evento']}');
      } catch (e) {
        debugPrint('Sigue sin enviarse "${registro['evento']}": $e');
        _alertasPendientes.add(registro);
      }
    }
  }

  // ============================================================
  // REGISTRAR ASISTENCIA
  // ============================================================

  Future<void> _registrarAsistencia(
    String codigo,
  ) async {
    if (_guardandoAsistencia) return;

    if (mounted) {
      setState(() {
        _guardandoAsistencia = true;
      });
    }

    try {
      await SupabaseConfig.client.from('asistencias').insert({
        'estudiante_nombre': widget.nombreEstudiante,
        'qr_contenido': codigo,
        'fecha_hora': DateTime.now().toIso8601String(),
      });

      if (!mounted) return;

      setState(() {
        _sesionIniciada = true;
      });

      await _registrarAlerta('ingreso');

      // Consultar la duración y arrancar el temporizador del celular
      await _obtenerYIniciarModoEnfoque();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '¡Asistencia registrada e inicio de clase confirmado!',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      debugPrint('Error registrando asistencia: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al registrar asistencia: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _guardandoAsistencia = false;
        });
      }
    }
  }

  // ============================================================
  // ABRIR ESCÁNER QR
  // ============================================================

  void _abrirEscanerQR() {
    qrDetectado = null;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(24),
        ),
      ),
      builder: (BuildContext modalContext) {
        return Container(
          height: MediaQuery.of(modalContext).size.height * 0.7,
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Container(
                width: 40,
                height: 5,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const Text(
                'Escanea el código QR de la clase',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: MobileScanner(
                    onDetect: (BarcodeCapture capture) {
                      if (_guardandoAsistencia) return;

                      for (final Barcode barcode in capture.barcodes) {
                        final String? codigo = barcode.rawValue;

                        if (codigo != null &&
                            codigo.isNotEmpty &&
                            qrDetectado != codigo) {
                          qrDetectado = codigo;

                          _registrarAsistencia(codigo);

                          Navigator.pop(modalContext);

                          break;
                        }
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () {
                    Navigator.pop(modalContext);
                  },
                  icon: const Icon(Icons.close),
                  label: const Text('Cancelar Escaneo'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ============================================================
  // INTERFAZ DE USUARIO
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final double progreso = _duracionTotalSegundos > 0
        ? (_segundosRestantes / _duracionTotalSegundos)
        : 0.0;

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('Vista Estudiante'),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Cerrar Sesión',
            onPressed: () async {
              await SupabaseConfig.client.auth.signOut();
              if (context.mounted) {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const LoginScreen(),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    children: [
                      const CircleAvatar(
                        radius: 40,
                        backgroundColor: Colors.blueAccent,
                        child: Icon(
                          Icons.person,
                          size: 50,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        widget.nombreEstudiante,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _sesionIniciada
                            ? 'Estado: En Clase (Monitoreando)'
                            : 'Estado: Pendiente de escaneo QR',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color:
                              _sesionIniciada ? Colors.green : Colors.orange,
                          fontWeight: FontWeight.w600,
                        ),
                      ),

                      // ==========================================
                      // TARJETA DE CRONÓMETRO DEL MODO ENFOQUE
                      // ==========================================
                      if (_sesionIniciada) ...[
                        const Divider(height: 32),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.indigo.shade50,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.indigo.shade200),
                          ),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.timer, color: Colors.indigo),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Modo Enfoque Activo',
                                    style: TextStyle(
                                      color: Colors.indigo.shade900,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
                              ),
                              if (_nombreAsignatura.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  '$_nombreAsignatura - $_grupoAula',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.indigo.shade700,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 12),
                              Text(
                                _formatearTiempo(_segundosRestantes),
                                style: const TextStyle(
                                  fontSize: 36,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.indigo,
                                  letterSpacing: 2,
                                ),
                              ),
                              const SizedBox(height: 12),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: LinearProgressIndicator(
                                  value: progreso,
                                  minHeight: 10,
                                  backgroundColor: Colors.indigo.shade100,
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                    Colors.indigo,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Mantén la app abierta para conservar tu puntaje',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      const Divider(height: 32),
                      if (qrDetectado != null) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.green.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.green),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.check_circle,
                                color: Colors.green,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Asistencia registrada:\n$qrDetectado',
                                  style: const TextStyle(
                                    color: Colors.green,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // ==========================================
                      // BOTÓN DE ESCANEO
                      // ==========================================
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _sesionIniciada
                                ? Colors.grey.shade400
                                : Colors.indigo,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey.shade400,
                            disabledForegroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: (_guardandoAsistencia || _sesionIniciada)
                              ? null
                              : _abrirEscanerQR,
                          icon: Icon(
                            _sesionIniciada
                                ? Icons.check
                                : Icons.qr_code_scanner,
                          ),
                          label: Text(
                            _sesionIniciada
                                ? 'Asistencia Registrada'
                                : 'Escanear Código QR',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
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