package com.example.estudiante_app

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
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
        // App en primer plano, permisos y servicio de monitoreo
        // ------------------------------------------------------------
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, USO_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "tienePermisoUso" -> result.success(UsoApps.tienePermiso(this))
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
                    AvisosSalida.cancelar(this)
                    result.success(null)
                }
                // Los avisos de "10 segundos" los muestra el servicio nativo;
                // Flutter solo los quita al volver a la app (por si acaso).
                "cancelarAvisoSalida" -> {
                    AvisosSalida.cancelar(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
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
        val actual = UsoApps.appEnPrimerPlano(this) ?: return null
        return if (actual == packageName) "" else actual
    }

    /**
     * Devuelve el paquete de la última app (distinta a esta) que pasó a primer plano
     * en los últimos [segundos] segundos, o null si no hay datos / no hay permiso.
     */
    private fun ultimaAppEnPrimerPlano(segundos: Int): String? {
        if (!UsoApps.tienePermiso(this)) return null

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
