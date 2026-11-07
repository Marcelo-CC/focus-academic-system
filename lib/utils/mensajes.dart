import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Convierte los errores técnicos de Supabase en mensajes claros para el estudiante.
String mensajeErrorLogin(Object error) {
  if (error is AuthRetryableFetchException ||
      error is SocketException ||
      error is TimeoutException) {
    return 'Sin conexión a internet. Revisa tu red e inténtalo de nuevo.';
  }
  if (error is AuthException) {
    switch (error.code) {
      case 'invalid_credentials':
        return 'Correo o contraseña incorrectos.';
      case 'email_not_confirmed':
        return 'Tu correo aún no ha sido confirmado. Revisa tu bandeja de entrada.';
      case 'user_banned':
        return 'Tu cuenta está bloqueada. Comunícate con tu docente.';
      case 'over_request_rate_limit':
      case 'over_email_send_rate_limit':
        return 'Demasiados intentos. Espera un momento y vuelve a intentarlo.';
      case 'validation_failed':
        return 'Escribe un correo válido.';
    }
    if (error.statusCode == '400') return 'Correo o contraseña incorrectos.';
  }
  return 'No se pudo iniciar sesión. Inténtalo de nuevo.';
}

/// Mensaje claro para errores al guardar datos (asistencia, etc.).
String mensajeErrorGeneral(Object error) {
  if (error is SocketException ||
      error is TimeoutException ||
      error is AuthRetryableFetchException) {
    return 'Sin conexión a internet. Revisa tu red e inténtalo de nuevo.';
  }
  return 'Ocurrió un problema. Inténtalo de nuevo en unos segundos.';
}

enum TipoAviso { exito, error, advertencia, info }

/// Muestra un aviso flotante con ícono, con un estilo uniforme en toda la app.
void mostrarAviso(
  BuildContext context,
  String mensaje, {
  TipoAviso tipo = TipoAviso.info,
  Duration duracion = const Duration(seconds: 4),
}) {
  final (Color color, IconData icono) = switch (tipo) {
    TipoAviso.exito => (const Color(0xFF2E7D32), Icons.check_circle_rounded),
    TipoAviso.error => (const Color(0xFFC62828), Icons.error_rounded),
    TipoAviso.advertencia => (const Color(0xFFEF6C00), Icons.warning_rounded),
    TipoAviso.info => (const Color(0xFF3949AB), Icons.info_rounded),
  };

  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: color,
        duration: duracion,
        content: Row(
          children: [
            Icon(icono, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                mensaje,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
}
