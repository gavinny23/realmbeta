import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../services/account_manager_service.dart';
import '../theme/rm_theme.dart';
import 'login_screen.dart';
import 'complete_profile_screen.dart';
import 'home_shell.dart';

/// Routes between LoginScreen, CompleteProfileScreen, and HomeShell
/// based on both auth state and profile existence — not just auth
/// state alone. Those can now diverge: a first-time Google sign-in
/// (see SupabaseService.signInWithGoogle) produces a real Supabase
/// Auth session with no profiles row yet, since Google gives no
/// concept of "username" for SupabaseService.signUp's normal
/// email/password path to use. CompleteProfileScreen is what fills
/// that gap in before HomeShell (and everything it assumes a profile
/// row exists for) ever mounts.
class AuthGate extends StatefulWidget {
  AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  /// [SupabaseService.hasProfile] is a plain network round trip with
  /// no timeout of its own. On a cold, fully-offline launch that's
  /// restoring a session from disk (see main.dart's Supabase.initialize
  /// comment — restoring a session doesn't require this check to have
  /// ever succeeded before), that call can simply hang, and a
  /// FutureBuilder waiting on it never gets data — the person sees an
  /// infinite spinner and can never reach HomeShell, even though
  /// FeedScreen/LocalCacheService are perfectly able to show cached
  /// content with no connection at all.
  ///
  /// Bounded here instead: if the check doesn't come back within
  /// [_profileCheckTimeout], fall back to whether this device has
  /// *ever* successfully used this account before (a purely local,
  /// network-free check — see AccountManagerService's own doc
  /// comment). That's true for exactly the case this matters for —
  /// a previously-signed-in session being restored offline — so
  /// those people land in HomeShell same as always. A session that's
  /// never been active on this device before (e.g. mid first-time
  /// Google sign-in) has no such local record, so it still surfaces
  /// the error below instead of guessing; completing a profile needs
  /// a network call anyway, so there's no working offline path to
  /// fall back to for that case regardless.
  static const _profileCheckTimeout = Duration(seconds: 8);

  // Bumped on every "Retry" tap to force the FutureBuilder below to
  // key off a fresh future instead of replaying the same failed one.
  int _retryCount = 0;

  Future<bool> _resolveHasProfile(String userId) async {
    try {
      return await SupabaseService.instance
          .hasProfile(userId)
          .timeout(_profileCheckTimeout);
    } catch (_) {
      final saved = await AccountManagerService.instance.loadSavedAccounts();
      final knownLocally = saved.any((a) => a.id == userId);
      if (knownLocally) return true;
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: SupabaseService.instance.authStateChanges,
      builder: (context, snapshot) {
        final session = SupabaseService.instance.currentUser;
        if (session == null) {
          return LoginScreen();
        }
        return FutureBuilder<bool>(
          // Keyed by user id (and by _retryCount, so a manual retry
          // always starts a fresh check) so switching accounts, or a
          // fresh sign-in replacing an anonymous/expired one, re-runs
          // this instead of reusing a stale result from a previous user.
          key: ValueKey('${session.id}_$_retryCount'),
          future: _resolveHasProfile(session.id),
          builder: (context, profileSnapshot) {
            if (profileSnapshot.connectionState != ConnectionState.done) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            // Genuinely offline with no local record of this account
            // (see _resolveHasProfile) — nothing sensible to route to,
            // so say so plainly instead of leaving the spinner up
            // forever with no explanation.
            if (profileSnapshot.hasError) {
              return Scaffold(
                backgroundColor: RMColors.background,
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.wifi_off_rounded, size: 40),
                        const SizedBox(height: 12),
                        const Text(
                          "Can't reach Realm right now. Check your "
                          'connection and try again.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () => setState(() => _retryCount++),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            return profileSnapshot.data!
                ? HomeShell()
                : CompleteProfileScreen();
          },
        );
      },
    );
  }
}
