import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'app_storage_service.dart';
import 'supabase_service.dart';

/// Makes a profile-field edit (username, display name, home city)
/// made while offline "just sync" once the device is back online, no
/// further action needed — same contract, and near-identical
/// implementation, as [PrivacySettingsSyncService].
///
/// Deliberately doesn't cover email changes: those go through
/// Supabase Auth's "confirm via link sent to the new address" flow,
/// which has no offline-queueable form — there's nothing useful to
/// queue if the confirmation email itself can't be sent yet. The
/// Edit Profile sheet keeps that one field's save gated on actually
/// being online rather than routing it through here.
///
/// Kept as its own small, single-purpose service rather than folded
/// into [PrivacySettingsSyncService] or generalized into one shared
/// "settings sync" engine — same reasoning as that service's own doc
/// comment: a settings blob has simple last-value-wins merge
/// semantics, easiest to keep obviously correct when each queue is
/// scoped to one screen's fields rather than shared.
class ProfileFieldsSyncService {
  ProfileFieldsSyncService._();
  static final ProfileFieldsSyncService instance = ProfileFieldsSyncService._();

  static const _pendingKey = 'profile_fields_pending';

  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _flushing = false;

  /// Notified after a flush actually succeeds, so the Edit Profile
  /// sheet (if still open) can drop its "couldn't sync yet" banner
  /// without the user having to do anything.
  final _onSynced = StreamController<void>.broadcast();
  Stream<void> get onSynced => _onSynced.stream;

  /// Notified when a flush fails specifically because the queued
  /// username was already taken by someone else in the meantime —
  /// the one failure mode here that leaving queued forever won't fix
  /// on its own, so the sheet needs to actually tell the person.
  final _onUsernameConflict = StreamController<void>.broadcast();
  Stream<void> get onUsernameConflict => _onUsernameConflict.stream;

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
  /// Last value wins per-field.
  Future<void> queue(Map<String, dynamic> fields) async {
    final existing =
        await AppStorageService.instance.loadMap(_pendingKey) ?? {};
    existing.addAll(fields);
    await AppStorageService.instance.saveMap(_pendingKey, existing);
  }

  /// Whatever's currently queued but not yet synced — the Edit
  /// Profile sheet reads this on load so a still-pending change shows
  /// up in the fields immediately rather than being overwritten by
  /// whatever's still on the server.
  Future<Map<String, dynamic>?> peekPending() =>
      AppStorageService.instance.loadMap(_pendingKey);

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
      await SupabaseService.instance.updateProfile(
        userId: user.id,
        username: pending['username'] as String?,
        displayName: pending['display_name'] as String?,
        homeCity: pending['home_city'] as String?,
      );
      await AppStorageService.instance.clear(_pendingKey);
      _onSynced.add(null);
    } on Exception catch (e) {
      // A taken-username conflict isn't going to resolve itself by
      // retrying later the way "still offline" will — surface it and
      // drop the queued username specifically so the rest of a
      // pending edit (display name, home city) can still sync
      // normally rather than getting stuck behind it forever.
      if (e.toString().contains('already taken')) {
        final rest = Map<String, dynamic>.from(pending)..remove('username');
        if (rest.isEmpty) {
          await AppStorageService.instance.clear(_pendingKey);
        } else {
          await AppStorageService.instance.saveMap(_pendingKey, rest);
        }
        _onUsernameConflict.add(null);
      }
      // Otherwise: still offline (or a transient failure) — leave it
      // queued and try again on the next connectivity-change event.
    } finally {
      _flushing = false;
    }
  }

  void dispose() {
    _sub?.cancel();
    _onSynced.close();
    _onUsernameConflict.close();
  }
}
