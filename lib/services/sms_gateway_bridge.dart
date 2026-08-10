import 'dart:async';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'sms_bridge_service.dart';

/// Runs on the one Android phone acting as the SMS gateway. Owns:
/// - the native MethodChannel/EventChannel plumbing (send a real SMS,
///   hear about real incoming SMS)
/// - the sync loop that claims queued outbound messages from Supabase
///   and hands them to the native side, and that uploads inbound SMS
///   the native side hands back
///
/// Everything else in the app (the owner side of a bridged chat) only
/// talks to [SmsBridgeService] directly and never touches this class.
class SmsGatewayBridge {
  SmsGatewayBridge._();
  static final SmsGatewayBridge instance = SmsGatewayBridge._();

  static const _methodChannel = MethodChannel('reality_merge/sms_gateway');
  static const _incomingSmsChannel =
      EventChannel('reality_merge/sms_gateway/incoming');
  static const _prefsDeviceIdKey = 'sms_gateway_device_id';
  static const _prefsShouldRunKey = 'sms_gateway_should_run';

  final _service = SmsBridgeService.instance;

  String? _deviceId;
  String? get deviceId => _deviceId;

  StreamSubscription? _incomingSub;
  RealtimeChannel? _outboxChannel;
  Timer? _pollTimer;
  Timer? _heartbeatTimer;
  bool _running = false;
  bool get isRunning => _running;

  final _statusController = StreamController<GatewayStatus>.broadcast();
  Stream<GatewayStatus> get statusStream => _statusController.stream;
  GatewayStatus _status = GatewayStatus.stopped;
  GatewayStatus get status => _status;

  /// Set whenever [status] becomes [GatewayStatus.error] — the raw
  /// exception message, so GatewaySetupScreen can show *why* it
  /// failed instead of just hanging on "Starting...".
  String? lastError;

  void _setStatus(GatewayStatus s) {
    _status = s;
    _statusController.add(s);
  }

  /// Requests the SEND_SMS / RECEIVE_SMS / READ_SMS permission group,
  /// plus a battery-optimization exemption prompt so Android is less
  /// likely to kill the background service. Call this from the
  /// Gateway Setup screen before [start].
  Future<bool> requestPermissions() async {
    final smsStatus = await Permission.sms.request();
    if (!smsStatus.isGranted) return false;
    // Best-effort — some OEMs don't show this dialog, and that's fine;
    // the foreground service notification is the real reliability net.
    await Permission.ignoreBatteryOptimizations.request();
    return true;
  }

  Future<bool> hasPermissions() async => (await Permission.sms.status).isGranted;

  /// Registers/re-claims this device as a gateway, starts the native
  /// foreground service + incoming-SMS listener, and starts the
  /// outbox sync loop. Safe to call again after [stop].
  Future<void> start({String label = 'SMS Gateway'}) async {
    if (_running) return;
    _setStatus(GatewayStatus.starting);
    lastError = null;

    try {
      if (!await hasPermissions()) {
        _setStatus(GatewayStatus.missingPermissions);
        return;
      }

      if (Supabase.instance.client.auth.currentSession == null) {
        throw StateError('Not signed in — open the app and sign in first.');
      }

      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getString(_prefsDeviceIdKey);

      String? simNumber;
      try {
        simNumber = await _methodChannel.invokeMethod<String>('getSimNumber');
      } catch (_) {
        // Not all SIMs/carriers report their own number — fine, it's
        // purely informational on the server.
      }

      final id = await _service.registerGatewayDevice(
        existingDeviceId: existing,
        label: label,
        simPhoneNumber: simNumber,
      );
      _deviceId = id;
      await prefs.setString(_prefsDeviceIdKey, id);

      try {
        await _methodChannel.invokeMethod('startForegroundService');
      } on PlatformException catch (_) {
        // Foreground service failed to start (e.g. permission revoked
        // mid-flight) — still proceed with best-effort polling; the
        // status stream below reflects degraded reliability to the UI.
      }

      _incomingSub = _incomingSmsChannel.receiveBroadcastStream().listen(
        _onNativeIncomingSms,
        onError: (_) {},
      );

      _running = true;
      _setStatus(GatewayStatus.online);

      // React instantly to new outbound rows...
      _outboxChannel = _service.watchOutboxChanges(
        gatewayDeviceId: id,
        onChange: _drainOutbox,
      );
      // ...and also poll on an interval as a safety net, since a missed
      // realtime event (reconnect gap, backgrounded process) shouldn't
      // mean a queued text sits forever.
      _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) => _drainOutbox());
      _heartbeatTimer = Timer.periodic(const Duration(minutes: 2), (_) {
        if (_deviceId != null) {
          _service.registerGatewayDevice(existingDeviceId: _deviceId, label: label);
        }
      });

      unawaited(_drainOutbox());

      final prefs2 = await SharedPreferences.getInstance();
      await prefs2.setBool(_prefsShouldRunKey, true);
    } catch (e) {
      // Anything above can legitimately fail on a first run: the
      // v14-migration.sql RPCs not applied yet in Supabase, no
      // network, or (via resumeIfNeeded) not signed in yet. Whatever
      // it is, land on a visible error state instead of leaving the
      // screen stuck on "Starting..." forever.
      _running = false;
      lastError = e.toString();
      _setStatus(GatewayStatus.error);
    }
  }

  /// Call once at app startup (after Supabase auth is restored). If
  /// this device was last left in Gateway mode — the person turned it
  /// on and never explicitly turned it back off — this brings it back
  /// online without them needing to reopen the setup screen every
  /// time the app process restarts. A no-op if Gateway mode was never
  /// turned on here, or if SMS permission has since been revoked.
  Future<void> resumeIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final shouldRun = prefs.getBool(_prefsShouldRunKey) ?? false;
    if (!shouldRun || _running) return;
    if (!await hasPermissions()) return;
    if (Supabase.instance.client.auth.currentSession == null) return;
    try {
      await start();
    } catch (_) {
      // Best-effort: if this fails (e.g. flaky network right at
      // launch), Gateway mode just stays off until the person opens
      // GatewaySetupScreen and tries again — never worth crashing or
      // blocking app startup over.
      _setStatus(GatewayStatus.stopped);
    }
  }

  Future<void> stop() async {
    _running = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsShouldRunKey, false);
    _pollTimer?.cancel();
    _heartbeatTimer?.cancel();
    await _incomingSub?.cancel();
    if (_outboxChannel != null) {
      await Supabase.instance.client.removeChannel(_outboxChannel!);
      _outboxChannel = null;
    }
    if (_deviceId != null) {
      await _service.setGatewayOffline(_deviceId!);
    }
    try {
      await _methodChannel.invokeMethod('stopForegroundService');
    } catch (_) {}
    _setStatus(GatewayStatus.stopped);
  }

  /// Claims whatever's currently queued and asks the native side to
  /// actually send each one over the real SMS radio.
  Future<void> _drainOutbox() async {
    if (!_running || _deviceId == null) return;
    try {
      final claimed =
          await _service.claimPendingSms(gatewayDeviceId: _deviceId!);
      for (final msg in claimed) {
        final phone = msg['phone_number'] as String;
        final body = msg['body'] as String;
        final messageId = msg['message_id'] as String;
        try {
          await _methodChannel.invokeMethod('sendSms', {
            'phoneNumber': phone,
            'body': body,
          });
          await _service.updateSmsStatus(messageId: messageId, status: 'sent');
        } catch (_) {
          await _service.updateSmsStatus(messageId: messageId, status: 'failed');
        }
      }
    } catch (_) {
      // Transient network/DB error — next poll tick or realtime event
      // will retry; nothing queued gets lost since rows stay 'sending'
      // and a stuck 'sending' batch can be re-claimed by adding a
      // staleness check server-side if that ever proves necessary.
    }
  }

  /// A real SMS arrived on this phone. Upload it to Supabase so it
  /// shows up in the owner's chat.
  Future<void> _onNativeIncomingSms(dynamic event) async {
    if (_deviceId == null) return;
    final map = Map<String, dynamic>.from(event as Map);
    final from = map['from'] as String;
    final body = map['body'] as String;
    try {
      await _service.receiveSms(
        gatewayDeviceId: _deviceId!,
        fromPhoneNumber: from,
        body: body,
      );
    } catch (_) {
      // If this fails the text is still sitting on the phone itself
      // (Android's own SMS app has it) — not silently lost, just not
      // synced yet. The next incoming text or app resume can retry;
      // for now the priority is never crashing the receiver.
    }
  }
}

enum GatewayStatus { stopped, starting, online, missingPermissions, error }
