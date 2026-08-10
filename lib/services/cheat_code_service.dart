import 'package:flutter/foundation.dart';
import '../models/profile_rank.dart';
import 'app_storage_service.dart';
import 'supabase_service.dart';

/// Result of attempting to redeem a cheat code — carries enough info
/// for the UI to show a pass/fail dialog without reaching back into
/// the service. [rank] is only set for codes that return live data
/// (currently just "/my-rank") rather than toggling a local flag.
class CheatCodeResult {
  final bool passed;
  final String title;
  final String message;
  final ProfileRank? rank;
  const CheatCodeResult({
    required this.passed,
    required this.title,
    required this.message,
    this.rank,
  });
}

/// Local, on-device-only "cheat codes" for previewing states of the
/// app that would otherwise take a real event to reach (e.g. what a
/// verified profile looks like), plus one code ("/my-rank") that pulls
/// a real, live comparison against other profiles rather than faking
/// anything.
///
/// Everything except "/my-rank" is purely cosmetic device state:
/// nothing is synced to Supabase and nothing is visible to any other
/// account, so it can't be used to fake a trust signal to other real
/// people. "/my-rank" is different in kind — it doesn't set any local
/// flag at all, it just asks the server where you honestly stand
/// (see supabase/v21-migration.sql) and shows you that.
///
/// Enabled/disabled via a switch in Dev Hub. While enabled, typing a
/// recognized trigger phrase into any text field wired up with
/// [CheatCodeService.matchTrigger] runs that code.
class CheatCodeService extends ChangeNotifier {
  CheatCodeService._();
  static final CheatCodeService instance = CheatCodeService._();

  static const _storageKey = 'cheat_code_state';

  // Trigger phrases. Add a new one here, a case in [redeem], and (for
  // anything with a UI treatment) a getter below.
  static const String verifiedTrigger = '/get-verified';
  static const String goldFrameTrigger = '/gold-frame';
  static const String ogBadgeTrigger = '/og-badge';
  static const String rankTrigger = '/my-rank';

  static const Duration verifiedDuration = Duration(days: 3);
  static const Duration goldFrameDuration = Duration(hours: 24);

  static const List<String> _allTriggers = [
    verifiedTrigger,
    goldFrameTrigger,
    ogBadgeTrigger,
    rankTrigger,
  ];

  bool _enabled = false;
  DateTime? _verifiedUntil;
  DateTime? _goldFrameUntil;
  bool _ogBadge = false;
  bool _loaded = false;

  bool get enabled => _enabled;

  /// True once [load] has resolved at least once for the currently
  /// active account. [main.dart] fires [load] off without awaiting it,
  /// so the very first frame of anything reading this service's status
  /// (e.g. Dev Hub's cheat-code status rows) can land before the saved
  /// state has actually been read back — this lets that UI show a
  /// loading treatment instead of silently rendering stale defaults
  /// for a moment.
  bool get isLoaded => _loaded;

  bool get isVerified =>
      _verifiedUntil != null && DateTime.now().isBefore(_verifiedUntil!);

  Duration? get verifiedRemaining =>
      isVerified ? _verifiedUntil!.difference(DateTime.now()) : null;

  bool get hasGoldFrame =>
      _goldFrameUntil != null && DateTime.now().isBefore(_goldFrameUntil!);

  Duration? get goldFrameRemaining =>
      hasGoldFrame ? _goldFrameUntil!.difference(DateTime.now()) : null;

  bool get hasOgBadge => _ogBadge;

  /// If [text] (trimmed, case-insensitive) exactly matches a known
  /// trigger phrase, returns that trigger constant — otherwise null.
  /// Call from a field's onChanged/onSubmitted, then pass the result
  /// to [redeem] if non-null.
  String? matchTrigger(String text) {
    final normalized = text.trim().toLowerCase();
    for (final t in _allTriggers) {
      if (normalized == t) return t;
    }
    return null;
  }

  /// Loads this account's saved cheat state. Safe to call again after
  /// switching accounts (`AppStorageService`'s namespacing means this
  /// reads whichever account is active at call time) — reset to
  /// defaults first so a switch to an account with nothing saved
  /// doesn't keep showing the previous account's state.
  Future<void> load() async {
    _enabled = false;
    _verifiedUntil = null;
    _goldFrameUntil = null;
    _ogBadge = false;
    _loaded = false;
    try {
      final saved = await AppStorageService.instance.loadMap(_storageKey);
      if (saved != null) {
        _enabled = saved['enabled'] as bool? ?? false;
        _ogBadge = saved['og_badge'] as bool? ?? false;
        final until = saved['verified_until'] as String?;
        _verifiedUntil = until != null ? DateTime.tryParse(until) : null;
        final goldUntil = saved['gold_frame_until'] as String?;
        _goldFrameUntil =
            goldUntil != null ? DateTime.tryParse(goldUntil) : null;
      }
    } catch (_) {
      // Best-effort; defaults are fine.
    } finally {
      _loaded = true;
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    if (!value) {
      // Turning cheat mode off also drops every active cheat state —
      // there's no reason a "disabled" toggle should still be quietly
      // granting any of these.
      _verifiedUntil = null;
      _goldFrameUntil = null;
      _ogBadge = false;
    }
    await _persist();
    notifyListeners();
  }

  /// Immediately clears every active local cheat state (not "/my-rank",
  /// which never sets any state to begin with). Handy in Dev Hub while
  /// testing so you don't have to wait one out.
  Future<void> clearAll() async {
    _verifiedUntil = null;
    _goldFrameUntil = null;
    _ogBadge = false;
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    await AppStorageService.instance.saveMap(_storageKey, {
      'enabled': _enabled,
      'verified_until': _verifiedUntil?.toIso8601String(),
      'gold_frame_until': _goldFrameUntil?.toIso8601String(),
      'og_badge': _ogBadge,
    });
  }

  /// Runs whichever code [trigger] names (one of the `*Trigger`
  /// constants above — get it from [matchTrigger]). Fails outright (no
  /// delay) if cheat mode is off — that's true for "/my-rank" too,
  /// since the toggle is what makes any of these phrases "live" in a
  /// text field at all. Every code except "/my-rank" then simulates a
  /// short processing delay so the loading UI has something to show;
  /// "/my-rank" instead does a real (usually just as quick) network
  /// fetch, since it's live data rather than a local flag flip.
  Future<CheatCodeResult> redeem(String trigger) async {
    if (!_enabled) {
      return const CheatCodeResult(
        passed: false,
        title: 'Cheat codes are off',
        message: 'Turn on Cheat Codes in Dev Hub first, then try again.',
      );
    }
    if (trigger == rankTrigger) return _runMyRank();

    await Future.delayed(const Duration(milliseconds: 1400));
    switch (trigger) {
      case verifiedTrigger:
        return _runVerified();
      case goldFrameTrigger:
        return _runGoldFrame();
      case ogBadgeTrigger:
        return _runOgBadge();
      default:
        return const CheatCodeResult(
          passed: false,
          title: 'Unknown code',
          message: "That's not a recognized cheat code.",
        );
    }
  }

  Future<CheatCodeResult> _runVerified() async {
    _verifiedUntil = DateTime.now().add(verifiedDuration);
    await _persist();
    notifyListeners();
    return const CheatCodeResult(
      passed: true,
      title: '/get-verified — passed',
      message: 'Verified badge applied to your profile for 3 days.',
    );
  }

  Future<CheatCodeResult> _runGoldFrame() async {
    _goldFrameUntil = DateTime.now().add(goldFrameDuration);
    await _persist();
    notifyListeners();
    return const CheatCodeResult(
      passed: true,
      title: '/gold-frame — passed',
      message: 'Gold avatar ring applied for 24 hours.',
    );
  }

  Future<CheatCodeResult> _runOgBadge() async {
    _ogBadge = !_ogBadge;
    await _persist();
    notifyListeners();
    return CheatCodeResult(
      passed: true,
      title: '/og-badge — passed',
      message: _ogBadge
          ? 'Early-adopter badge added to your profile.'
          : 'Early-adopter badge removed.',
    );
  }

  Future<CheatCodeResult> _runMyRank() async {
    try {
      final rank = await SupabaseService.instance.fetchProfileRank();
      return CheatCodeResult(
        passed: true,
        title: 'Your rank',
        message: 'Here\'s how you compare to everyone else right now.',
        rank: rank,
      );
    } catch (e) {
      return const CheatCodeResult(
        passed: false,
        title: "Couldn't load your rank",
        message: 'Check your connection and try again.',
      );
    }
  }
}
