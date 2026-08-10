import 'package:shared_preferences/shared_preferences.dart';
import 'compression_service.dart';

/// Durable, account-scoped local storage for data the user would
/// actually be upset to lose — chat history/outbox, profile stats,
/// privacy settings, etc.
///
/// This is intentionally a *separate* store from [LocalCacheService].
/// `LocalCacheService` holds disposable, always-refetchable content
/// (the drops feed, flicks, nearby drops) under an `rm_cache_` prefix
/// — it's fine for that to be wiped at any time, worst case is a
/// re-fetch. This service uses a different prefix (`rm_data_`) and,
/// critically, nothing in the app is allowed to blanket-clear it the
/// way a "reset cache" style action might clear `LocalCacheService`.
/// The only thing that clears it is [clearAll], called from
/// `SupabaseService.signOut()` — because at that point it genuinely
/// should stop being on the device.
///
/// Same cache-first idiom as [LocalCacheService]:
///   1. Read what's stored, show it immediately (works fully offline).
///   2. Fetch fresh in the background; on success, overwrite.
///   3. On failure (offline), just keep showing what's stored.
///
/// Every key is namespaced under whichever account is currently
/// active (see [setActiveUser], driven by `AccountManagerService`),
/// so account switching never leaks one account's chats/settings
/// into another's — and so switching *to* a saved account shows its
/// own last-known data straight away, even with no connection.
///
/// Values are gzip-compressed on disk (see [CompressionService]) —
/// lossless, transparent to every caller here, just less space taken
/// up by a device's saved chat history/outbox/settings over time.
class AppStorageService {
  AppStorageService._();
  static final AppStorageService instance = AppStorageService._();

  static const _prefix = 'rm_data_';

  static String? _activeUserId;

  /// Called by `AccountManagerService` whenever the active account
  /// changes (sign in, switch, sign out) so subsequent reads/writes
  /// land in that account's own namespace.
  static void setActiveUser(String? userId) {
    _activeUserId = userId;
  }

  static String _namespacedKey(String key) =>
      '$_prefix${_activeUserId ?? 'anon'}_$key';

  /// The plain, un-namespaced key this same [key] would have been
  /// stored under before per-account namespacing existed.
  static String _legacyKey(String key) => '$_prefix$key';

  Future<void> saveList(String key, List<Map<String, dynamic>> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _namespacedKey(key), CompressionService.compressJson(items));
    } catch (_) {
      // Storage is best-effort — never let a write failure surface.
    }
  }

  /// Falls back to the pre-namespacing key if nothing's under the
  /// namespaced one yet, migrating it forward (see [LocalCacheService.
  /// loadList] for the full reasoning) so chat history/outbox saved
  /// before per-account namespacing existed doesn't look like it was
  /// lost the moment this device updated.
  Future<List<Map<String, dynamic>>?> loadList(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var raw = prefs.getString(_namespacedKey(key));
      if (raw == null) {
        final legacy = prefs.getString(_legacyKey(key));
        if (legacy == null) return null;
        raw = legacy;
        await prefs.setString(_namespacedKey(key), legacy);
        await prefs.remove(_legacyKey(key));
      }
      final decoded = CompressionService.decompressJson(raw) as List;
      return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return null;
    }
  }

  /// For single objects — a profile's stats, a settings blob — rather
  /// than a list.
  Future<void> saveMap(String key, Map<String, dynamic> value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _namespacedKey(key), CompressionService.compressJson(value));
    } catch (_) {}
  }

  /// Same legacy-key fallback as [loadList], for single-object values.
  Future<Map<String, dynamic>?> loadMap(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var raw = prefs.getString(_namespacedKey(key));
      if (raw == null) {
        final legacy = prefs.getString(_legacyKey(key));
        if (legacy == null) return null;
        raw = legacy;
        await prefs.setString(_namespacedKey(key), legacy);
        await prefs.remove(_legacyKey(key));
      }
      return Map<String, dynamic>.from(
          CompressionService.decompressJson(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  Future<void> clear(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_namespacedKey(key));
    } catch (_) {}
  }

  /// Wipes every durable key belonging to one account — [userId], or
  /// the currently-active one if omitted. Only ever called on
  /// sign-out/forget — this is account-scoped data, so it's correct
  /// (and necessary, for privacy) to drop it when that account leaves
  /// the device. It must never be wired up to any in-app "clear
  /// cache" style action.
  Future<void> clearAll({String? userId}) async {
    final ns = userId ?? _activeUserId ?? 'anon';
    final targetPrefix = '$_prefix${ns}_';
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k
          in prefs.getKeys().where((k) => k.startsWith(targetPrefix)).toList()) {
        await prefs.remove(k);
      }
    } catch (_) {}
  }
}
