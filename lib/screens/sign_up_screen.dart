import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/account_manager_service.dart';
import '../services/supabase_service.dart';
import 'home_shell.dart';
import 'complete_profile_screen.dart';

/// Account creation: a choice screen (Google vs. manual), then for
/// manual sign-up, one field per step — email, then username, then
/// password + confirm — rather than one long form. Each step's
/// availability check (email/username already taken) happens right
/// when someone tries to move past it, not just at the very end.
class SignUpScreen extends StatefulWidget {
  /// Same meaning as LoginScreen.isAddingAccount — passed through
  /// since Sign up is reachable both as the app's primary entry point
  /// and from "add another account".
  final bool isAddingAccount;

  SignUpScreen({super.key, this.isAddingAccount = false});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

enum _Step { choice, email, username, password }

class _SignUpScreenState extends State<SignUpScreen> {
  _Step _step = _Step.choice;
  bool _loading = false;
  bool _googleLoading = false;
  String? _error;

  final _emailCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  StreamSubscription<AuthState>? _authSub;

  static final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  static final _usernamePattern = RegExp(r'^[A-Za-z0-9_]{3,20}$');

  @override
  void initState() {
    super.initState();
    // Same purpose as the identical listener in LoginScreen — only
    // ever matters for the isAddingAccount case; the primary
    // (not-yet-signed-in) case is handled by AuthGate's own
    // StreamBuilder instead. See that listener's comment for why.
    _authSub =
        SupabaseService.instance.authStateChanges.listen(_onAuthStateChange);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _emailCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _onAuthStateChange(AuthState state) async {
    if (!widget.isAddingAccount) return;
    if (state.event != AuthChangeEvent.signedIn) return;
    final user = SupabaseService.instance.currentUser;
    if (user == null || !mounted) return;

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

  Future<void> _continueWithGoogle() async {
    setState(() { _googleLoading = true; _error = null; });
    try {
      await SupabaseService.instance.signInWithGoogle();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _googleLoading = false);
    }
  }

  Future<void> _nextFromEmail() async {
    final email = _emailCtrl.text.trim();
    if (!_emailPattern.hasMatch(email)) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      if (await SupabaseService.instance.emailIsRegistered(email)) {
        setState(() => _error = 'An account with this email already exists.');
        return;
      }
      setState(() => _step = _Step.username);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _nextFromUsername() async {
    final username = _usernameCtrl.text.trim();
    if (!_usernamePattern.hasMatch(username)) {
      setState(() => _error =
          '3-20 characters — letters, numbers, and underscores only.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      if (await SupabaseService.instance.usernameIsTaken(username)) {
        setState(() => _error = 'That username is already taken.');
        return;
      }
      setState(() => _step = _Step.password);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final password = _passwordCtrl.text;
    final confirm = _confirmCtrl.text;
    if (password.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }
    if (password != confirm) {
      setState(() => _error = "Passwords don't match.");
      return;
    }

    setState(() { _loading = true; _error = null; });
    try {
      final username = _usernameCtrl.text.trim();
      await SupabaseService.instance.signUp(
        email: _emailCtrl.text.trim(),
        password: password,
        username: username,
        // Kept to exactly the three fields asked for (email, username,
        // password) rather than adding a fourth "display name" step —
        // this just defaults to the username, editable later from the
        // profile screen. Home city likewise isn't collected here;
        // it's optional in the schema and can be added afterward too.
        displayName: username,
        homeCity: '',
      );

      await AccountManagerService.instance.rememberCurrentSession();

      if (!mounted) return;
      if (widget.isAddingAccount) {
        Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => HomeShell()),
          (route) => false,
        );
      }
      // Otherwise AuthGate's stream listener handles navigation.
    } on PostgrestException catch (e) {
      // The username-availability check above already covers the
      // common case — this only fires on the narrow race where
      // someone else grabbed the same username in between that check
      // and this insert. Postgres' unique-violation code (23505) is
      // the one case worth a friendlier message than the raw
      // Postgres error text.
      setState(() => _error = e.code == '23505'
          ? 'That username was just taken — go back and try another.'
          : e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _back() {
    setState(() {
      _error = null;
      _step = switch (_step) {
        _Step.email => _Step.choice,
        _Step.username => _Step.email,
        _Step.password => _Step.username,
        _Step.choice => _Step.choice,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final busy = _loading || _googleLoading;
    return Scaffold(
      appBar: AppBar(
        title: Text('Sign up'),
        leading: _step == _Step.choice
            ? null
            : IconButton(
                icon: Icon(Icons.arrow_back),
                onPressed: busy ? null : _back,
              ),
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: _buildStep(),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: TextStyle(color: Colors.red)),
                ),
              _buildAction(busy),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case _Step.choice:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: 24),
            Text(
              'Create your account',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 32),
            OutlinedButton.icon(
              onPressed: (_loading || _googleLoading) ? null : _continueWithGoogle,
              icon: _googleLoading
                  ? SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.g_mobiledata_rounded, size: 24),
              label: Text('Continue with Google'),
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
            FilledButton(
              onPressed: (_loading || _googleLoading)
                  ? null
                  : () => setState(() => _step = _Step.email),
              child: Text('Sign up with email'),
            ),
          ],
        );

      case _Step.email:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: 24),
            Text('What\'s your email?',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center),
            SizedBox(height: 24),
            TextField(
              controller: _emailCtrl,
              decoration: InputDecoration(labelText: 'Email'),
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
              onSubmitted: (_) => _nextFromEmail(),
            ),
          ],
        );

      case _Step.username:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: 24),
            Text('Pick a username',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center),
            SizedBox(height: 24),
            TextField(
              controller: _usernameCtrl,
              decoration: InputDecoration(labelText: 'Username'),
              autocorrect: false,
              autofocus: true,
              onSubmitted: (_) => _nextFromUsername(),
            ),
          ],
        );

      case _Step.password:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: 24),
            Text('Set a password',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center),
            SizedBox(height: 24),
            TextField(
              controller: _passwordCtrl,
              decoration: InputDecoration(labelText: 'Password'),
              obscureText: true,
              autofocus: true,
            ),
            SizedBox(height: 12),
            TextField(
              controller: _confirmCtrl,
              decoration: InputDecoration(labelText: 'Confirm password'),
              obscureText: true,
              onSubmitted: (_) => _submit(),
            ),
          ],
        );
    }
  }

  Widget _buildAction(bool busy) {
    if (_step == _Step.choice) return SizedBox.shrink();

    final label = switch (_step) {
      _Step.email => 'Next',
      _Step.username => 'Next',
      _Step.password => 'Create account',
      _Step.choice => '',
    };
    final onPressed = switch (_step) {
      _Step.email => _nextFromEmail,
      _Step.username => _nextFromUsername,
      _Step.password => _submit,
      _Step.choice => null,
    };

    return FilledButton(
      onPressed: busy ? null : onPressed,
      child: _loading
          ? SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Text(label),
    );
  }
}
