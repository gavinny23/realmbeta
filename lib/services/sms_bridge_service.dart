import 'package:supabase_flutter/supabase_flutter.dart';

/// Talks to the `sms_*` tables/RPCs added in `v14-migration.sql`.
///
/// Two roles share this one service:
/// - The *owner* side: a normal user viewing/sending into an SMS-backed
///   thread, same as any other conversation in the Chats tab.
/// - The *gateway* side: the one Android phone with a real SIM, running
///   in Gateway mode (see `SmsGatewayBridge`), claiming outbound work
///   and posting inbound texts it actually received over SMS.
class SmsBridgeService {
  SmsBridgeService._();
  static final SmsBridgeService instance = SmsBridgeService._();

  SupabaseClient get _client => Supabase.instance.client;

  /// Same reasoning as `SupabaseService._quickReadTimeout`: these two
  /// reads back cache-first screens (the Chats list, an open SMS
  /// thread) that already show cached data immediately — this just
  /// makes sure a background refresh over a dead connection fails
  /// fast instead of leaving that data stuck mid-refresh.
  static const _quickReadTimeout = Duration(seconds: 8);

  // ---------------------------------------------------------------
  // Owner side
  // ---------------------------------------------------------------

  /// One row per SMS thread the current user owns, newest first —
  /// shaped to merge directly into the same list as fetchConversations().
  Future<List<Map<String, dynamic>>> fetchSmsConversations() async {
    final rows = await _client
        .rpc('list_sms_conversations')
        .timeout(_quickReadTimeout);
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// Full message history for one SMS thread, oldest first.
  Future<List<Map<String, dynamic>>> fetchSmsMessages(
      {required String threadId}) async {
    final rows = await _client
        .from('sms_messages')
        .select()
        .eq('thread_id', threadId)
        .order('created_at', ascending: true)
        .timeout(_quickReadTimeout);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// Live updates for one open SMS thread.
  Stream<List<Map<String, dynamic>>> watchSmsMessages(
      {required String threadId}) {
    return _client
        .from('sms_messages')
        .stream(primaryKey: ['id'])
        .eq('thread_id', threadId)
        .order('created_at');
  }

  /// Queues an outbound text. Finds-or-creates the thread server-side
  /// (see `send_sms_message` RPC) so the first message to a brand new
  /// number can't race into two threads. The gateway phone picks this
  /// up next time it polls its outbox.
  Future<Map<String, dynamic>> sendSms({
    required String gatewayDeviceId,
    required String phoneNumber,
    required String body,
    String? displayName,
  }) async {
    final row = await _client.rpc('send_sms_message', params: {
      'target_gateway_id': gatewayDeviceId,
      'target_phone_number': phoneNumber,
      'message_body': body,
      'contact_display_name': displayName,
    });
    return Map<String, dynamic>.from(row as Map);
  }

  Future<void> markThreadRead(String threadId) async {
    await _client
        .rpc('mark_sms_thread_read', params: {'target_thread_id': threadId});
  }

  /// The gateway device(s) the current user operates — usually just
  /// one. Needed on the owner side too, e.g. to know which gateway to
  /// address when starting a brand new SMS thread.
  Future<List<Map<String, dynamic>>> fetchMyGatewayDevices() async {
    final rows = await _client
        .from('sms_gateway_devices')
        .select()
        .order('created_at', ascending: true);
    return List<Map<String, dynamic>>.from(rows);
  }

  // ---------------------------------------------------------------
  // Gateway side (runs on the phone with the SIM)
  // ---------------------------------------------------------------

  /// Registers this device as a gateway (first run) or re-claims +
  /// heartbeats an existing one (subsequent runs / periodic ping).
  /// Returns the gateway device id, which the caller should persist
  /// locally (SharedPreferences) and pass back in on every call after.
  Future<String> registerGatewayDevice({
    String? existingDeviceId,
    String label = 'SMS Gateway',
    String? simPhoneNumber,
  }) async {
    final id = await _client.rpc('register_gateway_device', params: {
      'device_id': existingDeviceId,
      'device_label': label,
      'sim_phone_number': simPhoneNumber,
    });
    return id as String;
  }

  Future<void> setGatewayOffline(String deviceId) async {
    await _client.rpc('set_gateway_offline', params: {'device_id': deviceId});
  }

  /// Atomically claims up to [batchSize] pending outbound texts for
  /// this gateway and flips them to 'sending', so a restarted background
  /// isolate can never double-send a message an earlier run already
  /// grabbed.
  Future<List<Map<String, dynamic>>> claimPendingSms({
    required String gatewayDeviceId,
    int batchSize = 20,
  }) async {
    final rows = await _client.rpc('claim_pending_sms', params: {
      'for_gateway_id': gatewayDeviceId,
      'batch_size': batchSize,
    });
    return List<Map<String, dynamic>>.from(rows as List);
  }

  Future<void> updateSmsStatus({
    required String messageId,
    required String status, // 'sent' | 'delivered' | 'failed'
  }) async {
    await _client.rpc('update_sms_status', params: {
      'target_message_id': messageId,
      'new_status': status,
    });
  }

  /// Called when the native SMS receiver hands Dart a real incoming
  /// text. Finds-or-creates the thread server-side so a first message
  /// from a brand-new number still lands somewhere sensible.
  Future<Map<String, dynamic>> receiveSms({
    required String gatewayDeviceId,
    required String fromPhoneNumber,
    required String body,
  }) async {
    final row = await _client.rpc('receive_sms_message', params: {
      'from_gateway_id': gatewayDeviceId,
      'from_phone_number': fromPhoneNumber,
      'message_body': body,
    });
    return Map<String, dynamic>.from(row as Map);
  }

  /// Realtime stream of new outbound rows queued for this gateway —
  /// lets Gateway mode react instantly instead of only on its poll
  /// interval. The payload only signals "something changed"; the
  /// caller still calls [claimPendingSms] to actually grab work
  /// (keeps the claim atomic regardless of what triggered it).
  RealtimeChannel watchOutboxChanges({
    required String gatewayDeviceId,
    required void Function() onChange,
  }) {
    final channel = _client.channel('sms-outbox-$gatewayDeviceId');
    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'sms_messages',
          callback: (payload) => onChange(),
        )
        .subscribe();
    return channel;
  }
}
