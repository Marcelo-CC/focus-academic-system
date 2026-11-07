package com.example.estudiante_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Servicio en primer plano que se mantiene activo mientras dura la clase.
 *
 * Desde Android 14 el sistema "congela" las apps en segundo plano a los pocos
 * segundos. Mientras este servicio está activo (con su notificación fija),
 * Android NO congela la app, así que puede seguir detectando a qué apps va el
 * estudiante, los bloqueos y desbloqueos de pantalla.
 */
class MonitoreoService : Service() {

    companion object {
        private const val CANAL_ID = "monitoreo_clase"
        private const val NOTIFICACION_ID = 1001

        fun iniciar(context: Context) {
            val intent = Intent(context, MonitoreoService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun detener(context: Context) {
            context.stopService(Intent(context, MonitoreoService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        crearCanal()

        val abrirApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CANAL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val notificacion = builder
            .setContentTitle("Clase en curso")
            .setContentText("Modo Enfoque activo: tu actividad está siendo monitoreada.")
            .setSmallIcon(R.drawable.ic_stat_monitoreo)
            .setContentIntent(abrirApp)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICACION_ID,
                notificacion,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICACION_ID, notificacion)
        }

        // Si el sistema mata el proceso, no se reinicia solo:
        // la app retoma la clase cuando el estudiante la vuelve a abrir.
        return START_NOT_STICKY
    }

    private fun crearCanal() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CANAL_ID) == null) {
            val canal = NotificationChannel(
                CANAL_ID,
                "Monitoreo de clase",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Aviso fijo mientras el Modo Enfoque está activo"
                setShowBadge(false)
            }
            manager.createNotificationChannel(canal)
        }
    }
}
