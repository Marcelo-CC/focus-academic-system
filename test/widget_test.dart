import 'package:estudiante_app/screens/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('La pantalla de login se muestra y valida campos vacíos',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));

    expect(find.text('Acceso Estudiantes'), findsOneWidget);
    expect(find.text('Correo Institucional'), findsOneWidget);

    // Sin correo ni contraseña: muestra el aviso y no intenta conectarse
    await tester.tap(find.text('Iniciar Sesión'));
    await tester.pump();
    expect(find.text('Completa tu correo y tu contraseña.'), findsOneWidget);
  });
}
