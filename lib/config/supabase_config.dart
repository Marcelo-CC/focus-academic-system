import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfig {
  // Los valores se leen de config/supabase.json (no se sube a GitHub).
  // Compilar/ejecutar con: --dart-define-from-file=config/supabase.json
  // Usar SOLO la clave pública (sb_publishable_...), nunca una sb_secret_...
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabasePublishableKey =
      String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  static Future<void> init() async {
    if (supabaseUrl.isEmpty || supabasePublishableKey.isEmpty) {
      throw StateError(
        'Falta la configuración de Supabase. Crea config/supabase.json '
        '(copia config/supabase.example.json) y ejecuta con '
        '--dart-define-from-file=config/supabase.json',
      );
    }
    await Supabase.initialize(
      url: supabaseUrl,
      publishableKey: supabasePublishableKey,
    );
  }

  static SupabaseClient get client => Supabase.instance.client;

  /// Nombre a mostrar del estudiante: usa `full_name` de los metadatos
  /// y, si no existe, la parte inicial del correo en mayúsculas.
  static String nombreDeUsuario(User user) {
    final dynamic nombre = user.userMetadata?['full_name'];
    if (nombre is String && nombre.trim().isNotEmpty) return nombre.trim();
    final String? email = user.email;
    if (email != null && email.isNotEmpty) {
      return email.split('@').first.toUpperCase();
    }
    return 'ESTUDIANTE';
  }
}