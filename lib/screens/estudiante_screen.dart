import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/supabase_config.dart';
import '../utils/mensajes.dart';
import 'login_screen.dart';

class EstudianteScreen extends StatefulWidget {
  final String nombreEstudiante;

  /// true si se llega a esta pantalla justo después de iniciar sesión
  /// (para avisar al docente "volvió a iniciar sesión" en vez de "reabrió la app").
  final bool desdeLogin;

  const EstudianteScreen({
    super.key,
    required this.nombreEstudiante,
    this.desdeLogin = false,
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
  // CANALES NATIVOS
  // ============================================================
  static const EventChannel _screenChannel =
      EventChannel('com.example.estudiante_app/screen_events');

  // Canal nativo propio: permiso de uso, app en primer plano y servicio de monitoreo
  static const MethodChannel _usoChannel =
      MethodChannel('com.example.estudiante_app/uso_apps');

  // El QR del docente tiene el formato CLASE_QR_<milisegundos> y rota cada 10 s.
  // Se acepta si fue generado hace menos de este tiempo (margen para relojes desfasados).
  static const String _prefijoQR = 'CLASE_QR_';
  static const Duration _vigenciaQR = Duration(minutes: 2);

  StreamSubscription? _screenSubscription;

  // ============================================================
  // ESTADO DEL MONITOREO
  // ============================================================
  bool _isScreenLockedOrOff = false;
  bool _estaEnSegundoPlano = false;
  bool _posibleNotificacion = false;
  bool _desbloqueoRegistrado = false;

  Timer? _timerNotificacion;
  Timer? _timerDesbloqueo;

  // "creado_en" de la clase escaneada. Si el docente la termina o inicia
  // otra, deja de coincidir y la clase se finaliza también en el celular.
  String? _creadoEnSesion;
  int _ticksDesdeVerificacion = 0;
  static const int _verificarClaseCada = 15; // segundos

  // Vigilancia mientras el estudiante está FUERA de la app:
  // cada segundo se consulta qué app tiene abierta y se registra cada cambio.
  Timer? _timerVigilancia;
  bool _consultandoApp = false;
  String? _paqueteReportado; // última app registrada en esta salida
  bool _salidaReportada = false; // ya se registró "salió de la app" en esta salida
  DateTime? _inicioFuera;

  final List<Map<String, dynamic>> _alertasPendientes = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initScreenStateListener();
    _restaurarSesion();
  }

  @override
  void dispose() {
    _timerNotificacion?.cancel();
    _timerDesbloqueo?.cancel();
    _timerVigilancia?.cancel();
    _timerEnfoque?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _screenSubscription?.cancel();
    super.dispose();
  }

  // ============================================================
  // SERVICIO EN PRIMER PLANO (evita que Android congele la app)
  // ============================================================
  Future<void> _iniciarServicioMonitoreo() async {
    try {
      await _usoChannel.invokeMethod('iniciarMonitoreo');
    } catch (e) {
      debugPrint('No se pudo iniciar el servicio de monitoreo: $e');
    }
  }

  Future<void> _detenerServicioMonitoreo() async {
    try {
      await _usoChannel.invokeMethod('detenerMonitoreo');
    } catch (e) {
      debugPrint('No se pudo detener el servicio de monitoreo: $e');
    }
  }

  /// Termina el monitoreo de la clase (fin del tiempo o cierre de sesión).
  void _finalizarMonitoreo() {
    _timerEnfoque?.cancel();
    _timerVigilancia?.cancel();
    _timerNotificacion?.cancel();
    _timerDesbloqueo?.cancel();
    _detenerServicioMonitoreo();
  }

  // ============================================================
  // RETOMAR LA CLASE SI EL ESTUDIANTE CERRÓ LA APP O LA SESIÓN
  // ============================================================
  String? get _claveSesionLocal {
    final String? uid = SupabaseConfig.client.auth.currentUser?.id;
    return uid == null ? null : 'sesion_en_curso_$uid';
  }

  Future<void> _guardarSesionLocal(
    Map<String, dynamic> sesion,
    String codigo,
  ) async {
    final String? clave = _claveSesionLocal;
    if (clave == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        clave,
        jsonEncode({
          'creado_en': sesion['creado_en']?.toString(),
          'qr': codigo,
        }),
      );
    } catch (e) {
      debugPrint('No se pudo guardar la sesión local: $e');
    }
  }

  Future<void> _borrarSesionLocal() async {
    final String? clave = _claveSesionLocal;
    if (clave == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(clave);
    } catch (e) {
      debugPrint('No se pudo borrar la sesión local: $e');
    }
  }

  /// Si el estudiante ya escaneó el QR de la clase que sigue activa,
  /// retoma el monitoreo y el temporizador sin pedir un nuevo escaneo.
  Future<void> _restaurarSesion() async {
    try {
      final String? clave = _claveSesionLocal;
      final String? uid = SupabaseConfig.client.auth.currentUser?.id;
      if (clave == null || uid == null) return;

      // Debe haber una clase activa y con tiempo
      final Map<String, dynamic>? sesion = await _consultarSesionActiva();
      if (sesion == null || _segundosRestantesDe(sesion) <= 0) {
        await _borrarSesionLocal();
        return;
      }
      final String? creadoEn = sesion['creado_en']?.toString();
      String? qr;

      // 1. ¿Este celular recuerda haber escaneado ESTA clase?
      final prefs = await SharedPreferences.getInstance();
      final String? guardado = prefs.getString(clave);
      if (guardado != null) {
        final Map<String, dynamic> datos =
            jsonDecode(guardado) as Map<String, dynamic>;
        if (datos['creado_en'] == creadoEn) {
          qr = datos['qr']?.toString() ?? '';
        } else {
          await _borrarSesionLocal();
        }
      }

      // 2. Si no, ¿ya registró asistencia en esta clase?
      //    (app reinstalada o sesión iniciada en otro celular)
      if (qr == null) {
        final DateTime? inicio = _parsearFechaSupabase(creadoEn);
        if (inicio != null) {
          final Map<String, dynamic>? fila = await SupabaseConfig.client
              .from('asistencias')
              .select('qr_contenido')
              .eq('estudiante_id', uid)
              .gte('fecha_hora', inicio.toUtc().toIso8601String())
              .order('fecha_hora', ascending: false)
              .limit(1)
              .maybeSingle();
          if (fila != null) {
            qr = fila['qr_contenido']?.toString() ?? '';
            await _guardarSesionLocal(sesion, qr);
          }
        }
      }

      if (qr == null || !mounted) return;
      final String qrRecuperado = qr;
      setState(() {
        _sesionIniciada = true;
        qrDetectado = qrRecuperado.isEmpty ? null : qrRecuperado;
      });
      _iniciarModoEnfoque(sesion);
      _iniciarServicioMonitoreo();
      _registrarAlerta(widget.desdeLogin ? 'reingreso_sesion' : 'reabrio_app');

      mostrarAviso(
        context,
        'Clase en curso retomada. El docente fue notificado.',
        tipo: TipoAviso.advertencia,
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
  // CERRAR SESIÓN
  // ============================================================
  Future<void> _cerrarSesion() async {
    if (_sesionIniciada) {
      final bool? confirmar = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('¿Cerrar sesión?'),
          content: const Text(
            'Estás en plena clase. Si cierras sesión, el docente será '
            'notificado. Cuando vuelvas a entrar, el tiempo seguirá corriendo.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Seguir en clase'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Cerrar sesión'),
            ),
          ],
        ),
      );
      if (confirmar != true) return;

      // Se registra ANTES de cerrar sesión (después ya no hay permiso para escribir).
      // La clase guardada en el celular NO se borra: al volver a entrar se retoma.
      await _registrarAlerta('cerro_sesion');
      _sesionIniciada = false;
    }

    _finalizarMonitoreo();
    await SupabaseConfig.client.auth.signOut();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const LoginScreen()),
    );
  }

  // ============================================================
  // PERMISOS
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

  /// Permiso para mostrar la notificación "Clase en curso" (Android 13+).
  /// No es obligatorio: el monitoreo funciona igual sin él.
  Future<void> _pedirPermisoNotificaciones() async {
    try {
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
    } catch (e) {
      debugPrint('No se pudo pedir el permiso de notificaciones: $e');
    }
  }

  // ============================================================
  // NOMBRE DE LA APP A PARTIR DEL PAQUETE DE ANDROID
  // ============================================================
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
      _creadoEnSesion = sesion['creado_en']?.toString();
    });

    if (restantes > 0) {
      _iniciarCronometroEnfoque();
    } else {
      _terminarClase(mostrarMensaje: false);
    }
  }

  void _iniciarCronometroEnfoque() {
    _timerEnfoque?.cancel();

    _timerEnfoque = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;

      // Se calcula con la hora de fin (no restando 1) para no desfasarse
      // si el sistema retrasa el temporizador.
      final int restantes = _horaFinEnfoque == null
          ? 0
          : _horaFinEnfoque!.difference(DateTime.now()).inSeconds;

      if (restantes > 0) {
        setState(() {
          _segundosRestantes = restantes;
        });
        _ticksDesdeVerificacion++;
        if (_ticksDesdeVerificacion >= _verificarClaseCada) {
          _ticksDesdeVerificacion = 0;
          _verificarClaseVigente();
          _enviarPendientes();
        }
      } else {
        _terminarClase(mostrarMensaje: true);
      }
    });
  }

  /// Comprueba que el docente no haya terminado la clase (o iniciado otra).
  Future<void> _verificarClaseVigente() async {
    final String? creadoEn = _creadoEnSesion;
    if (!_sesionIniciada || creadoEn == null) return;
    try {
      final Map<String, dynamic>? sesion = await _consultarSesionActiva();
      if (!_sesionIniciada || _creadoEnSesion != creadoEn) return;

      String? motivo;
      if (sesion == null) {
        motivo = 'El docente finalizó la clase.';
      } else if (sesion['creado_en']?.toString() != creadoEn) {
        motivo = 'El docente inició una nueva clase. Escanea el nuevo código QR.';
      }
      if (motivo == null) return;

      _terminarClase(mostrarMensaje: false);
      if (mounted) {
        mostrarAviso(
          context,
          motivo,
          tipo: TipoAviso.info,
          duracion: const Duration(seconds: 6),
        );
      }
    } catch (e) {
      // Sin internet: se vuelve a intentar en la próxima verificación
      debugPrint('No se pudo verificar la clase: $e');
    }
  }

  void _terminarClase({required bool mostrarMensaje}) {
    _creadoEnSesion = null;
    _finalizarMonitoreo();
    if (mounted) {
      setState(() {
        _segundosRestantes = 0;
        _sesionIniciada = false;
      });
    }
    _borrarSesionLocal();

    if (mostrarMensaje && mounted) {
      mostrarAviso(
        context,
        '¡Has completado el Modo Enfoque exitosamente! 🎉',
        tipo: TipoAviso.exito,
        duracion: const Duration(seconds: 6),
      );
    }
  }

  String _formatearTiempo(int totalSegundos) {
    final int minutos = totalSegundos ~/ 60;
    final int segundos = totalSegundos % 60;
    return '${minutos.toString().padLeft(2, '0')}:${segundos.toString().padLeft(2, '0')}';
  }

  bool get _appEnPrimerPlano =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  // ============================================================
  // VIGILANCIA FUERA DE LA APP
  // Cada segundo pregunta a Android qué app está abierta.
  // - La primera app detectada se registra como "salio_de_app:<App>".
  // - Cada app distinta que abra después, como "cambio_app:<App>".
  // ============================================================
  void _iniciarVigilancia() {
    if (!_sesionIniciada) return;
    _inicioFuera ??= DateTime.now();
    if (_timerVigilancia?.isActive ?? false) return;
    _timerVigilancia = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _vigilar(),
    );
  }

  void _detenerVigilancia() {
    _timerVigilancia?.cancel();
    _timerVigilancia = null;
    _paqueteReportado = null;
    _salidaReportada = false;
    _inicioFuera = null;
  }

  Future<void> _vigilar() async {
    if (!_sesionIniciada || _isScreenLockedOrOff || _consultandoApp) return;
    if (_appEnPrimerPlano) return;

    _consultandoApp = true;
    try {
      final String? paquete =
          await _usoChannel.invokeMethod<String>('appActualExterna');

      // Pudo cambiar el estado mientras se consultaba
      if (!_sesionIniciada || _isScreenLockedOrOff || _appEnPrimerPlano) {
        return;
      }

      if (paquete == null) {
        // Sin permiso o sin datos: si lleva más de 3 s fuera,
        // se registra una salida genérica (una sola vez).
        final DateTime? inicio = _inicioFuera;
        if (!_salidaReportada &&
            inicio != null &&
            DateTime.now().difference(inicio) > const Duration(seconds: 3)) {
          _salidaReportada = true;
          _registrarAlerta('salio_de_app:Otra App');
        }
        return;
      }

      // Texto vacío = la app en primer plano es esta misma
      // (p. ej. detrás de la pantalla de bloqueo): no es una salida.
      if (paquete.isEmpty) return;

      if (paquete == _paqueteReportado) return; // sigue en la misma app
      _paqueteReportado = paquete;

      final String nombre = _nombreDeApp(paquete);
      if (!_salidaReportada) {
        _salidaReportada = true;
        _registrarAlerta('salio_de_app:$nombre');
      } else {
        _registrarAlerta('cambio_app:$nombre');
      }
    } catch (e) {
      debugPrint('Error consultando la app en primer plano: $e');
    } finally {
      _consultandoApp = false;
    }
  }

  // ============================================================
  // EVENTOS NATIVOS DE PANTALLA
  // ============================================================
  void _initScreenStateListener() {
    _screenSubscription = _screenChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (!_sesionIniciada) return;

        if (event == 'pantalla_bloqueada') {
          _isScreenLockedOrOff = true;
          _posibleNotificacion = false;
          _desbloqueoRegistrado = false;
          _timerNotificacion?.cancel();
          // Al desbloquear se vuelve a informar la app en la que aparezca
          _paqueteReportado = null;

          _registrarAlerta('pantalla_bloqueada');
        } else if (event == 'pantalla_encendida') {
          // Encendida pero aún en la pantalla de bloqueo: no se vigila
          // hasta que la desbloquee.
          if (!_appEnPrimerPlano) {
            _estaEnSegundoPlano = true;
          }
        } else if (event == 'pantalla_desbloqueada') {
          _isScreenLockedOrOff = false;
          // Se espera un momento: si al desbloquear vuelve a ESTA app no hay
          // alerta. Si entró a otra (p. ej. tocando una notificación en la
          // pantalla de bloqueo), se registra el desbloqueo y la app abierta.
          _timerDesbloqueo?.cancel();
          _timerDesbloqueo = Timer(const Duration(milliseconds: 1200), () {
            if (!_sesionIniciada || _isScreenLockedOrOff || _appEnPrimerPlano) {
              return;
            }
            _estaEnSegundoPlano = true;
            if (!_desbloqueoRegistrado) {
              _desbloqueoRegistrado = true;
              _registrarAlerta('desbloqueo');
            }
            _inicioFuera = DateTime.now();
            _iniciarVigilancia();
            _vigilar();
          });
        }
      },
      onError: (dynamic error) {
        debugPrint('Error en canal de pantalla: $error');
      },
    );
  }

  // ============================================================
  // CICLO DE VIDA DE LA APP
  // ============================================================
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_sesionIniciada) return;

    if (state == AppLifecycleState.inactive) {
      // "inactive" sin pasar a "paused" = bajó la barra de notificaciones
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

      // Empieza a vigilar a qué apps va. Si en realidad bloqueó la pantalla,
      // el evento "pantalla_bloqueada" pausa la vigilancia.
      _inicioFuera = DateTime.now();
      _iniciarVigilancia();
    } else if (state == AppLifecycleState.resumed) {
      if (_horaFinEnfoque != null) {
        final int diferenciaSegundos =
            _horaFinEnfoque!.difference(DateTime.now()).inSeconds;

        if (diferenciaSegundos <= 0) {
          _terminarClase(mostrarMensaje: true);
          return;
        }
        setState(() {
          _segundosRestantes = diferenciaSegundos;
        });
      }

      _timerNotificacion?.cancel();
      _timerDesbloqueo?.cancel();
      _detenerVigilancia();
      _desbloqueoRegistrado = false;

      _enviarPendientes();
      _verificarClaseVigente();

      if (_estaEnSegundoPlano || _isScreenLockedOrOff) {
        _registrarAlerta('regreso');
      }
      _estaEnSegundoPlano = false;
      _isScreenLockedOrOff = false;
      _posibleNotificacion = false;
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
      // Siempre en UTC (con "Z"). Sin zona horaria, Supabase la guardaba como
      // si ya fuera UTC y el panel mostraba la hora con 5 h de diferencia.
      'fecha_hora': (fecha ?? DateTime.now()).toUtc().toIso8601String(),
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
        'fecha_hora': DateTime.now().toUtc().toIso8601String(),
      });

      if (!mounted) return;

      setState(() {
        qrDetectado = codigo;
        _sesionIniciada = true;
      });

      // 3. Recordar la clase en el celular (por si cierra la app o la sesión)
      await _guardarSesionLocal(sesion, codigo);

      // 4. Iniciar monitoreo, servicio en primer plano y temporizador
      await _registrarAlerta('ingreso');
      if (!mounted) return;
      _iniciarModoEnfoque(sesion);
      _iniciarServicioMonitoreo();

      mostrarAviso(
        context,
        '¡Asistencia registrada! La clase ha comenzado.',
        tipo: TipoAviso.exito,
      );
    } catch (e) {
      debugPrint('Error registrando asistencia: $e');
      _mostrarError(
        'No se pudo registrar la asistencia. ${mensajeErrorGeneral(e)}',
      );
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
    mostrarAviso(context, mensaje, tipo: TipoAviso.error);
  }

  Future<void> _abrirEscanerQR() async {
    // Permiso de uso obligatorio; el de notificaciones es opcional
    final bool continuar = await _asegurarPermisoUso();
    if (!continuar || !mounted) return;
    await _pedirPermisoNotificaciones();
    if (!mounted) return;

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
            onPressed: _cerrarSesion,
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
