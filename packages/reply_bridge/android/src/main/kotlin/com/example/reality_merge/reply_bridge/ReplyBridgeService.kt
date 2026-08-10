package com.example.reality_merge.reply_bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat

/// A minimal, near-invisible foreground service whose only job is to
/// lift this app's whole process into Android's "foreground"
/// execution state for the few seconds a notification reply's network
/// call needs. Foreground services are specifically exempt from
/// Doze/App Standby's network deferral, regardless of whether the
/// person has granted the separate "Unrestricted battery" exemption —
/// this is the same mechanism WhatsApp/Signal/etc. rely on for
/// reply-from-notification to work reliably under default battery
/// settings. See PushNotificationService.handleChatReply (via
/// ReplyBridge) for the only caller.
///
/// Deliberately uses IMPORTANCE_MIN so it doesn't visually compete
/// with the actual chat notification flutter_local_notifications is
/// already showing/updating — Android still requires *a* notification
/// to run a foreground service at all; this keeps it as quiet as the
/// platform allows (no sound, minimal/no shade presence on most
/// versions) rather than a second visible "Sending…" banner.
class ReplyBridgeService : Service() {
    companion object {
        private const val CHANNEL_ID = "reply_bridge_channel"
        private const val NOTIFICATION_ID = 4301

        // Safety net only — ReplyBridge.stop() is expected to end
        // this within a second or two of the reply attempt finishing.
        // This just guarantees the service (and the Doze exemption
        // riding on it) never outlives a crashed/killed isolate that
        // never got to call it.
        private const val SAFETY_TIMEOUT_MS = 20_000L

        /// Set from ReplyBridgePlugin.onAttachedToEngine — always the
        /// application context, since this can be started from a
        /// headless engine with no Activity at all.
        var appContext: Context? = null

        private var running = false
        private val handler = Handler(Looper.getMainLooper())
        private var safetyStop: Runnable? = null

        fun start() {
            val context = appContext ?: return
            if (running) {
                // Already up for a previous/overlapping reply — just
                // push the safety timeout back out rather than
                // starting a redundant second instance.
                safetyStop?.let { handler.removeCallbacks(it) }
            } else {
                val intent = Intent(context, ReplyBridgeService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                running = true
            }
            val stopRunnable = Runnable { stop() }
            safetyStop = stopRunnable
            handler.postDelayed(stopRunnable, SAFETY_TIMEOUT_MS)
        }

        fun stop() {
            safetyStop?.let { handler.removeCallbacks(it) }
            safetyStop = null
            if (!running) return
            running = false
            val context = appContext ?: return
            context.stopService(Intent(context, ReplyBridgeService::class.java))
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
        // Not START_STICKY on purpose, unlike SmsGatewayForegroundService
        // — this is meant to be short-lived and explicitly stopped by
        // ReplyBridge.stop() (or the safety timeout above). There's
        // nothing useful to "recreate" if the OS kills it; a fresh
        // reply attempt starts its own instance from scratch anyway.
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Sending replies",
            NotificationManager.IMPORTANCE_MIN
        ).apply {
            description = "Brief, silent background time while a chat reply sends."
            setShowBadge(false)
        }
        manager?.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Sending…")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .build()
    }
}
