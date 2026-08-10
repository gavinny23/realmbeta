import 'package:flutter/material.dart';
import '../services/account_manager_service.dart';
import '../services/supabase_service.dart';
import '../widgets/location_autocomplete_field.dart';

/// Shown by AuthGate when someone has a Supabase Auth session but no
/// profiles row yet — in practice, always a first-time Google
/// sign-in, since the normal email/password path (SignUpScreen)
/// always creates the profile in the same flow as the auth account.
/// Google gives an email and a display name for free but no concept
/// of "username", which is the one thing this really has to collect.
class CompleteProfileScreen extends StatefulWidget {
  CompleteProfileScreen({super.key});

  @override
  State<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends State<CompleteProfileScreen> {
  final _usernameCtrl = TextEditingController();
  final _displayNameCtrl = TextEditingController();
  String _homeCity = '';
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Google hands back a display name (and sometimes an avatar,
    // handled server-side by Supabase Auth's own identity fields)
    // for free — prefilled here purely as a convenience, still fully
    // editable before submitting.
    final metadata = SupabaseService.instance.currentUser?.userMetadata;
    final suggestedName =
        metadata?['full_name'] as String? ?? metadata?['name'] as String?;
    if (suggestedName != null) _displayNameCtrl.text = suggestedName;
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _displayNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _usernameCtrl.text.trim();
    final displayName = _displayNameCtrl.text.trim();
    if (username.isEmpty) {
      setState(() => _error = 'Pick a username to continue.');
      return;
    }
    if (displayName.isEmpty) {
      setState(() => _error = 'Add a display name to continue.');
      return;
    }

    setState(() { _loading = true; _error = null; });
    try {
      if (await SupabaseService.instance.usernameIsTaken(username)) {
        setState(() => _error = 'That username is already taken.');
        return;
      }
      await SupabaseService.instance.completeProfile(
        username: username,
        displayName: displayName,
        homeCity: _homeCity.isEmpty ? null : _homeCity,
      );
      await AccountManagerService.instance.rememberCurrentSession();
      // No navigation call needed — AuthGate's FutureBuilder re-runs
      // hasProfile() once this rebuilds up the tree and finds a
      // profiles row now, same as its normal signed-in path.
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: 48),
              Text(
                'Almost there',
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              Text(
                'Pick a username to finish setting up your account.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              SizedBox(height: 32),
              TextField(
                controller: _usernameCtrl,
                decoration: InputDecoration(labelText: 'Username'),
                autocorrect: false,
              ),
              SizedBox(height: 12),
              TextField(
                controller: _displayNameCtrl,
                decoration: InputDecoration(labelText: 'Display name'),
              ),
              SizedBox(height: 12),
              LocationAutocompleteField(
                label: 'Home city (optional)',
                onSelected: (value) => setState(() => _homeCity = value),
              ),
              SizedBox(height: 24),
              if (_error != null)
                Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: TextStyle(color: Colors.red)),
                ),
              FilledButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text('Continue'),
              ),
              TextButton(
                onPressed: _loading
                    ? null
                    : () => SupabaseService.instance.signOut(),
                child: Text('Sign out instead'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
