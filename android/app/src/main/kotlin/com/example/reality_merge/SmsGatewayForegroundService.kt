package com.example.reality_merge

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
import androidx.core.app.NotificationCompat

/// A minimal foreground service whose only real job is to hold a
/// visible notification so Android doesn't reclaim this process while
/// Gateway mode is on. As long as this process stays alive, the
/// FlutterEngine cached by MainActivity (id "sms_gateway_engine")
/// stays alive too, which is what lets SmsReceiver -> IncomingSmsBridge
/// reach Dart's EventChannel listener without a UI on screen.
///
/// Known limitation: this does NOT survive a full device reboot or the
/// user force-stopping the app from system settings — Android won't
/// run any of this app's code again until it's opened once more. For
/// most "phone stays on and charging" gateway setups that's fine; a
/// fully reboot-proof gateway would additionally need a BOOT_COMPLETED
/// receiver and a way to re-authenticate without user interaction,
/// which is a reasonable next step but out of scope here.
class SmsGatewayForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "sms_gateway_channel"
        private const val NOTIFICATION_ID = 4201

        fun start(context: Context) {
            val intent = Intent(context, SmsGatewayForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SmsGatewayForegroundService::class.java))
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // START_STICKY: if the OS kills this process under memory
        // pressure, ask it to recreate the service (without the
        // original intent) as soon as resources free up, rather than
        // leaving Gateway mode silently stopped.
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "SMS Gateway",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Keeps the SMS bridge running so messages sync in the background."
        }
        manager?.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("SMS Gateway active")
            .setContentText("Relaying messages between chat and SMS.")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .build()
    }
}
