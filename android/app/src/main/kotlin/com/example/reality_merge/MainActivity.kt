package com.example.reality_merge

import android.graphics.Rect
import android.os.Build
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/// Handles the "reality_merge/gesture_exclusion" channel so Dart can
/// reserve a strip of the screen (e.g. the left edge, for the
/// Explore-tab drawer) from Android's gesture-navigation back swipe.
/// Without this, a swipe starting near the left edge on gesture-nav
/// devices is intercepted by the OS as "go back" before it ever
/// reaches Flutter's Drawer edge-drag recognizer.
///
/// Also handles "reality_merge/sms_gateway" (send a real SMS, read the
/// SIM's own number, start/stop the gateway foreground service) and
/// streams real incoming SMS to Dart over
/// "reality_merge/sms_gateway/incoming". See SmsReceiver.kt and
/// SmsGatewayForegroundService.kt for the other half of this.
class MainActivity : FlutterActivity() {
    private val gestureChannelName = "reality_merge/gesture_exclusion"
    private val smsChannelName = "reality_merge/sms_gateway"
    private val smsEventChannelName = "reality_merge/sms_gateway/incoming"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Cached under a stable id so SmsGatewayForegroundService can
        // reuse this exact engine (and therefore this exact Dart
        // isolate/EventChannel listener) to push incoming-SMS events
        // even after this Activity itself is destroyed — as long as
        // the process stays alive, which the foreground service's
        // notification is what keeps Android from reclaiming it.
        FlutterEngineCache.getInstance().put("sms_gateway_engine", flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, gestureChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setLeftEdgeExclusion" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        setLeftEdgeExclusion(enabled)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, smsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sendSms" -> {
                        val phoneNumber = call.argument<String>("phoneNumber")
                        val body = call.argument<String>("body")
                        if (phoneNumber == null || body == null) {
                            result.error("bad_args", "phoneNumber and body are required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            sendSms(phoneNumber, body)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("send_failed", e.message, null)
                        }
                    }
                    "getSimNumber" -> {
                        result.success(getSimNumber())
                    }
                    "startForegroundService" -> {
                        SmsGatewayForegroundService.start(applicationContext)
                        result.success(null)
                    }
                    "stopForegroundService" -> {
                        SmsGatewayForegroundService.stop(applicationContext)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, smsEventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    IncomingSmsBridge.attach(sink)
                }

                override fun onCancel(arguments: Any?) {
                    IncomingSmsBridge.detach()
                }
            })
    }

    /// Splits into multiple parts automatically for bodies longer than
    /// one SMS segment (SmsManager handles the 160/153-char GSM-7 or
    /// 70/67-char UCS-2 math and concatenation headers internally).
    private fun sendSms(phoneNumber: String, body: String) {
        val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }
        val parts = smsManager.divideMessage(body)
        if (parts.size <= 1) {
            smsManager.sendTextMessage(phoneNumber, null, body, null, null)
        } else {
            smsManager.sendMultipartTextMessage(phoneNumber, null, parts, null, null)
        }
    }

    private fun getSimNumber(): String? {
        return try {
            val tm = getSystemService(TELEPHONY_SERVICE) as TelephonyManager
            @Suppress("DEPRECATION")
            tm.line1Number?.takeIf { it.isNotBlank() }
        } catch (e: SecurityException) {
            null
        }
    }

    private fun setLeftEdgeExclusion(enabled: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val decorView = window?.decorView ?: return
        if (!enabled) {
            decorView.systemGestureExclusionRects = emptyList()
            return
        }
        // Reserve a strip along the full height of the left edge, wide
        // enough to comfortably win the drag-to-open-drawer gesture.
        val width = decorView.width
        val height = decorView.height
        if (width <= 0 || height <= 0) {
            // Layout hasn't happened yet — try again next frame.
            decorView.post { setLeftEdgeExclusion(true) }
            return
        }
        val exclusionWidthPx = (40 * resources.displayMetrics.density).toInt()
        decorView.systemGestureExclusionRects =
            listOf(Rect(0, 0, exclusionWidthPx, height))
    }
}
