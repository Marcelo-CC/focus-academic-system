package com.example.estudiante_app

import android.app.AppOpsManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Process
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val SCREEN_CHANNEL = "com.example.estudiante_app/screen_events"
    private val USO_CHANNEL = "com.example.estudiante_app/uso_apps"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ------------------------------------------------------------
        // Eventos de pantalla (bloqueo / encendido / desbloqueo)
        // ------------------------------------------------------------
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SCREEN_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                private var receiver: BroadcastReceiver? = null

                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    val filter = IntentFilter().apply {
                        addAction(Intent.ACTION_SCREEN_OFF)
                        addAction(Intent.ACTION_SCREEN_ON)
                        addAction(Intent.ACTION_USER_PRESENT)
                    }

                    receiver = object : BroadcastReceiver() {
                        override fun onReceive(context: Context?, intent: Intent?) {
                            when (intent?.action) {
                                Intent.ACTION_SCREEN_OFF -> events?.success("pantalla_bloqueada")
                                Intent.ACTION_SCREEN_ON -> events?.success("pantalla_encendida")
                                Intent.ACTION_USER_PRESENT -> events?.success("pantalla_desbloqueada")
                            }
                        }
                    }
                    registerReceiver(receiver, filter)
                }

                override fun onCancel(arguments: Any?) {
                    receiver?.let {
                        try {
                            unregisterReceiver(it)
                        } catch (_: IllegalArgumentException) {
                            // Ya estaba desregistrado
                        }
                    }
                    receiver = null
                }
            }
        )

        // ------------------------------------------------------------
        // Detección de la app en primer plano (reemplaza a app_usage)
        // ------------------------------------------------------------
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, USO_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "tienePermisoUso" -> result.success(tienePermisoUso())
                "abrirAjustesUso" -> {
                    abrirAjustesUso()
                    result.success(null)
                }
                "ultimaAppEnPrimerPlano" -> {
                    val segundos = call.argument<Int>("segundos") ?: 30
                    result.success(ultimaAppEnPrimerPlano(segundos))
                }
                "appActualExterna" -> result.success(appActualExterna())
                "iniciarMonitoreo" -> {
                    try {
                        MonitoreoService.iniciar(this)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICIO", e.message, null)
                    }
                }
                "detenerMonitoreo" -> {
                    MonitoreoService.detener(this)
                    cancelarAvisoSalida()
                    result.success(null)
                }
                "mostrarAvisoSalida" -> {
                    val segundos = call.argument<Int>("segundos") ?: 10
                    mostrarAvisoSalida(segundos)
                    result.success(null)
                }
                "avisoTiempoAgotado" -> {
                    avisoTiempoAgotado()
                    result.success(null)
                }
                "cancelarAvisoSalida" -> {
                    cancelarAvisoSalida()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // ------------------------------------------------------------
    // Aviso emergente "Tienes 10 segundos para volver a la clase"
    // ------------------------------------------------------------
    private val CANAL_AVISO = "aviso_salida"
    private val ID_AVISO = 2001

    private fun notificationManager(): NotificationManager {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(CANAL_AVISO) == null
        ) {
            // Importancia ALTA: aparece como aviso emergente arriba de la pantalla
            val canal = NotificationChannel(
                CANAL_AVISO,
                "Avisos de salida de la clase",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Avisa cuando sales de la app durante la clase"
                enableVibration(true)
            }
            manager.createNotificationChannel(canal)
        }
        return manager
    }

    private fun constructorAviso(): Notification.Builder {
        val abrirApp = PendingIntent.getActivity(
            this,
            1,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CANAL_AVISO)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_HIGH)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_monitoreo)
            .setContentIntent(abrirApp)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
    }

    private fun mostrarAvisoSalida(segundos: Int) {
        val notificacion = constructorAviso()
            .setContentTitle("⚠ Saliste de la clase")
            .setContentText("Tienes $segundos segundos para volver a la app.")
            // Cuenta regresiva visible en la notificación
            .setWhen(System.currentTimeMillis() + segundos * 1000L)
            .setShowWhen(true)
            .setUsesChronometer(true)
            .setChronometerCountDown(true)
            .build()
        notificationManager().notify(ID_AVISO, notificacion)
    }

    private fun avisoTiempoAgotado() {
        val notificacion = constructorAviso()
            .setContentTitle("Se agotó el tiempo")
            .setContentText("Tu salida quedó registrada para el docente. Vuelve a la clase.")
            .build()
        notificationManager().notify(ID_AVISO, notificacion)
    }

    private fun cancelarAvisoSalida() {
        getSystemService(NotificationManager::class.java).cancel(ID_AVISO)
    }

    private fun tienePermisoUso(): Boolean {
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val modo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName
            )
        }
        return modo == AppOpsManager.MODE_ALLOWED
    }

    private fun abrirAjustesUso() {
        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).apply {
            // En algunos equipos abre directamente la ficha de esta app
            data = Uri.parse("package:$packageName")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            startActivity(intent)
        } catch (_: Exception) {
            // Si el fabricante no admite el "package:", se abre la lista general
            startActivity(
                Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }

    /**
     * App que está en primer plano AHORA MISMO:
     *  - el nombre del paquete si es OTRA app,
     *  - "" (texto vacío) si es esta misma app,
     *  - null si no hay permiso o no hay datos.
     */
    private fun appActualExterna(): String? {
        if (!tienePermisoUso()) return null

        val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val fin = System.currentTimeMillis()
        val inicio = fin - 60 * 60 * 1000L // última hora

        val eventos = usm.queryEvents(inicio, fin)
        val evento = UsageEvents.Event()
        var actual: String? = null
        var tiempo = 0L

        while (eventos.hasNextEvent()) {
            eventos.getNextEvent(evento)
            @Suppress("DEPRECATION")
            if (evento.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND &&
                evento.timeStamp >= tiempo
            ) {
                actual = evento.packageName
                tiempo = evento.timeStamp
            }
        }
        return if (actual == packageName) "" else actual
    }

    /**
     * Devuelve el paquete de la última app (distinta a esta) que pasó a primer plano
     * en los últimos [segundos] segundos, o null si no hay datos / no hay permiso.
     */
    private fun ultimaAppEnPrimerPlano(segundos: Int): String? {
        if (!tienePermisoUso()) return null

        val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val fin = System.currentTimeMillis()
        val inicio = fin - segundos * 1000L

        val eventos = usm.queryEvents(inicio, fin)
        val evento = UsageEvents.Event()
        var ultimoPaquete: String? = null
        var ultimoTiempo = 0L

        while (eventos.hasNextEvent()) {
            eventos.getNextEvent(evento)
            @Suppress("DEPRECATION")
            val esPrimerPlano = evento.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND
            if (esPrimerPlano &&
                evento.packageName != packageName &&
                evento.timeStamp >= ultimoTiempo
            ) {
                ultimoPaquete = evento.packageName
                ultimoTiempo = evento.timeStamp
            }
        }
        return ultimoPaquete
    }
}
