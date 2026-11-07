# Sistema Regulador de Aula — App Estudiante

App Flutter (Android) para el monitoreo de estudiantes en clase + panel web del docente (`index.html`), con backend en Supabase.

## Configuración (claves de Supabase)

Las claves **no se suben a GitHub**. Después de clonar el proyecto:

1. **App Flutter:** copia `config/supabase.example.json` como `config/supabase.json` y pon la URL y la clave pública (`sb_publishable_...`) de tu proyecto Supabase.
2. **Panel docente:** copia `config.example.js` como `config.js` y pon los mismos datos.

> Usa solo la clave **publishable**. Nunca pongas una clave `sb_secret_...` en la app ni en la web.

## Base de datos

Ejecuta en Supabase (SQL Editor) los scripts de la carpeta `supabase/` en orden.

## Ejecutar

```bash
flutter pub get
flutter run --dart-define-from-file=config/supabase.json
```

En VS Code basta con presionar **F5** (ya está configurado en `.vscode/launch.json`).

Compilar APK:

```bash
flutter build apk --dart-define-from-file=config/supabase.json
```
