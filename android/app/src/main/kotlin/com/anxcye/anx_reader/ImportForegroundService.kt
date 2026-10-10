package com.anxcye.anx_reader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.MethodChannel

/**
 * Foreground service that keeps folder imports running while the app is in
 * the background or the device dozes: it holds a partial wake lock, shows a
 * persistent progress notification, and exposes start/update/stop through
 * the "import_service" MethodChannel (driven by ImportProgressService).
 * Already-imported books survive any interruption via the persisted
 * resume task, so a killed service never loses work.
 */
class ImportForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?) = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createChannel()
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int
    ): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val name = intent?.getStringExtra(EXTRA_NAME) ?: ""
                val total = intent?.getIntExtra(EXTRA_TOTAL, 0) ?: 0
                startForeground(NOTIFICATION_ID, buildNotification(name, 0, total))
                acquireWakeLock()
            }
        }
        return START_STICKY
    }

    fun updateProgress(name: String, imported: Int, total: Int) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(name, imported, total))
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "anx:import")
        wakeLock?.acquire(60 * 60 * 1000L) // safety cap: 1 hour
    }

    override fun onDestroy() {
        instance = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Import progress",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(name: String, imported: Int, total: Int): Notification {
        val text = if (total > 0) "$name: $imported/$total" else name
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationCompat.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            NotificationCompat.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Importing books")
            .setContentText(text)
            .setProgress(if (total > 0) total else 0, imported, total <= 0)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    companion object {
        @Volatile
        private var instance: ImportForegroundService? = null

        /** Called from the MethodChannel while the service is alive. */
        fun updateLive(context: Context, name: String, imported: Int, total: Int) {
            instance?.updateProgress(name, imported, total)
                ?: start(context, name, total)
        }

        const val CHANNEL_ID = "anx_import"
        const val NOTIFICATION_ID = 4711
        const val ACTION_STOP = "com.anxcye.anx_reader.import.STOP"
        const val EXTRA_NAME = "name"
        const val EXTRA_TOTAL = "total"

        fun start(context: Context, name: String, total: Int) {
            val intent = Intent(context, ImportForegroundService::class.java)
                .putExtra(EXTRA_NAME, name)
                .putExtra(EXTRA_TOTAL, total)
            context.startForegroundService(intent)
        }

        fun update(context: Context, name: String, imported: Int, total: Int) {
            val intent = Intent(context, ImportForegroundService::class.java)
            intent.putExtra(EXTRA_NAME, name)
            intent.putExtra(EXTRA_TOTAL, total)
            intent.putExtra("imported", imported)
            context.startService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, ImportForegroundService::class.java)
                .setAction(ACTION_STOP)
            context.startService(intent)
        }
    }
}
