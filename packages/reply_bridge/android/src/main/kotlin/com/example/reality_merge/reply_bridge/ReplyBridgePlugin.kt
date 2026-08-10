package com.example.reality_merge.reply_bridge

import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/// Registered automatically on every FlutterEngine this app creates —
/// including flutter_local_notifications' own background-isolate
/// engine — because this is declared as a real plugin dependency (see
/// this package's pubspec.yaml), not wired manually into just
/// MainActivity. That's what lets ReplyBridge.start()/stop() reach
/// this from a notification-reply background isolate at all.
class ReplyBridgePlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "reality_merge/reply_bridge")
        channel.setMethodCallHandler(this)
        // Always the application context, never an Activity one —
        // this plugin may be attached to a headless engine with no
        // Activity in sight at all.
        ReplyBridgeService.appContext = binding.applicationContext
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        when (call.method) {
            "start" -> {
                ReplyBridgeService.start()
                result.success(null)
            }
            "stop" -> {
                ReplyBridgeService.stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
