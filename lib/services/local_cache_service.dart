import 'package:shared_preferences/shared_preferences.dart';
import 'compression_service.dart';

/// A small "cache-first" store for lists of posts (drops, flicks, …).
///
/// The pattern used across the app is:
///   1. On screen load, read whatever was cached last time and show it
///      immediately — no spinner, no network round-trip, and it works
///      with no connection at all.
///   2. Kick off a fresh fetch in the background. If it succeeds,
///      replace what's on screen and overwrite the cache. If it fails
///      (e.g. offline), just keep showing the cached posts instead of
///      an error screen.
///
/// This means a post's *data* (caption, media URLs, counts, etc.) is
/// never re-downloaded on every app open just to render the same
/// list — only when a fresh fetch actually succeeds does anything get
/// replaced. The underlying media (photos/videos) gets its own disk
/// cache too — see `cached_media.dart` — so previously-viewed media
/// keeps working offline as well.
///
/// Every key is namespaced under whichever account is currently
/// active (see [setActiveUser], driven by `AccountManagerService`).
/// That's what makes switching between saved accounts fast *and*
/// correct offline: account B's last-known feed is stored under its
/// own namespace, so switching to it shows B's data immediately
/// instead of a stale copy of account A's.
///
/// Values are gzip-compressed on disk (see [CompressionService]) —
/// lossless, transparent to every caller here, just less space taken
/// up by a device's cached feed/chat history over time.
class LocalCacheService {
  LocalCacheService._();
  static final LocalCacheService instance = LocalCacheService._();

  static const _prefix = 'rm_cache_';

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

  /// Persists a list of already-serialized maps (e.g. `Drop.toMap()`)
  /// under [key], scoped to the currently-active account.
  Future<void> saveList(String key, List<Map<String, dynamic>> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _namespacedKey(key), CompressionService.compressJson(items));
    } catch (_) {
      // Caching is a nice-to-have — never let a write failure surface
      // to the user.
    }
  }

  /// Reads back whatever was last saved under [key] for the
  /// currently-active account, or null if nothing's cached yet (or it
  /// failed to parse).
  ///
  /// Falls back to the pre-namespacing key if nothing's there yet —
  /// otherwise, upgrading to per-account namespacing would make
  /// whatever was already cached before that change look like it had
  /// simply vanished, with nothing to show until the next successful
  /// online fetch repopulates it. The legacy copy is migrated forward
  /// (and removed) so this only ever needs to happen once per key.
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

  /// Clears one cached key for the currently-active account (used e.g.
  /// after deleting a post, so a stale copy of it can't reappear from
  /// cache).
  Future<void> clear(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_namespacedKey(key));
    } catch (_) {}
  }

  /// Clears every cached list belonging to one account — [userId], or
  /// the currently-active one if omitted. Called on sign-out/forget so
  /// the next account (or a re-added copy of this one later) never
  /// sees a stale copy of someone else's cached posts.
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
