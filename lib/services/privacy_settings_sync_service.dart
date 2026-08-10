import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'app_storage_service.dart';
import 'supabase_service.dart';

/// Makes a privacy-setting change made while offline "just sync" once
/// the device is back online, with no further action from the user.
///
/// The flow:
///   1. [queue] is called the instant a toggle changes. The new field(s)
///      are merged into a pending-write blob and persisted via
///      [AppStorageService] (durable — survives an app restart).
///   2. [flush] tries to push that pending blob to Supabase. On success
///      it's cleared. On failure (still offline / transient error) it's
///      left in place for next time.
///   3. [init] — called once at app startup — loads any pending write
///      left over from a previous session, attempts an immediate flush
///      in case we're already online, and then subscribes to
///      connectivity changes so that going from offline -> online
///      triggers an automatic retry, even if the user never reopens
///      the privacy settings sheet.
///
/// Deliberately scoped to privacy settings only (not a generic sync
/// engine) — same spirit as the chat outbox, which is also
/// feature-specific rather than a shared abstraction.
class PrivacySettingsSyncService {
  PrivacySettingsSyncService._();
  static final PrivacySettingsSyncService instance =
      PrivacySettingsSyncService._();

  static const _pendingKey = 'privacy_settings_pending';

  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _flushing = false;

  /// Notified after a flush actually succeeds, so any open UI (e.g. the
  /// privacy settings sheet, if still on screen) can drop its "couldn't
  /// sync yet" banner without the user having to do anything.
  final _onSynced = StreamController<void>.broadcast();
  Stream<void> get onSynced => _onSynced.stream;

  Future<void> init() async {
    // Covers the case where the app was killed while a write was still
    // pending — don't wait for a connectivity *change* event that may
    // never fire if we're already online right now.
    await flush();

    _sub ??= Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online) flush();
    });
  }

  /// Merges [fields] into whatever's already pending and persists it.
  /// Last value wins per-field, which is the right merge rule for a
  /// settings blob (unlike, say, a chat outbox where order matters).
  Future<void> queue(Map<String, dynamic> fields) async {
    final existing =
        await AppStorageService.instance.loadMap(_pendingKey) ?? {};
    existing.addAll(fields);
    await AppStorageService.instance.saveMap(_pendingKey, existing);
  }

  /// Attempts to push whatever's pending. Safe to call anytime —
  /// no-ops if there's nothing queued, no signed-in user, or a flush
  /// is already in flight.
  Future<void> flush() async {
    if (_flushing) return;
    final user = SupabaseService.instance.currentUser;
    if (user == null) return;

    final pending = await AppStorageService.instance.loadMap(_pendingKey);
    if (pending == null || pending.isEmpty) return;

    _flushing = true;
    try {
      await SupabaseService.instance.updatePrivacySettings(
        userId: user.id,
        allowDiscovery: pending['allow_discovery'] as bool?,
        showHomeCity: pending['show_home_city'] as bool?,
        showDisplayName: pending['show_display_name'] as bool?,
        showStats: pending['show_stats'] as bool?,
        showOnMap: pending['show_on_map'] as bool?,
        allowTagging: pending['allow_tagging'] as bool?,
      );
      await AppStorageService.instance.clear(_pendingKey);
      _onSynced.add(null);
    } catch (_) {
      // Still offline (or a genuine failure) — leave it queued and
      // try again on the next connectivity-change event.
    } finally {
      _flushing = false;
    }
  }

  void dispose() {
    _sub?.cancel();
    _onSynced.close();
  }
}
