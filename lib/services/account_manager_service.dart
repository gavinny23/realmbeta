import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/saved_account.dart';
import 'app_storage_service.dart';
import 'local_cache_service.dart';
import 'push_notification_service.dart';
import 'supabase_service.dart';

/// Lets more than one account live on this device at once, and makes
/// switching between them fast — including with no connection.
///
/// How it works:
///  * Each account's full Supabase session (access + refresh token) is
///    snapshotted into secure storage, keyed by user id, the moment
///    that account signs in (see [rememberCurrentSession]).
///  * Lightweight metadata for every saved account (username, display
///    name, avatar — no secrets) lives in SharedPreferences so the
///    switcher can render the list instantly without touching the
///    network.
///  * [switchToAccount] loads a saved session straight into the
///    Supabase client via `SupabaseService.restoreSession`. As long as
///    that account's access token hasn't expired, this never touches
///    the network — that's what makes offline switching possible.
///  * [LocalCacheService] and [AppStorageService] are told which
///    account is active (see their `setActiveUser`) so each account's
///    cached feed/chats/settings stay in their own namespace and
///    switching shows the right data immediately.
///
/// Signing out of an account for real (revoking its session
/// server-side) is a separate, explicit step — see [forgetAccount]
/// with `alsoSignOut: true` — from merely switching away from it,
/// which never revokes anything.
class AccountManagerService {
  AccountManagerService._();
  static final AccountManagerService instance = AccountManagerService._();

  static const _listKey = 'rm_accounts_list';
  static const _activeIdKey = 'rm_accounts_active_id';

  final _secure = const FlutterSecureStorage();

  String _sessionKey(String userId) => 'rm_session_$userId';

  // ---------------------------------------------------------------
  // Reading the saved list
  // ---------------------------------------------------------------

  Future<List<SavedAccount>> loadSavedAccounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_listKey);
      if (raw == null) return [];
      final decoded = jsonDecode(raw) as List;
      final accounts = decoded
          .map((e) =>
              SavedAccount.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
      accounts.sort((a, b) => b.lastActiveAt.compareTo(a.lastActiveAt));
      return accounts;
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveAccountsList(List<SavedAccount> accounts) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _listKey, jsonEncode(accounts.map((a) => a.toMap()).toList()));
    } catch (_) {}
  }

  /// Raw read of whatever session is saved for [userId], if any — the
  /// same secret [switchToAccount] loads into the live Supabase
  /// client, but handed back as JSON instead. Exists for callers that
  /// need to authenticate as a *specific* account without disturbing
  /// whichever one is currently active in the UI — namely
  /// [PushNotificationService]'s notification-reply handling, which
  /// typically runs in its own short-lived background isolate (the
  /// app may be fully terminated) and must send as whichever account
  /// the tapped notification was actually for, not whatever this
  /// device's `currentUser` happens to be.
  Future<String?> readSavedSessionJson(String userId) async {
    try {
      // The one platform-channel call in the notification-reply path
      // that wasn't already timeout-bound — every network call around
      // it is (see PushNotificationService.handleChatReply), but a
      // stalled channel call to secure storage hangs exactly the same
      // way: no exception, nothing to catch, so the caller never
      // reaches its own failure path either. From a background
      // notification-action isolate specifically, that's the
      // difference between "reply failed" and "spinner stuck
      // forever" — bound it here so a stall becomes a normal,
      // catchable failure instead.
      return await _secure
          .read(key: _sessionKey(userId))
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    }
  }

  /// Overwrites the saved session for [userId] in place — used after
  /// a background token refresh (see [readSavedSessionJson]) so the
  /// refreshed access/refresh token pair is what's there next time,
  /// whether that's another background reply or a normal
  /// [switchToAccount]. Deliberately never touches the accounts list
  /// or the active-account pointer — this is purely a secret update,
  /// not a sign-in.
  Future<void> writeSavedSessionJson(String userId, String sessionJson) async {
    try {
      // Same reasoning as the timeout on readSavedSessionJson — this
      // sits in the same reply path (via _validAccessTokenFor's
      // refresh branch) and a stall here would hang the caller
      // exactly as silently.
      await _secure
          .write(key: _sessionKey(userId), value: sessionJson)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // Best-effort — worst case the next reply/refresh just repeats
      // this same refresh round trip.
    }
  }

  Future<String?> get activeAccountId async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_activeIdKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _setActiveAccountId(String? userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (userId == null) {
        await prefs.remove(_activeIdKey);
      } else {
        await prefs.setString(_activeIdKey, userId);
      }
    } catch (_) {}
    LocalCacheService.setActiveUser(userId);
    AppStorageService.setActiveUser(userId);
  }

  // ---------------------------------------------------------------
  // Boot / capture
  // ---------------------------------------------------------------

  /// Call once at app startup, right after `Supabase.initialize` has
  /// finished restoring whatever session it had persisted, so the
  /// local caches are namespaced to the right account from the very
  /// first frame instead of defaulting to "no account".
  Future<void> applyActiveNamespaceFromCurrentSession() async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) {
      LocalCacheService.setActiveUser(null);
      AppStorageService.setActiveUser(null);
      return;
    }
    await _setActiveAccountId(user.id);

    // Covers accounts that signed in before this feature existed, or
    // whose entry was otherwise never captured — make sure this
    // session is on the switcher list from now on.
    final known = await loadSavedAccounts();
    if (!known.any((a) => a.id == user.id)) {
      await rememberCurrentSession();
    }
  }

  /// Call right after a successful sign in/sign up: snapshots the
  /// current session and profile summary so this account appears in
  /// the switcher and can be switched back to later, even offline.
  Future<void> rememberCurrentSession() async {
    final user = SupabaseService.instance.currentUser;
    final sessionJson = SupabaseService.instance.currentSessionJson;
    if (user == null || sessionJson == null) return;

    try {
      await _secure.write(key: _sessionKey(user.id), value: sessionJson);
    } catch (_) {
      // Secure storage can fail on some devices — the account just
      // won't be switchable offline in that case; everything else
      // (including switching while online) still works fine.
    }

    Map<String, dynamic>? summary;
    try {
      summary = await SupabaseService.instance.fetchAccountSummary(user.id);
    } catch (_) {
      // Most likely offline right after signing in — fall back to
      // whatever was already known about this account below.
    }

    final accounts = await loadSavedAccounts();
    final existing = accounts.where((a) => a.id == user.id);
    final previous = existing.isNotEmpty ? existing.first : null;
    final now = DateTime.now();

    final merged = SavedAccount(
      id: user.id,
      email: user.email ?? previous?.email ?? '',
      username:
          summary?['username'] as String? ?? previous?.username ?? '',
      displayName:
          summary?['display_name'] as String? ?? previous?.displayName ?? '',
      avatarUrl: summary?['avatar_url'] as String? ?? previous?.avatarUrl,
      addedAt: previous?.addedAt ?? now,
      lastActiveAt: now,
    );

    accounts.removeWhere((a) => a.id == user.id);
    accounts.add(merged);
    await _saveAccountsList(accounts);
    await _setActiveAccountId(user.id);
  }

  /// Refreshes the stored display name/avatar for the current account
  /// after a profile edit, so the switcher doesn't show stale info.
  Future<void> refreshCurrentAccountSummary() => rememberCurrentSession();

  // ---------------------------------------------------------------
  // Switching
  // ---------------------------------------------------------------

  /// Switches the active session to [userId]'s last-saved one.
  ///
  /// This loads the previously-persisted tokens straight into the
  /// client rather than signing in again, so it's fast and works
  /// fully offline as long as that account's access token hasn't
  /// expired yet. Returns false if nothing's saved for [userId] (it
  /// needs a fresh sign-in instead), or rethrows if the token had
  /// expired and there's no connectivity to silently refresh it.
  Future<bool> switchToAccount(String userId) async {
    final current = await activeAccountId;
    if (current == userId && SupabaseService.instance.currentUser != null) {
      return true;
    }

    String? sessionJson;
    try {
      sessionJson = await _secure.read(key: _sessionKey(userId));
    } catch (_) {
      sessionJson = null;
    }
    if (sessionJson == null) return false;

    await SupabaseService.instance.restoreSession(sessionJson);
    await _setActiveAccountId(userId);

    // Each account needs its own device_tokens row against this
    // device's shared FCM token (see v32-migration.sql) — otherwise
    // an account that was only ever added via the switcher, and never
    // itself ran the launch-time registration in FeedScreenState,
    // has no active row and silently never receives chat pushes.
    // Fire-and-forget, same best-effort pattern as _saveToken above:
    // worst case this account just doesn't get pushes until the next
    // successful registration attempt.
    unawaited(
      PushNotificationService.instance.registerTokenForCurrentUser(),
    );

    final accounts = await loadSavedAccounts();
    final idx = accounts.indexWhere((a) => a.id == userId);
    if (idx != -1) {
      accounts[idx] = accounts[idx].copyWith(lastActiveAt: DateTime.now());
      await _saveAccountsList(accounts);
    }
    return true;
  }

  // ---------------------------------------------------------------
  // Removing
  // ---------------------------------------------------------------

  /// Removes [userId] from this device: forgets its saved session and
  /// clears its cached data. This alone never contacts the network or
  /// invalidates anything server-side — it just means the switcher
  /// won't offer it anymore (a fresh sign-in would be needed to bring
  /// it back).
  ///
  /// Pass `alsoSignOut: true` when this *is* the active account and
  /// the user chose "sign out" — that additionally revokes the
  /// session server-side via `SupabaseService.signOut`. If other
  /// saved accounts remain afterward, the most recently-used one is
  /// switched to automatically so the user lands back in the app
  /// instead of at the login screen.
  Future<void> forgetAccount(String userId, {bool alsoSignOut = false}) async {
    final wasActive = await activeAccountId == userId;

    if (alsoSignOut && wasActive) {
      // Stop this device's shared FCM token from being pushed to for
      // this account specifically — deliberately *before* signOut
      // below, since device_tokens' row-level security requires being
      // authenticated as this user, and signOut invalidates that.
      // Any other account signed in on this device (sharing the same
      // token) is completely unaffected; see
      // PushNotificationService.unregisterTokenForUser.
      try {
        await PushNotificationService.instance.unregisterTokenForUser(userId);
      } catch (_) {
        // Best-effort — worst case this account keeps receiving
        // pushes on this device a little longer than ideal.
      }
      try {
        await SupabaseService.instance.signOut();
      } catch (_) {
        // Still proceed to forget it locally even if the network
        // revoke call failed (e.g. offline) — it'll simply expire on
        // its own server-side eventually.
      }
    }

    try {
      await _secure.delete(key: _sessionKey(userId));
    } catch (_) {}
    await LocalCacheService.instance.clearAll(userId: userId);
    await AppStorageService.instance.clearAll(userId: userId);

    final accounts = await loadSavedAccounts();
    accounts.removeWhere((a) => a.id == userId);
    await _saveAccountsList(accounts);

    if (wasActive) {
      await _setActiveAccountId(null);
      if (accounts.isNotEmpty) {
        accounts.sort((a, b) => b.lastActiveAt.compareTo(a.lastActiveAt));
        await switchToAccount(accounts.first.id);
      }
    }
  }
}
