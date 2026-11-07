import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  // Mientras se comprueba si había una clase en curso al abrir la app
  bool _restaurandoSesion = true;

  // Clave en el almacenamiento local del celular donde se recuerda
  // la clase escaneada, para retomarla si el estudiante cierra la app.
  static const String _claveSesionLocal = 'sesion_en_curso';

  // ============================================================
  // TEMPORIZADOR DEL MODO ENFOQUE
  // ============================================================
  int _duracionTotalSegundos = 45 * 60;
  int _segundosRestantes = 0;
  DateTime? _horaFinEnfoque;
  Timer? _timerEnfoque;
  String _nombreAsignatura = '';
  String _grupoAula = '';

  // ============================================================
  // CANAL NATIVO Y DETECCIÓN DE APPS
  // ============================================================
  static const EventChannel _screenChannel =
      EventChannel('com.example.estudiante_app/screen_events');

  // Canal nativo propio para saber a qué app se fue el estudiante
  // (reemplaza al paquete app_usage, que ya no es compatible con Gradle moderno)
  static const MethodChannel _usoChannel =
      MethodChannel('com.example.estudiante_app/uso_apps');

  // El QR del docente tiene el formato CLASE_QR_<milisegundos> y rota cada 10 s.
  // Se acepta si fue generado hace menos de este tiempo (margen para relojes desfasados).
  static const String _prefijoQR = 'CLASE_QR_';
  static const Duration _vigenciaQR = Duration(minutes: 2);

  StreamSubscription? _screenSubscription;

  bool _isScreenLockedOrOff = false;
  bool _estaEnSegundoPlano = false;
  bool _posibleNotificacion = false;

  bool _desbloqueoRegistrado = false;
  bool _salioRegistrado = false;

  Timer? _timerBloqueo;
  Timer? _timerNotificacion;
  Timer? _timerGracia;

  static const int _segundosGracia = 10;
  DateTime? _limiteGracia;

  final List<Map<String, dynamic>> _alertasPendientes = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initScreenStateListener();
    _restaurarSesion();
  }

  // ============================================================
  // RETOMAR LA CLASE SI EL ESTUDIANTE CERRÓ Y REABRIÓ LA APP
  // ============================================================
  Future<void> _guardarSesionLocal(
    Map<String, dynamic> sesion,
    String codigo,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _claveSesionLocal,
        jsonEncode({
          'uid': SupabaseConfig.client.auth.currentUser?.id,
          'creado_en': sesion['creado_en']?.toString(),
          'qr': codigo,
        }),
      );
    } catch (e) {
      debugPrint('No se pudo guardar la sesión local: $e');
    }
  }

  Future<void> _borrarSesionLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_claveSesionLocal);
    } catch (e) {
      debugPrint('No se pudo borrar la sesión local: $e');
    }
  }

  /// Si el estudiante ya escaneó el QR de la clase que sigue activa,
  /// retoma el monitoreo y el temporizador sin pedir un nuevo escaneo.
  Future<void> _restaurarSesion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? guardado = prefs.getString(_claveSesionLocal);
      if (guardado == null) return;

      final Map<String, dynamic> datos =
          jsonDecode(guardado) as Map<String, dynamic>;

      // Debe ser el mismo estudiante que tiene la sesión iniciada
      if (datos['uid'] != SupabaseConfig.client.auth.currentUser?.id) {
        await _borrarSesionLocal();
        return;
      }

      final Map<String, dynamic>? sesion = await _consultarSesionActiva();

      // Debe ser la MISMA clase (mismo inicio) y todavía con tiempo
      final bool mismaClase = sesion != null &&
          sesion['creado_en']?.toString() == datos['creado_en'];
      if (!mismaClase || _segundosRestantesDe(sesion) <= 0) {
        await _borrarSesionLocal();
        return;
      }

      if (!mounted) return;
      setState(() {
        _sesionIniciada = true;
        qrDetectado = datos['qr']?.toString();
      });
      _iniciarModoEnfoque(sesion);
      _registrarAlerta('reabrio_app');

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Clase en curso retomada. El docente fue notificado.'),
          backgroundColor: Colors.orange,
        ),
      );
    } catch (e) {
      debugPrint('No se pudo restaurar la sesión: $e');
    } finally {
      if (mounted) {
        setState(() {
          _restaurandoSesion = false;
        });
      }
    }
  }

  // ============================================================
  // PERMISO DE "ACCESO A DATOS DE USO" Y APP DE DESTINO
  // ============================================================
  Future<bool> _tienePermisoUso() async {
    try {
      return await _usoChannel.invokeMethod<bool>('tienePermisoUso') ?? false;
    } catch (e) {
      debugPrint('No se pudo verificar el permiso de uso: $e');
      return false;
    }
  }

  /// El permiso de uso es OBLIGATORIO para iniciar la clase.
  /// Devuelve true solo si el permiso ya está concedido.
  Future<bool> _asegurarPermisoUso() async {
    if (await _tienePermisoUso()) return true;
    if (!mounted) return false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Permiso obligatorio'),
        content: const Text(
          'Para participar en la clase debes activar '
          '"Acceso a datos de uso" para esta app.\n\n'
          '1. Pulsa "Abrir ajustes".\n'
          '2. Busca estudiante_app y activa el permiso.\n'
          '3. Vuelve aquí y pulsa "Escanear Código QR".',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              try {
                await _usoChannel.invokeMethod('abrirAjustesUso');
              } catch (e) {
                debugPrint('No se pudo abrir ajustes de uso: $e');
              }
            },
            child: const Text('Abrir ajustes'),
          ),
        ],
      ),
    );
    // Aunque haya abierto los ajustes, no se escanea hasta que vuelva
    // y el permiso esté realmente activado (se verifica en el próximo intento).
    return false;
  }

  Future<String> _obtenerAppDestino() async {
    try {
      final String? paquete = await _usoChannel.invokeMethod<String>(
        'ultimaAppEnPrimerPlano',
        {'segundos': 30},
      );
      if (paquete != null) return _nombreDeApp(paquete);
    } catch (e) {
      debugPrint('Error leyendo app en primer plano: $e');
    }
    return 'Otra App';
  }

  // Paquete de Android -> nombre que verá el docente en el panel.
  // El ORDEN importa: los más específicos primero (p. ej. Messenger antes que Facebook).
  static const List<MapEntry<List<String>, String>> _catalogoApps = [
    MapEntry(['whatsapp'], 'WhatsApp'),
    MapEntry(['instagram.barcelona'], 'Threads'),
    MapEntry(['instagram'], 'Instagram'),
    MapEntry(['musically', 'tiktok', 'ugc.trill'], 'TikTok'),
    MapEntry(['facebook.orca', 'messenger'], 'Messenger'),
    MapEntry(['facebook', 'katana'], 'Facebook'),
    MapEntry(['youtube'], 'YouTube'),
    MapEntry(['telegram'], 'Telegram'),
    MapEntry(['twitter', 'com.x.android'], 'X'),
    MapEntry(['snapchat'], 'Snapchat'),
    MapEntry(['spotify'], 'Spotify'),
    MapEntry(['netflix'], 'Netflix'),
    MapEntry(['discord'], 'Discord'),
    MapEntry(['twitch'], 'Twitch'),
    MapEntry(['reddit'], 'Reddit'),
    MapEntry(['pinterest'], 'Pinterest'),
    MapEntry(['android.chrome', 'chrome'], 'Chrome'),
    MapEntry(['firefox', 'mozilla'], 'Firefox'),
    MapEntry(['android.gm'], 'Gmail'),
    MapEntry(['openai', 'chatgpt'], 'ChatGPT'),
    MapEntry(['android.apps.bard', 'gemini'], 'Gemini'),
    MapEntry([
      'supercell', 'brawlstars', 'clashofclans', 'clashroyale',
      'freefire', 'garena', 'roblox', 'pubg', 'tencent.ig',
      'mobile.legends', 'mojang', 'minecraft', 'activision',
      'callofduty', 'mihoyo', 'hoyoverse', 'king.candycrush', 'epicgames',
    ], 'Juegos'),
    MapEntry(['camera'], 'Cámara'),
    MapEntry(['gallery', 'photos'], 'Galería'),
    MapEntry(['android.settings', 'systemsettings'], 'Ajustes'),
    MapEntry(['launcher', '.home'], 'Pantalla de inicio'),
  ];

  String _nombreDeApp(String paquete) {
    final String pkg = paquete.toLowerCase();
    for (final MapEntry<List<String>, String> app in _catalogoApps) {
      if (app.key.any(pkg.contains)) return app.value;
    }
    return 'Otra App';
  }

  // ============================================================
  // VALIDACIÓN DEL CÓDIGO QR
  // ============================================================
  /// Devuelve null si el QR es válido, o el mensaje de error.
  String? _validarQR(String codigo) {
    if (!codigo.startsWith(_prefijoQR)) {
      return 'Este código QR no pertenece a la clase.';
    }
    final int? milis = int.tryParse(codigo.substring(_prefijoQR.length));
    if (milis == null) {
      return 'Código QR inválido.';
    }
    final DateTime generado = DateTime.fromMillisecondsSinceEpoch(milis);
    final Duration diferencia = DateTime.now().difference(generado).abs();
    if (diferencia > _vigenciaQR) {
      return 'El código QR ha expirado. Escanea el que muestra ahora el docente.';
    }
    return null;
  }

  // ============================================================
  // LÓGICA DEL TEMPORIZADOR Y SINCRONIZACIÓN
  // ============================================================

  /// Convierte la fecha de Supabase a DateTime. Si viene sin zona horaria
  /// (columna `timestamp` en vez de `timestamptz`), se interpreta como UTC,
  /// que es como la guarda el panel docente (toISOString()).
  DateTime? _parsearFechaSupabase(dynamic valor) {
    if (valor == null) return null;
    String texto = valor.toString().trim();
    final bool tieneZona =
        RegExp(r'(Z|[+-]\d{2}(:?\d{2})?)$').hasMatch(texto);
    if (!tieneZona) texto = '${texto}Z';
    return DateTime.tryParse(texto);
  }

  Future<Map<String, dynamic>?> _consultarSesionActiva() {
    return SupabaseConfig.client
        .from('configuracion_sesion')
        .select('duracion, asignatura, grupo, creado_en')
        .eq('estado', 'ACTIVA')
        .order('creado_en', ascending: false)
        .limit(1)
        .maybeSingle();
  }

  int _duracionSegundos(Map<String, dynamic> sesion) {
    final int minutos = int.tryParse('${sesion['duracion']}') ?? 45;
    return minutos * 60;
  }

  int _segundosRestantesDe(Map<String, dynamic> sesion) {
    final int duracionTotal = _duracionSegundos(sesion);
    final DateTime? creadoEn = _parsearFechaSupabase(sesion['creado_en']);
    if (creadoEn == null) return duracionTotal;

    final int transcurridos = DateTime.now().difference(creadoEn).inSeconds;
    final int restantes = duracionTotal - transcurridos;
    return restantes > 0 ? restantes : 0;
  }

  void _iniciarModoEnfoque(Map<String, dynamic> sesion) {
    final int duracionTotal = _duracionSegundos(sesion);
    final int restantes = _segundosRestantesDe(sesion);

    setState(() {
      _nombreAsignatura = sesion['asignatura']?.toString() ?? '';
      _grupoAula = sesion['grupo']?.toString() ?? '';
      _duracionTotalSegundos = duracionTotal;
      _segundosRestantes = restantes;
      _horaFinEnfoque = DateTime.now().add(Duration(seconds: restantes));
    });

    if (restantes > 0) {
      _iniciarCronometroEnfoque();
    } else {
      setState(() {
        _sesionIniciada = false;
      });
      _borrarSesionLocal();
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
        _borrarSesionLocal();

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
    _limiteGracia = DateTime.now().add(const Duration(seconds: _segundosGracia));
    _salioRegistrado = false;

    _timerGracia = Timer(const Duration(seconds: _segundosGracia), () async {
      if (!mounted || !_sesionIniciada) return;

      final bool enLaApp = WidgetsBinding.instance.lifecycleState ==
          AppLifecycleState.resumed;

      if (!enLaApp && !_isScreenLockedOrOff && !_salioRegistrado) {
        _salioRegistrado = true;
        String appNombre = await _obtenerAppDestino();
        _registrarAlerta('salio_de_app:$appNombre', fecha: _limiteGracia);
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
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

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
        } else if (event == 'pantalla_encendida') {
          _isScreenLockedOrOff = false;
          if (!appEnPrimerPlano) {
            _estaEnSegundoPlano = true;
          }
        } else if (event == 'pantalla_desbloqueada') {
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
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
          () async {
            if (!_isScreenLockedOrOff &&
                _estaEnSegundoPlano &&
                !_salioRegistrado) {
              _salioRegistrado = true;
              String appNombre = await _obtenerAppDestino();
              _registrarAlerta('salio_de_app:$appNombre');
            }
          },
        );
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_horaFinEnfoque != null) {
        final int diferenciaSegundos =
            _horaFinEnfoque!.difference(DateTime.now()).inSeconds;

        setState(() {
          _segundosRestantes = diferenciaSegundos > 0 ? diferenciaSegundos : 0;
        });

        if (_segundosRestantes == 0) {
          _timerEnfoque?.cancel();
          setState(() {
            _sesionIniciada = false;
          });
          _borrarSesionLocal();
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
        _obtenerAppDestino().then((appNombre) {
          _registrarAlerta('salio_de_app:$appNombre', fecha: limite);
        });
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
      'estudiante_id': SupabaseConfig.client.auth.currentUser?.id,
      'estudiante_nombre': widget.nombreEstudiante,
      'evento': evento,
      'fecha_hora': (fecha ?? DateTime.now()).toIso8601String(),
    };

    try {
      await SupabaseConfig.client.from('alertas_inactividad').insert(registro);
      debugPrint('[ALERTA DETECTADA] ${widget.nombreEstudiante} -> $evento');
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
        _alertasPendientes.add(registro);
      }
    }
  }

  // ============================================================
  // REGISTRAR ASISTENCIA
  // ============================================================
  Future<void> _registrarAsistencia(String codigo) async {
    if (_guardandoAsistencia) return;

    if (mounted) {
      setState(() {
        _guardandoAsistencia = true;
      });
    }

    try {
      // 1. Verificar que el docente tenga una clase activa y en curso
      final Map<String, dynamic>? sesion = await _consultarSesionActiva();
      if (!mounted) return;

      if (sesion == null) {
        _mostrarError('El docente aún no ha iniciado la clase.');
        return;
      }
      if (_segundosRestantesDe(sesion) <= 0) {
        _mostrarError('La clase ya finalizó. No se puede registrar asistencia.');
        return;
      }

      // 2. Registrar la asistencia
      await SupabaseConfig.client.from('asistencias').insert({
        'estudiante_id': SupabaseConfig.client.auth.currentUser?.id,
        'estudiante_nombre': widget.nombreEstudiante,
        'qr_contenido': codigo,
        'fecha_hora': DateTime.now().toIso8601String(),
      });

      if (!mounted) return;

      setState(() {
        qrDetectado = codigo;
        _sesionIniciada = true;
      });

      // 3. Recordar la clase en el celular (por si cierra y reabre la app)
      await _guardarSesionLocal(sesion, codigo);

      // 4. Iniciar monitoreo y temporizador
      await _registrarAlerta('ingreso');
      if (!mounted) return;
      _iniciarModoEnfoque(sesion);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('¡Asistencia registrada e inicio de clase confirmado!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      debugPrint('Error registrando asistencia: $e');
      _mostrarError('Error al registrar asistencia: $e');
    } finally {
      if (mounted) {
        setState(() {
          _guardandoAsistencia = false;
        });
      }
    }
  }

  void _mostrarError(String mensaje) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(mensaje),
        backgroundColor: Colors.red,
      ),
    );
  }

  Future<void> _abrirEscanerQR() async {
    // Pedir el permiso de uso antes de iniciar la clase
    final bool continuar = await _asegurarPermisoUso();
    if (!continuar || !mounted) return;

    bool procesado = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: MobileScanner(
                    onDetect: (BarcodeCapture capture) {
                      // onDetect se dispara muchas veces por segundo:
                      // solo procesamos el primer código leído.
                      if (procesado || _guardandoAsistencia) return;

                      for (final Barcode barcode in capture.barcodes) {
                        final String? codigo = barcode.rawValue;
                        if (codigo == null || codigo.isEmpty) continue;

                        procesado = true;
                        Navigator.pop(modalContext);

                        final String? error = _validarQR(codigo);
                        if (error != null) {
                          _mostrarError(error);
                        } else {
                          _registrarAsistencia(codigo);
                        }
                        break;
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
                  onPressed: () => Navigator.pop(modalContext),
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
              await _borrarSesionLocal();
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
                          color: _sesionIniciada ? Colors.green : Colors.orange,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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
                                  valueColor: const AlwaysStoppedAnimation<Color>(
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
                          onPressed: (_guardandoAsistencia ||
                                  _sesionIniciada ||
                                  _restaurandoSesion)
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