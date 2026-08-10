package com.example.reality_merge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import androidx.core.content.ContextCompat

/// Registered in AndroidManifest.xml for
/// android.provider.Telephony.SMS_RECEIVED — this fires even if the
/// app's Activity isn't open, as long as the app hasn't been force-
/// stopped by the user or the OS. Concatenated multi-part SMS arrive
/// as separate PDUs with the same originating address in quick
/// succession; Telephony.Sms.Intents already reassembles them into
/// one array per broadcast, so we just join the message bodies.
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isNullOrEmpty()) return

        val from = messages[0].originatingAddress ?: return
        val body = messages.joinToString(separator = "") { it.messageBody ?: "" }
        if (body.isBlank()) return

        // Forward to whichever consumer is available right now:
        // - If Gateway mode is running, IncomingSmsBridge has a live
        //   EventChannel sink and this reaches Dart within a beat.
        // - If not (app cold, engine not yet attached), it queues in
        //   IncomingSmsBridge until Gateway mode next starts and drains it.
        IncomingSmsBridge.onIncomingSms(from, body)

        // Also (re)start the foreground service so a text that arrives
        // while the app process is fully dead brings the gateway back
        // up rather than silently going unanswered until next manual
        // open. If the service (and its cached engine) are already
        // running this is a cheap no-op.
        ContextCompat.startForegroundService(
            context,
            Intent(context, SmsGatewayForegroundService::class.java)
        )
    }
}
