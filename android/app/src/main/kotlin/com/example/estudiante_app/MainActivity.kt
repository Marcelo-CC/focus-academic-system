package com.example.estudiante_app

import android.app.AppOpsManager
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
                else -> result.notImplemented()
            }
        }
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
