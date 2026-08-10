import 'package:flutter/services.dart';

/// Dart side of the reply_bridge plugin — see this package's
/// pubspec.yaml doc comment for why it exists as a real plugin rather
/// than a plain MethodChannel wired into MainActivity, and see
/// PushNotificationService.handleChatReply for the only caller.
class ReplyBridge {
  ReplyBridge._();

  static const _channel = MethodChannel('reality_merge/reply_bridge');

  /// Starts a minimal, silent Android foreground service for as long
  /// as the caller needs guaranteed background network access — e.g.
  /// while sending a notification reply from a background isolate,
  /// where Doze/App Standby would otherwise be free to defer the
  /// request until Android's next maintenance window. Android-only;
  /// a no-op (successfully, not an error) on any other platform.
  ///
  /// Safe to call more than once — idempotent on the native side, and
  /// each call pushes the safety-net auto-stop back out. Always pair
  /// with [stop] once the work is done, ideally in a `finally` block
  /// — the native side self-stops after a timeout regardless, but
  /// that's a backstop for a crashed/killed isolate, not something to
  /// rely on for normal flow.
  static Future<void> start() async {
    try {
      await _channel.invokeMethod('start');
    } catch (_) {
      // Best-effort — if this fails (channel not reachable from this
      // engine, an OEM blocking foreground service starts outright,
      // etc.) the caller still gets a normal best-effort attempt,
      // just without the Doze exemption this buys on top.
    }
  }

  /// Stops the foreground service started by [start]. Safe to call
  /// even if [start] was never called, or was already stopped.
  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
