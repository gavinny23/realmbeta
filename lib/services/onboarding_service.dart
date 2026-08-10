import 'package:shared_preferences/shared_preferences.dart';

class OnboardingService {
  OnboardingService._();
  static final OnboardingService instance = OnboardingService._();

  static const _keyFeedTutorial = 'seen_feed_tutorial';
  static const _keyMapTutorial  = 'seen_map_tutorial';
  static const _keyDropTutorial = 'seen_drop_tutorial';

  Future<bool> shouldShowFeedTutorial() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_keyFeedTutorial) ?? false);
  }

  Future<bool> shouldShowMapTutorial() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_keyMapTutorial) ?? false);
  }

  Future<bool> shouldShowDropTutorial() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_keyDropTutorial) ?? false);
  }

  Future<void> markFeedTutorialSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyFeedTutorial, true);
  }

  Future<void> markMapTutorialSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMapTutorial, true);
  }

  Future<void> markDropTutorialSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDropTutorial, true);
  }

  /// Resets only the tutorial-seen flags. Deliberately scoped to just
  /// these three keys — do NOT replace this with a blanket
  /// `prefs.clear()` at the call site, since SharedPreferences is
  /// shared with everything else the app persists locally (chat
  /// history/outbox, cached feed, theme, data-saver setting, etc.)
  /// and a blanket clear would silently wipe all of it.
  Future<void> resetAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyFeedTutorial);
    await prefs.remove(_keyMapTutorial);
    await prefs.remove(_keyDropTutorial);
  }
}
