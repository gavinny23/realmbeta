package com.example.reality_merge

import io.flutter.plugin.common.EventChannel
import java.util.concurrent.ConcurrentLinkedQueue

/// Sits between SmsReceiver (which can fire with no Dart engine
/// listening yet) and the "reality_merge/sms_gateway/incoming"
/// EventChannel in MainActivity. Incoming SMS that arrive before
/// Dart's SmsGatewayBridge has attached a listener (e.g. the very
/// first text after a cold start) are queued and flushed as soon as
/// one attaches, instead of being dropped.
object IncomingSmsBridge {
    private var sink: EventChannel.EventSink? = null
    private val pending = ConcurrentLinkedQueue<Map<String, String>>()

    @Synchronized
    fun attach(newSink: EventChannel.EventSink) {
        sink = newSink
        while (true) {
            val event = pending.poll() ?: break
            newSink.success(event)
        }
    }

    @Synchronized
    fun detach() {
        sink = null
    }

    @Synchronized
    fun onIncomingSms(from: String, body: String) {
        val event = mapOf("from" to from, "body" to body)
        val currentSink = sink
        if (currentSink != null) {
            currentSink.success(event)
        } else {
            pending.add(event)
        }
    }
}
