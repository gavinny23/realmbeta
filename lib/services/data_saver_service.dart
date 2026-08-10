import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted "Data saver" preference. Compressing uploads is only part
/// of what this controls — while it's on, media loaded *from* the
/// network (status, drops, updates, anywhere a photo or video shows
/// up) also loads blurred at the lowest quality first, with a tap-to-
/// download button, instead of silently pulling the full file in the
/// background. See [DataSaverMediaGate] in `widgets/blur_media.dart`
/// for the viewing side of this.
///
/// Follows the same singleton + SharedPreferences pattern as
/// [ThemeController] so it can be read synchronously anywhere in the
/// app once [init] has run at startup.
class DataSaverService extends ChangeNotifier {
  DataSaverService._();
  static final DataSaverService instance = DataSaverService._();

  static const _prefsKey = 'rm_data_saver_enabled';

  bool _enabled = false;
  bool get enabled => _enabled;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefsKey) ?? false;
    } catch (_) {
      // Prefs unavailable — default to off (full quality).
    }
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, value);
    } catch (_) {}
  }

  // ── Compression targets ────────────────────────────────────────────
  // Two tiers only — kept simple on purpose. Data saver trades a
  // noticeably smaller file for a still-perfectly-viewable image/video;
  // it's not trying to squeeze out every last byte.

  /// Longest edge, in pixels, a photo is resized to before upload.
  int get photoMaxDimension => _enabled ? 1080 : 1600;

  /// JPEG quality (0-100) used when re-encoding photos before upload.
  int get photoQuality => _enabled ? 62 : 82;

  // ── Viewing side: which media the person has chosen to download ────
  // Session-only on purpose — it tracks what's been explicitly
  // unlocked with the download button since the app was opened, not a
  // permanent per-file record. Reopening the app with data saver still
  // on means starting blurred again, same as every other data-saver
  // messaging app.
  final Set<String> _unlockedMedia = {};

  bool isUnlocked(String mediaKey) => _unlockedMedia.contains(mediaKey);

  void unlock(String mediaKey) {
    if (_unlockedMedia.add(mediaKey)) notifyListeners();
  }
}
