import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the single deepest screen someone was actually looking
/// at, so that when Android kills the whole process in the background
/// (see the comment on `_boot()` in main.dart — this is routine OS
/// memory reclamation the moment the app isn't visible, not something
/// this app controls) the next cold start can drop them back into
/// that screen instead of just the right bottom-nav tab.
///
/// Deliberately generic rather than one field per screen type: only
/// one screen can ever be "on top" at a time, so this only ever needs
/// to hold one record — whichever restorable screen was pushed most
/// recently, cleared the moment its push future resolves (i.e. the
/// person navigated back to whatever was under it). Screens that want
/// this restore their own [description] in that shape and know how
/// to turn [params] back into themselves — this service is just
/// storage, not aware of what any particular screen means.
class NavigationRestorationService {
  NavigationRestorationService._();
  static final NavigationRestorationService instance =
      NavigationRestorationService._();

  static const _typeKey = 'rm_nav_restore_type';
  static const _paramsPrefix = 'rm_nav_restore_param_';

  /// Call right before pushing a restorable screen. [params] values
  /// must themselves be strings — callers that only have an id or a
  /// couple of short fields (a chat's other-user id + username, say)
  /// fit this fine; anything that needs a full fetched object (a
  /// Drop, a NewsArticle) doesn't belong here yet, since restoring it
  /// on a cold start would mean re-fetching by id and this app
  /// doesn't have fetch-by-id for those yet.
  Future<void> save(String type, Map<String, String> params) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_typeKey, type);
      for (final entry in params.entries) {
        await prefs.setString('$_paramsPrefix${entry.key}', entry.value);
      }
      // Record which keys belong to this save so clear() only wipes
      // what it actually wrote, not some other screen type's leftover
      // params from a previous session.
      await prefs.setStringList(
          '${_paramsPrefix}_keys', params.keys.toList());
    } catch (_) {
      // Best-effort — worst case a cold start just lands on the tab
      // instead of the exact screen, same as before this existed.
    }
  }

  /// Call once the pushed screen's own Future completes (i.e. the
  /// person is back on whatever screen called [save]) — that's the
  /// signal this is no longer "the screen someone was last looking
  /// at", so a process kill from here on should restore nothing.
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getStringList('${_paramsPrefix}_keys') ?? [];
      for (final key in keys) {
        await prefs.remove('$_paramsPrefix$key');
      }
      await prefs.remove('${_paramsPrefix}_keys');
      await prefs.remove(_typeKey);
    } catch (_) {
      // Best-effort, same as save().
    }
  }

  /// Reads back whatever was saved, if anything — `null` on a normal
  /// cold start with nothing to restore, which is the common case.
  Future<_RestorableScreen?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final type = prefs.getString(_typeKey);
      if (type == null) return null;
      final keys = prefs.getStringList('${_paramsPrefix}_keys') ?? [];
      final params = <String, String>{};
      for (final key in keys) {
        final value = prefs.getString('$_paramsPrefix$key');
        if (value != null) params[key] = value;
      }
      return _RestorableScreen(type: type, params: params);
    } catch (_) {
      return null;
    }
  }
}

class _RestorableScreen {
  final String type;
  final Map<String, String> params;
  const _RestorableScreen({required this.type, required this.params});
}
