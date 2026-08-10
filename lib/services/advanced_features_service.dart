import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted toggles for opt-in features that most people never touch
/// and would otherwise just clutter Profile for everyone — right now
/// that's just Dev Hub (connecting GitHub, browsing/editing repos,
/// committing from the in-app editor or terminal), which only means
/// anything to someone who actually maintains a repo.
///
/// Off by default. Turning "Dev Hub" on here — from Profile →
/// Settings → Additional features — is what makes the Dev Hub entry
/// under Profile → Developer appear at all; it stays hidden for
/// everyone who hasn't opted in.
///
/// Follows the same singleton + SharedPreferences pattern as
/// [DataSaverService] so it can be read synchronously anywhere in the
/// app once [init] has run at startup.
class AdvancedFeaturesService extends ChangeNotifier {
  AdvancedFeaturesService._();
  static final AdvancedFeaturesService instance = AdvancedFeaturesService._();

  static const _devHubPrefsKey = 'rm_advanced_dev_hub_enabled';

  bool _devHubEnabled = false;
  bool get devHubEnabled => _devHubEnabled;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _devHubEnabled = prefs.getBool(_devHubPrefsKey) ?? false;
    } catch (_) {
      // Prefs unavailable — default to off, same fallback every other
      // toggle in this app takes when storage can't be reached.
    }
  }

  Future<void> setDevHubEnabled(bool value) async {
    if (_devHubEnabled == value) return;
    _devHubEnabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_devHubPrefsKey, value);
    } catch (_) {
      // Best-effort persistence, same as DataSaverService.setEnabled —
      // the in-memory value (and the notifyListeners() above) already
      // took effect either way, so the toggle itself doesn't hang or
      // silently fail to respond even if the write does.
    }
  }
}
