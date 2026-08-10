import 'dart:async';
import 'supabase_service.dart';

/// Keeps the current user's `profiles.last_active_at` fresh so other
/// people's clients can render an accurate green-dot / "last seen Xm
/// ago" badge (see [PresenceAvatar]) next to this person's avatar.
///
/// There's no session-end hook here on purpose — see the migration
/// comment on `touch_presence()` for why a timestamp beats a boolean
/// flag. All this does is call it: once immediately whenever the app
/// comes to the foreground, and then on a repeating timer while it
/// stays there. [PresenceAvatar.onlineWindow] is deliberately a bit
/// wider than [_heartbeatInterval] so a heartbeat landing a few
/// seconds late never makes someone flicker offline.
class PresenceService {
  PresenceService._();
  static final PresenceService instance = PresenceService._();

  static const _heartbeatInterval = Duration(seconds: 60);

  Timer? _timer;

  /// Call once the person is signed in and the app is in the
  /// foreground (app startup, and again on every resume).
  void start() {
    _beat();
    _timer ??= Timer.periodic(_heartbeatInterval, (_) => _beat());
  }

  /// Call when the app is backgrounded — stops the timer so a
  /// suspended app doesn't keep firing heartbeats it can't actually
  /// deliver reliably anyway. Presence simply ages out into "offline"
  /// on its own once heartbeats stop; nothing needs to be flipped
  /// explicitly here.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _beat() async {
    if (SupabaseService.instance.currentUser == null) return;
    try {
      await SupabaseService.instance.touchPresence();
    } catch (_) {
      // Best-effort — a missed heartbeat just means this person's
      // badge elsewhere reads as "offline" a little early. Never
      // worth surfacing an error over.
    }
  }
}
