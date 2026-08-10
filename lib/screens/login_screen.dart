import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/account_manager_service.dart';
import '../services/supabase_service.dart';
import 'home_shell.dart';
import 'complete_profile_screen.dart';
import 'sign_up_screen.dart';

/// Log-in only — account creation lives in SignUpScreen now (email →
/// username → password steps, plus its own "Continue with Google"
/// option). Google is offered here too, not just on the sign-up
/// side: signInWithOAuth doesn't distinguish first-time from
/// returning, so it's also how a Google-only user (no password ever
/// set) logs back in.
class LoginScreen extends StatefulWidget {
  /// True when this screen was pushed on top of an already-signed-in
  /// session specifically to add another account (from the account
  /// switcher), rather than being the app's initial auth screen. This
  /// only changes copy/navigation on success — the sign-in call
  /// itself is identical either way.
  final bool isAddingAccount;

  LoginScreen({super.key, this.isAddingAccount = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _loading = false;
  bool _googleLoading = false;
  String? _error;

  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  StreamSubscription<AuthState>? _authSub;

  // Whichever account was already active *before* this screen opened
  // — only meaningful for the isAddingAccount case. Captured before
  // subscribing below, so _onAuthStateChange can tell a genuine new
  // sign-in apart from the spurious replay event described there.
  String? _previouslyActiveUserId;

  @override
  void initState() {
    super.initState();
    _previouslyActiveUserId = SupabaseService.instance.currentUser?.id;
    // Only actually needed for the isAddingAccount case — see
    // _onAuthStateChange. When this screen IS the app's primary auth
    // gate, AuthGate's own StreamBuilder already reacts to the same
    // event and swaps this screen out on its own; this listener just
    // becomes a no-op in that case (the isAddingAccount check below
    // returns immediately).
    _authSub =
        SupabaseService.instance.authStateChanges.listen(_onAuthStateChange);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  /// Supabase's `onAuthStateChange` doesn't only fire on a genuinely
  /// new sign-in — the moment anything subscribes to it (i.e. the
  /// instant this screen's initState runs), it immediately replays a
  /// `signedIn` event for whichever session is *already* active. For
  /// the isAddingAccount case that's account A's own already-signed-in
  /// session, not the new account B someone is here to add — without
  /// the guard below, that replay was read as "a sign-in just
  /// completed" and navigated straight back to HomeShell before the
  /// person had even touched the form, which is why the screen used
  /// to flash and disappear the instant it opened.
  Future<void> _onAuthStateChange(AuthState state) async {
    if (!widget.isAddingAccount) return;
    if (state.event != AuthChangeEvent.signedIn) return;
    final user = SupabaseService.instance.currentUser;
    if (user == null || !mounted) return;
    if (user.id == _previouslyActiveUserId) return; // the replay above

    await AccountManagerService.instance.rememberCurrentSession();
    if (!mounted) return;

    final hasProfile = await SupabaseService.instance.hasProfile(user.id);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(
          builder: (_) => hasProfile ? HomeShell() : CompleteProfileScreen()),
      (route) => false,
    );
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await SupabaseService.instance.signIn(
        identifier: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
      );

      // Snapshot this account's session + profile summary so it shows
      // up in the account switcher and can be switched back to later,
      // even offline.
      await AccountManagerService.instance.rememberCurrentSession();

      // Navigation itself is left entirely to _onAuthStateChange
      // (isAddingAccount) / AuthGate's own stream listener (primary
      // sign-in) — both already react to the exact signedIn event
      // `signIn()` above just triggered. Doing it again here would
      // race the same navigation against _onAuthStateChange's.
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _continueWithGoogle() async {
    setState(() { _googleLoading = true; _error = null; });
    try {
      await SupabaseService.instance.signInWithGoogle();
      // Resolves once the external browser's been launched, not once
      // sign-in completes — _onAuthStateChange (isAddingAccount case)
      // or AuthGate (primary case) picks up from here.
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _googleLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _loading || _googleLoading;
    return Scaffold(
      appBar: widget.isAddingAccount
          ? AppBar(title: Text('Add account'))
          : null,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: widget.isAddingAccount ? 8 : 48),
              Text(
                'Reality Merge',
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              Text(
                widget.isAddingAccount
                    ? 'Sign in with another account.'
                    : 'The world is no longer empty.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              SizedBox(height: 32),
              TextField(
                controller: _emailCtrl,
                decoration: InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
              ),
              SizedBox(height: 12),
              TextField(
                controller: _passwordCtrl,
                decoration: InputDecoration(labelText: 'Password'),
                obscureText: true,
              ),
              SizedBox(height: 24),
              if (_error != null)
                Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: TextStyle(color: Colors.red)),
                ),
              FilledButton(
                onPressed: busy ? null : _submit,
                child: _loading
                    ? SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text('Log in'),
              ),
              SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: Divider()),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('or', style: TextStyle(color: Colors.grey)),
                  ),
                  Expanded(child: Divider()),
                ],
              ),
              SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: busy ? null : _continueWithGoogle,
                icon: _googleLoading
                    ? SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.g_mobiledata_rounded, size: 24),
                label: Text('Continue with Google'),
              ),
              SizedBox(height: 12),
              TextButton(
                onPressed: busy
                    ? null
                    : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => SignUpScreen(
                                isAddingAccount: widget.isAddingAccount),
                          ),
                        ),
                child: Text("Don't have an account? Sign up"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
