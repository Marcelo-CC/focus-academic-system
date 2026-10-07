import 'package:flutter/material.dart';
import 'config/supabase_config.dart';
import 'screens/estudiante_screen.dart';
import 'screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseConfig.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Comprobar si hay una sesión de Supabase guardada
    final session = SupabaseConfig.client.auth.currentSession;
    final user = SupabaseConfig.client.auth.currentUser;

    String? nombreEstudiante;
    if (user != null) {
      nombreEstudiante = user.userMetadata?['full_name'] ??
          user.email?.split('@').first.toUpperCase();
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Monitoreo Estudiante',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: session != null && nombreEstudiante != null
          ? EstudianteScreen(nombreEstudiante: nombreEstudiante)
          : const LoginScreen(),
    );
  }
}