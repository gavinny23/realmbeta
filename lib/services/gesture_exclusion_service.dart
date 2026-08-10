import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Talks to the native side (see `MainActivity.kt`) to reserve the
/// left edge of the screen for our own Drawer-open swipe instead of
/// letting Android's gesture-navigation "back" swipe steal it. Only
/// meaningful on Android; a no-op everywhere else.
///
/// Screens that own a left-side [Drawer] should call [enable] in
/// `initState`/`didPush` and [disable] in `dispose`/when navigating
/// away, so the exclusion only applies while that drawer is actually
/// reachable.
class GestureExclusionService {
  GestureExclusionService._();
  static final GestureExclusionService instance = GestureExclusionService._();

  static const _channel = MethodChannel('reality_merge/gesture_exclusion');

  Future<void> enable() => _set(true);
  Future<void> disable() => _set(false);

  Future<void> _set(bool enabled) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _channel
            .invokeMethod('setLeftEdgeExclusion', {'enabled': enabled});
      } catch (_) {
        // Best-effort only — worst case the OS back gesture wins on
        // some devices and the drawer stays reachable via the app bar.
      }
    }
  }
}
