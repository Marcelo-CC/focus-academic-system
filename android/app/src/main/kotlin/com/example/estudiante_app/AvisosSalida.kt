package com.example.estudiante_app

import android.app.AppOpsManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Process

/**
 * Consulta de la app en primer plano (requiere "Acceso a datos de uso").
 */
object UsoApps {

    /** Pantalla de bloqueo, barra de notificaciones, etc. (no son apps). */
    fun esPantallaDelSistema(paquete: String): Boolean {
        val pkg = paquete.lowercase()
        return pkg == "android" ||
            pkg.contains("systemui") ||
            pkg.contains("keyguard") ||
            pkg.contains("lockscreen") ||
            pkg.contains(".aod") ||
            pkg.contains("aodservice")
    }

    fun tienePermiso(context: Context): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val modo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName
            )
        }
        return modo == AppOpsManager.MODE_ALLOWED
    }

    /**
     * Paquete de la app que está en primer plano AHORA MISMO
     * (puede ser esta misma app), o null si no hay permiso o datos.
     */
    fun appEnPrimerPlano(context: Context): String? {
        if (!tienePermiso(context)) return null

        val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
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
        return actual
    }
}

/**
 * Avisos emergentes al estudiante cuando sale de la app durante la clase:
 *  - "Tienes 10 segundos para volver" (con cuenta regresiva)
 *  - "Cometiste una falta grave" (si no volvió a tiempo)
 */
object AvisosSalida {

    const val SEGUNDOS_PARA_VOLVER = 10

    private const val CANAL = "aviso_salida"
    private const val ID = 2001

    private fun manager(context: Context): NotificationManager {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(CANAL) == null
        ) {
            // Importancia ALTA: aparece como aviso emergente arriba de la pantalla
            val canal = NotificationChannel(
                CANAL,
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

    private fun constructor(context: Context): Notification.Builder {
        val abrirApp = PendingIntent.getActivity(
            context,
            1,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CANAL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context).setPriority(Notification.PRIORITY_HIGH)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_monitoreo)
            .setContentIntent(abrirApp)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
    }

    fun mostrarCuentaRegresiva(context: Context) {
        val notificacion = constructor(context)
            .setContentTitle("⚠ Saliste de la clase")
            .setContentText("Tienes $SEGUNDOS_PARA_VOLVER segundos para volver a la app.")
            // Cuenta regresiva visible en la notificación
            .setWhen(System.currentTimeMillis() + SEGUNDOS_PARA_VOLVER * 1000L)
            .setShowWhen(true)
            .setUsesChronometer(true)
            .setChronometerCountDown(true)
            .build()
        manager(context).notify(ID, notificacion)
    }

    fun mostrarFaltaGrave(context: Context) {
        val texto = "No volviste a la clase en $SEGUNDOS_PARA_VOLVER segundos. " +
            "Se registró como falta grave (cuenta como 2 distracciones)."
        val notificacion = constructor(context)
            .setContentTitle("🚨 Cometiste una falta grave")
            .setContentText(texto)
            .setStyle(Notification.BigTextStyle().bigText("$texto Vuelve a la app ahora."))
            .build()
        manager(context).notify(ID, notificacion)
    }

    fun cancelar(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(ID)
    }
}
