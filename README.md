# Sistema Regulador de Aula — App Estudiante

App Flutter (Android) para el monitoreo de estudiantes en clase + panel web del docente (`index.html`), con backend en Supabase.

## Configuración (claves de Supabase)

Las claves **no se suben a GitHub**. Después de clonar el proyecto:

1. **App Flutter:** copia `config/supabase.example.json` como `config/supabase.json` y pon la URL y la clave pública (`sb_publishable_...`) de tu proyecto Supabase.
2. **Panel docente:** copia `config.example.js` como `config.js` y pon los mismos datos.

> Usa solo la clave **publishable**. Nunca pongas una clave `sb_secret_...` en la app ni en la web.

## Base de datos

Ejecuta en Supabase (SQL Editor) los scripts de la carpeta `supabase/`:

| Script | Para qué |
|---|---|
| `001_estudiante_id_y_rls.sql` | Columna `estudiante_id` y seguridad básica (RLS) |
| `002_docentes_y_limpieza.sql` | Tabla de docentes y permiso para restablecer registros |
| `003_crear_estudiantes.sql` | Crea las cuentas ESTUDIANTE3…25 (contraseña 123456) |
| `004_simular_datos.sql` | *(antiguo, ya no es necesario)* |
| `005_clase_y_aula.sql` | Columnas de asignatura y aula en cada registro |
| `006_preguntas_relampago.sql` | Preguntas relámpago (tablas, funciones y tiempo real) |
| `007_simular_7_dias.sql` | **Borra todos los datos** y simula 7 días de clase (demo) |
| `008_seguridad.sql` | Solo los docentes manejan la clase y ven a todos los estudiantes |

Para agregar otro docente, repite en `008_seguridad.sql` la línea `insert into public.docentes …` con su correo.

## Ejecutar

```bash
flutter pub get
flutter run --dart-define-from-file=config/supabase.json
```

En VS Code basta con presionar **F5** (ya está configurado en `.vscode/launch.json`).

Compilar APK:

```bash
flutter build apk --release --dart-define-from-file=config/supabase.json
```

Pruebas del cálculo de puntos, rachas y tiempo fuera:

```bash
flutter test test/metricas_enfoque_test.dart
```
