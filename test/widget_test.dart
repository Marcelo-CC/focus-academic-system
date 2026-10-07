import 'package:flutter_test/flutter_test.dart';
import 'package:estudiante_app/main.dart';

void main() {
  testWidgets('Smoke test de la aplicación', (WidgetTester tester) async {
    // Carga la aplicación principal
    await tester.pumpWidget(const MyApp());
  });
}