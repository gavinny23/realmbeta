import 'package:flutter/material.dart';
import '../models/saved_account.dart';
import '../screens/home_shell.dart';
import '../screens/login_screen.dart';
import '../services/account_manager_service.dart';
import '../services/cheat_code_service.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';

/// Opens the account switcher as a modal bottom sheet. Call this from
/// anywhere the person should be able to switch/add/remove accounts —
/// currently the Profile screen's Account section.
void showAccountSwitcherSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: RMColors.surface,
    shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => _AccountSwitcherSheet(),
  );
}

/// Drops the entire navigation stack and rebuilds fresh from
/// [HomeShell] — used any time the active account changes underneath
/// an already-running app (switching, or finishing an "add account"
/// sign-in) so every screen re-initializes and re-caches under the
/// new account instead of risking stale state left over from the
/// previous one.
void relaunchToFreshHome(BuildContext context) {
  Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => HomeShell()),
    (route) => false,
  );
}

class _AccountSwitcherSheet extends StatefulWidget {
  @override
  State<_AccountSwitcherSheet> createState() => _AccountSwitcherSheetState();
}

class _AccountSwitcherSheetState extends State<_AccountSwitcherSheet> {
  List<SavedAccount> _accounts = [];
  String? _activeId;
  bool _loading = true;
  String? _busyId; // account currently being switched to/removed

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final accounts = await AccountManagerService.instance.loadSavedAccounts();
    final activeId = SupabaseService.instance.currentUser?.id;
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _activeId = activeId;
      _loading = false;
    });
  }

  Future<void> _switchTo(SavedAccount account) async {
    if (account.id == _activeId) return;
    setState(() => _busyId = account.id);
    try {
      final ok =
          await AccountManagerService.instance.switchToAccount(account.id);
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'That account needs a fresh sign-in — it was removed from this device.')),
        );
        setState(() => _busyId = null);
        return;
      }
      await CheatCodeService.instance.load();
      if (!mounted) return;
      Navigator.of(context).pop();
      relaunchToFreshHome(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                "Couldn't switch — this account's session had expired and needs a connection to refresh.")),
      );
      setState(() => _busyId = null);
    }
  }

  Future<void> _remove(SavedAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: RMColors.surface,
        title: Text('Remove account', style: TextStyle(color: RMColors.textPrimary)),
        content: Text(
          'Remove ${account.displayName.isNotEmpty ? account.displayName : account.username} from this device? You can always sign back in later.',
          style: TextStyle(color: RMColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel', style: TextStyle(color: RMColors.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busyId = account.id);
    await AccountManagerService.instance.forgetAccount(account.id);
    await _load();
  }

  Future<void> _addAnother() async {
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LoginScreen(isAddingAccount: true)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: RMColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            SizedBox(height: 20),
            Text('Switch account',
                style: TextStyle(
                    color: RMColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 17)),
            SizedBox(height: 16),
            if (_loading)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_accounts.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No other accounts saved on this device yet.',
                  style: TextStyle(color: RMColors.textSecondary),
                ),
              )
            else
              ..._accounts.map((a) => _AccountRow(
                    account: a,
                    isActive: a.id == _activeId,
                    isBusy: _busyId == a.id,
                    onTap: () => _switchTo(a),
                    onRemove: a.id == _activeId ? null : () => _remove(a),
                  )),
            SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _addAnother,
              icon: Icon(Icons.add_rounded, size: 20),
              label: Text('Add another account'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  final SavedAccount account;
  final bool isActive;
  final bool isBusy;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  _AccountRow({
    required this.account,
    required this.isActive,
    required this.isBusy,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final name =
        account.displayName.isNotEmpty ? account.displayName : account.username;
    return Container(
      margin: EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isActive ? RMColors.primaryDim : RMColors.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: isActive ? RMColors.primary : RMColors.border),
      ),
      child: ListTile(
        onTap: isBusy || isActive ? null : onTap,
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14)),
        leading: CircleAvatar(
          radius: 20,
          backgroundColor: RMColors.surface,
          backgroundImage: account.avatarUrl != null
              ? NetworkImage(account.avatarUrl!)
              : null,
          child: account.avatarUrl == null
              ? Text(
                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: TextStyle(color: RMColors.textPrimary),
                )
              : null,
        ),
        title: Text(name,
            style: TextStyle(
                color: RMColors.textPrimary, fontWeight: FontWeight.w600)),
        subtitle: Text(
          account.username.isNotEmpty ? '@${account.username}' : account.email,
          style: TextStyle(color: RMColors.textSecondary, fontSize: 12),
        ),
        trailing: isBusy
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : isActive
                ? Icon(Icons.check_circle_rounded, color: RMColors.primary)
                : onRemove != null
                    ? IconButton(
                        icon: Icon(Icons.close_rounded,
                            color: RMColors.textHint, size: 20),
                        onPressed: onRemove,
                        tooltip: 'Remove from this device',
                      )
                    : null,
      ),
    );
  }
}
