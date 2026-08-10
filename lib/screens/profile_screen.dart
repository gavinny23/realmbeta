import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import '../models/profile_stats.dart';
import '../services/account_manager_service.dart';
import '../services/advanced_features_service.dart';
import '../services/app_storage_service.dart';
import '../services/cheat_code_service.dart';
import '../services/data_saver_service.dart';
import '../services/onboarding_service.dart';
import '../services/privacy_settings_sync_service.dart';
import '../services/profile_fields_sync_service.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/account_switcher_sheet.dart';
import '../widgets/cheat_code_trigger.dart';
import '../widgets/location_autocomplete_field.dart';
import '../widgets/emoji_input.dart';
import 'coin_flip_screen.dart';
import 'dev_hub_screen.dart';
import 'followers_screen.dart';
import 'my_drops_gallery_screen.dart';

class ProfileScreen extends StatefulWidget {
  ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  ProfileStats? _stats;
  bool _loading = true;
  bool _uploadingAvatar = false;

  static const _statsKey = 'profile_stats';

  StreamSubscription<void>? _syncedSub;
  StreamSubscription<void>? _conflictSub;

  @override
  void initState() {
    super.initState();
    CheatCodeService.instance.addListener(_onCheatCodeChanged);
    _load();
    // A profile-field edit queued while offline (see
    // _EditProfileSheet) can finish syncing well after that sheet's
    // already closed — this screen stays mounted for as long as the
    // Profile tab does, so it's the right place to pick up both
    // outcomes: refresh the visible username/display name once a
    // sync actually lands, and let the person know if a queued
    // username turned out to be taken by someone else in the
    // meantime, since that's not something retrying on its own can
    // ever resolve.
    _syncedSub =
        ProfileFieldsSyncService.instance.onSynced.listen((_) => _load());
    _conflictSub =
        ProfileFieldsSyncService.instance.onUsernameConflict.listen((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'That username got taken before your change could sync — '
              'open Edit profile to pick a different one.')));
    });
  }

  @override
  void dispose() {
    CheatCodeService.instance.removeListener(_onCheatCodeChanged);
    _syncedSub?.cancel();
    _conflictSub?.cancel();
    super.dispose();
  }

  void _onCheatCodeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) return;

    // Best-effort, not awaited: keeps the account switcher's stored
    // avatar/display name in sync after edits, without blocking this
    // screen's own stats load on it.
    unawaited(AccountManagerService.instance.refreshCurrentAccountSummary());

    // Cache-first: show the last-known stats immediately, no spinner,
    // works fully offline. This lives in AppStorageService (not
    // LocalCacheService) precisely so it isn't treated as disposable.
    final cached = await AppStorageService.instance.loadMap(_statsKey);
    if (cached != null && mounted) {
      setState(() {
        _stats = ProfileStats.fromMap(cached);
        _loading = false;
      });
    }

    try {
      final stats = await SupabaseService.instance.fetchProfileStats(user.id);
      if (mounted) setState(() { _stats = stats; _loading = false; });
      if (stats != null) {
        await AppStorageService.instance.saveMap(_statsKey, stats.toMap());
      }
    } catch (_) {
      // Offline (or a transient failure) — keep showing cached stats,
      // if any, instead of blocking on an error.
      if (mounted && _stats == null) setState(() => _loading = false);
    }
  }

  Future<void> _changeAvatar() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: RMColors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.photo_camera_rounded, color: RMColors.textPrimary),
              title: Text('Take photo', style: TextStyle(color: RMColors.textPrimary)),
              onTap: () => Navigator.of(ctx).pop(ImageSource.camera),
            ),
            ListTile(
              leading: Icon(Icons.photo_library_rounded, color: RMColors.textPrimary),
              title: Text('Choose from gallery', style: TextStyle(color: RMColors.textPrimary)),
              onTap: () => Navigator.of(ctx).pop(ImageSource.gallery),
            ),
            SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null) return;

    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 85,
    );
    if (picked == null) return;

    setState(() => _uploadingAvatar = true);
    try {
      final bytes = await picked.readAsBytes();
      final ext = picked.name.contains('.')
          ? picked.name.split('.').last.toLowerCase()
          : 'jpg';
      await SupabaseService.instance.uploadAvatar(
        bytes: bytes,
        extension: ext == 'jpg' || ext == 'jpeg' || ext == 'png' ? ext : 'jpg',
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not update photo: $e')));
      }
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  List<_Badge> _getBadges(ProfileStats stats) {
    final badges = <_Badge>[];
    if (stats.dropsUnlocked >= 1)
      badges.add(_Badge(icon: Icons.flag_rounded, label: 'First Steps', color: RMColors.primary));
    if (stats.dropsUnlocked >= 10)
      badges.add(_Badge(icon: Icons.explore_rounded, label: 'Explorer', color: Color(0xFF00BCD4)));
    if (stats.dropsUnlocked >= 50)
      badges.add(_Badge(icon: Icons.public_rounded, label: 'World Walker', color: RMColors.success));
    if (stats.dropsCreated >= 1)
      badges.add(_Badge(icon: Icons.add_location_rounded, label: 'First Drop', color: RMColors.accent));
    if (stats.dropsCreated >= 5)
      badges.add(_Badge(icon: Icons.palette_rounded, label: 'Creator', color: Color(0xFFE040FB)));
    if (stats.dropsCreated >= 20)
      badges.add(_Badge(icon: Icons.star_rounded, label: 'Legend', color: RMColors.accent));
    return badges;
  }

  String _explorerTitle(int unlocked) {
    if (unlocked >= 50) return 'World Walker';
    if (unlocked >= 10) return 'Explorer';
    if (unlocked >= 1) return 'Wanderer';
    return 'Newcomer';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        title: Text('Profile'),
        backgroundColor: RMColors.background,
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: RMColors.primary))
          : SingleChildScrollView(
              padding: EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Avatar + info
                  Center(
                    child: Column(
                      children: [
                        GestureDetector(
                          onTap: _uploadingAvatar ? null : _changeAvatar,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Container(
                                width: 80,
                                height: 80,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: LinearGradient(
                                    colors: [RMColors.primary, RMColors.primaryDim],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  border: CheatCodeService.instance.hasGoldFrame
                                      ? Border.all(color: Colors.amber, width: 3)
                                      : null,
                                  image: _stats?.avatarUrl != null
                                      ? DecorationImage(
                                          image: CachedNetworkImageProvider(_stats!.avatarUrl!),
                                          fit: BoxFit.cover,
                                        )
                                      : null,
                                  boxShadow: [
                                    BoxShadow(
                                      color: RMColors.primary.withOpacity(0.3),
                                      blurRadius: 16,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                                child: _stats?.avatarUrl != null
                                    ? null
                                    : Center(
                                        child: Text(
                                          (_stats?.username ?? '?')[0].toUpperCase(),
                                          style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 32,
                                              fontWeight: FontWeight.w800),
                                        ),
                                      ),
                              ),
                              if (_uploadingAvatar)
                                Positioned.fill(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.black.withOpacity(0.45),
                                    ),
                                    child: Center(
                                      child: SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2, color: Colors.white),
                                      ),
                                    ),
                                  ),
                                ),
                              Positioned(
                                right: -2,
                                bottom: -2,
                                child: Container(
                                  padding: EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: RMColors.surface,
                                    border: Border.all(
                                        color: RMColors.background, width: 2),
                                  ),
                                  child: Icon(Icons.photo_camera_rounded,
                                      size: 14, color: RMColors.primary),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_stats?.avatarAiFlagged == true) ...[
                          SizedBox(height: 10),
                          Container(
                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: RMColors.surfaceAlt,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: RMColors.border),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.info_outline_rounded,
                                    size: 14, color: RMColors.textHint),
                                SizedBox(width: 6),
                                Text(
                                  'Profile photo flagged for review',
                                  style: TextStyle(
                                      color: RMColors.textHint,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500),
                                ),
                              ],
                            ),
                          ),
                        ],
                        SizedBox(height: 12),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '@${_stats?.username ?? ''}',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            if (CheatCodeService.instance.isVerified) ...[
                              const SizedBox(width: 6),
                              const VerifiedBadge(size: 18),
                            ],
                            if (CheatCodeService.instance.hasOgBadge) ...[
                              const SizedBox(width: 6),
                              const OgBadge(),
                            ],
                          ],
                        ),
                        SizedBox(height: 4),
                        Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: RMColors.primaryDim,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _explorerTitle(_stats?.dropsUnlocked ?? 0),
                            style: TextStyle(
                                color: RMColors.primary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 24),

                  // Stats row
                  Row(
                    children: [
                      Expanded(
                        child: _StatCard(
                          icon: Icons.people_alt_rounded,
                          label: 'Followers',
                          value: '${_stats?.followerCount ?? 0}',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const FollowersScreen()),
                          ),
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: _StatCard(
                          icon: Icons.add_location_alt_rounded,
                          label: 'Dropped',
                          value: '${_stats?.dropsCreated ?? 0}',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const MyDropsGalleryScreen()),
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 16),

                  // Progress bar
                  _buildProgress(_stats?.dropsUnlocked ?? 0),
                  SizedBox(height: 24),

                  // Badges
                  Text('Badges',
                      style: TextStyle(
                          color: RMColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 15)),
                  SizedBox(height: 12),
                  _stats == null || _getBadges(_stats!).isEmpty
                      ? Container(
                          padding: EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: RMColors.surface,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: RMColors.border),
                          ),
                          child: Text(
                            'No badges yet — explore drops to earn them.',
                            style: TextStyle(color: RMColors.textSecondary),
                          ),
                        )
                      : Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: _getBadges(_stats!)
                              .map((b) => _BadgeChip(badge: b))
                              .toList(),
                        ),
                  SizedBox(height: 28),

                  // Developer — hidden entirely unless "Dev Hub" has
                  // been turned on under Settings → Additional
                  // features below; most people never need this.
                  _DeveloperSection(),

                  // Settings section
                  Text('Settings',
                      style: TextStyle(
                          color: RMColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 15)),
                  SizedBox(height: 12),
                  _ThemeSettingsTile(),
                  _DataSaverSettingsTile(),
                  _SettingsTile(
                    icon: Icons.person_outline_rounded,
                    label: 'Edit profile',
                    onTap: () => _showEditProfile(context),
                  ),
                  _SettingsTile(
                    icon: Icons.notifications_none_rounded,
                    label: 'Notifications',
                    onTap: () => _showNotificationSettings(context),
                  ),
                  _SettingsTile(
                    icon: Icons.lock_outline_rounded,
                    label: 'Privacy',
                    onTap: () => _showPrivacySettings(context),
                  ),
                  _SettingsTile(
                    icon: Icons.monetization_on_outlined,
                    label: 'Coin flip',
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const CoinFlipScreen())),
                  ),
                  _SettingsTile(
                    icon: Icons.refresh_rounded,
                    label: 'Reset onboarding tutorials',
                    onTap: () async {
                      await OnboardingService.instance.resetAll();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text('Tutorials reset — reopen the app.')),
                        );
                      }
                    },
                  ),
                  SizedBox(height: 8),

                  // Additional features — opt-in toggles for things
                  // most people never need; Dev Hub is the first one.
                  // Turning it on here is what makes the Developer
                  // section above (and its Dev Hub entry) appear.
                  Text('Additional features',
                      style: TextStyle(
                          color: RMColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 15)),
                  SizedBox(height: 12),
                  _DevHubToggleTile(),
                  SizedBox(height: 8),

                  // Account section
                  Text('Account',
                      style: TextStyle(
                          color: RMColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 15)),
                  SizedBox(height: 12),
                  _SettingsTile(
                    icon: Icons.swap_horiz_rounded,
                    label: 'Switch account',
                    onTap: () => showAccountSwitcherSheet(context),
                  ),
                  _SettingsTile(
                    icon: Icons.logout_rounded,
                    label: 'Sign out',
                    onTap: () => _confirmSignOut(context),
                  ),
                  _SettingsTile(
                    icon: Icons.delete_outline_rounded,
                    label: 'Delete account',
                    destructive: true,
                    onTap: () => _confirmDeleteAccount(context),
                  ),
                  SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  Widget _buildProgress(int unlocked) {
    final milestones = [1, 10, 50];
    final next = milestones.firstWhere(
        (m) => m > unlocked, orElse: () => milestones.last);
    final prevIdx = milestones.indexOf(next) - 1;
    final prev = prevIdx < 0 ? 0 : milestones[prevIdx];
    final progress = unlocked >= next
        ? 1.0
        : (unlocked - prev) / (next - prev).toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Explorer progress',
                style: TextStyle(
                    color: RMColors.textSecondary, fontSize: 12)),
            Text('$unlocked / $next drops unlocked',
                style: TextStyle(
                    color: RMColors.textSecondary, fontSize: 12)),
          ],
        ),
        SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0).toDouble(),
            minHeight: 8,
            backgroundColor: RMColors.surfaceAlt,
            valueColor:
                AlwaysStoppedAnimation<Color>(RMColors.primary),
          ),
        ),
      ],
    );
  }

  // ── Dialogs ────────────────────────────────────────────────────────────────

  void _showEditProfile(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: RMColors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => _EditProfileSheet(onSaved: _load),
    );
  }

  void _showNotificationSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: RMColors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => _NotificationSettingsSheet(),
    );
  }

  void _showPrivacySettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: RMColors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => _PrivacySettingsSheet(),
    );
  }

  void _confirmSignOut(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: RMColors.surface,
        title: Text('Sign out',
            style: TextStyle(color: RMColors.textPrimary)),
        content: Text('Are you sure you want to sign out?',
            style: TextStyle(color: RMColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel',
                style: TextStyle(color: RMColors.textSecondary)),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              final userId = SupabaseService.instance.currentUser?.id;
              if (userId != null) {
                await AccountManagerService.instance
                    .forgetAccount(userId, alsoSignOut: true);
              }
              // If another saved account took over as active, rebuild
              // fresh under it rather than trusting already-open
              // screens to notice the swap on their own. If none did
              // (no other accounts saved), AuthGate handles showing
              // the login screen on its own.
              if (context.mounted &&
                  SupabaseService.instance.currentUser != null) {
                relaunchToFreshHome(context);
              }
            },
            child: Text('Sign out'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteAccount(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: RMColors.surface,
        title: Text('Delete account',
            style: TextStyle(color: RMColors.danger)),
        content: Text(
          'This will permanently delete your account, all your drops, and all your data. This cannot be undone.',
          style: TextStyle(color: RMColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel',
                style: TextStyle(color: RMColors.textSecondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: RMColors.danger),
            onPressed: () async {
              Navigator.of(ctx).pop();
              final userId = SupabaseService.instance.currentUser?.id;
              try {
                await SupabaseService.instance.deleteAccount();
                if (userId != null) {
                  // deleteAccount() already signed out server-side;
                  // this just drops it from the local switcher list
                  // and, if another saved account remains, switches
                  // to it automatically.
                  await AccountManagerService.instance.forgetAccount(userId);
                }
                if (context.mounted &&
                    SupabaseService.instance.currentUser != null) {
                  relaunchToFreshHome(context);
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(e.toString())),
                  );
                }
              }
            },
            child: Text('Delete permanently'),
          ),
        ],
      ),
    );
  }
}

// ── Notification settings sheet ───────────────────────────────────────────────

class _EditProfileSheet extends StatefulWidget {
  final VoidCallback onSaved;

  const _EditProfileSheet({required this.onSaved});

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _info;

  final _usernameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _displayCtrl = TextEditingController();
  String _homeCity = '';

  String _originalUsername = '';
  String _originalEmail = '';
  String _originalDisplayName = '';
  String _originalHomeCity = '';

  static const _detailsKey = 'account_details';

  // Which of the pencil-toggled rows are currently showing their
  // editable TextField rather than the static value.
  final Set<String> _editing = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _emailCtrl.dispose();
    _displayCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Belt-and-suspenders, same as the Privacy sheet: if a previous
    // edit is still queued (e.g. the connectivity-change event was
    // missed while the app was backgrounded), try pushing it now
    // rather than waiting on the next network transition.
    ProfileFieldsSyncService.instance.flush();

    // Cache-first: show the last-known details immediately, no
    // spinner, works fully offline.
    final cached = await AppStorageService.instance.loadMap(_detailsKey);
    if (cached != null && mounted) {
      _applyDetails(cached);
      setState(() => _loading = false);
    }

    // A queued-but-not-yet-synced edit should win over whatever's
    // cached or comes back from the server next — otherwise reopening
    // this sheet while still offline would show the *old* value and
    // make it look like the earlier edit never took.
    final pending = await ProfileFieldsSyncService.instance.peekPending();
    if (pending != null && mounted) {
      _applyDetails(pending);
      setState(() {});
    }

    try {
      final details = await SupabaseService.instance.fetchAccountDetails();
      if (!mounted) return;
      // Re-check for a pending edit rather than trusting the copy
      // read above — it's possible a flush completed (or a new edit
      // was queued) during this same await.
      final stillPending = await ProfileFieldsSyncService.instance.peekPending();
      _applyDetails(details);
      if (stillPending != null) _applyDetails(stillPending);
      setState(() => _loading = false);
      await AppStorageService.instance.saveMap(_detailsKey, details);
    } catch (e) {
      // Offline (or a transient failure) — keep showing cached/pending
      // details instead of blocking on an error.
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  /// Populates the controllers/originals from a details map, without
  /// touching fields the map doesn't include — used both for the
  /// full server response and for a partial pending-edit overlay.
  void _applyDetails(Map<String, dynamic> details) {
    final username = details['username'] as String?;
    final displayName = details['display_name'] as String?;
    final homeCity = details['home_city'] as String?;
    final email = details['email'] as String?;
    if (username != null) {
      _originalUsername = username;
      _usernameCtrl.text = username;
    }
    if (displayName != null) {
      _originalDisplayName = displayName;
      _displayCtrl.text = displayName;
    }
    if (homeCity != null) {
      _originalHomeCity = homeCity;
      _homeCity = homeCity;
    }
    if (email != null) {
      _originalEmail = email;
      _emailCtrl.text = email;
    }
  }

  Future<void> _save() async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) return;

    final newUsername = _usernameCtrl.text.trim();
    final newDisplayName = _displayCtrl.text.trim();
    final newEmail = _emailCtrl.text.trim();

    setState(() { _saving = true; _error = null; _info = null; });

    final changed = <String, dynamic>{
      if (newUsername.isNotEmpty && newUsername != _originalUsername)
        'username': newUsername,
      if (newDisplayName.isNotEmpty && newDisplayName != _originalDisplayName)
        'display_name': newDisplayName,
      if (_homeCity.isNotEmpty && _homeCity != _originalHomeCity)
        'home_city': _homeCity,
    };
    final emailChanged = newEmail.isNotEmpty && newEmail != _originalEmail;

    try {
      if (changed.isNotEmpty) {
        // Persist locally right away — these fields should still
        // "stick" on this device even if the sync below can't reach
        // the server yet, same contract as the Privacy sheet.
        final cached =
            await AppStorageService.instance.loadMap(_detailsKey) ?? {};
        cached.addAll(changed);
        await AppStorageService.instance.saveMap(_detailsKey, cached);

        await ProfileFieldsSyncService.instance.queue(changed);
      }

      // Email is the one field that can't be queued offline — it has
      // to reach Supabase Auth now, since that's what actually sends
      // the confirmation link. Attempted after the rest so a change
      // to username/display name/home city still gets queued even if
      // this part fails outright.
      String? emailNotice;
      if (emailChanged) {
        await SupabaseService.instance.updateEmail(newEmail);
        emailNotice =
            'Check $newEmail to confirm your new email — it won\'t '
            'take effect until then.';
      }

      final synced = changed.isEmpty
          ? true
          : await _attemptSync();

      if (!mounted) return;
      widget.onSaved();
      Navigator.of(context).pop();
      if (emailNotice != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(emailNotice)));
      } else if (!synced) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                "Saved on this device — it'll sync automatically once you're back online.")));
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Profile updated.')));
      }
    } catch (e) {
      if (mounted) {
        // The email step is the only one left that can throw here
        // outright (a queued username/display-name/home-city edit is
        // never lost even if this whole block fails downstream of it)
        // — including offline, where updateEmail's own timeout (see
        // SupabaseService) makes sure this doesn't just hang.
        setState(() =>
            _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Returns true if the queued edit actually reached the server.
  Future<bool> _attemptSync() async {
    await ProfileFieldsSyncService.instance.flush();
    final stillPending = await ProfileFieldsSyncService.instance.peekPending();
    return stillPending == null || stillPending.isEmpty;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: _loading
          ? SizedBox(
              height: 160,
              child: Center(
                  child: CircularProgressIndicator(color: RMColors.primary)),
            )
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Edit profile',
                      style: TextStyle(
                          color: RMColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 18)),
                  SizedBox(height: 4),
                  Text('User details',
                      style: TextStyle(
                          color: RMColors.textSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          letterSpacing: 0.4)),
                  SizedBox(height: 12),
                  _buildDetailRow(
                    fieldKey: 'username',
                    label: 'Username',
                    controller: _usernameCtrl,
                    prefixText: '@',
                  ),
                  Divider(color: RMColors.border, height: 24),
                  _buildDetailRow(
                    fieldKey: 'displayName',
                    label: 'Display name',
                    controller: _displayCtrl,
                    trailing: EmojiSheetButton(
                      controller: _displayCtrl,
                      color: RMColors.textSecondary,
                      compact: true,
                    ),
                  ),
                  Divider(color: RMColors.border, height: 24),
                  _buildDetailRow(
                    fieldKey: 'email',
                    label: 'Email',
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                  ),
                  SizedBox(height: 20),
                  LocationAutocompleteField(
                    label: 'Home city',
                    initialValue:
                        _originalHomeCity.isEmpty ? null : _originalHomeCity,
                    onSelected: (v) => _homeCity = v,
                  ),
                  if (_error != null)
                    Padding(
                      padding: EdgeInsets.only(top: 14),
                      child: Text(_error!,
                          style: TextStyle(color: RMColors.danger, fontSize: 13)),
                    ),
                  SizedBox(height: 20),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : Text('Save changes'),
                  ),
                ],
              ),
            ),
    );
  }

  /// A "value + pencil" row that swaps to an editable [TextField] once
  /// its pencil is tapped — the app's own username/email/display-name
  /// weren't editable at all before this, so surfacing them read-only
  /// first (rather than as inputs the user has to clear and retype)
  /// keeps their current value visible until they actually mean to
  /// change it.
  Widget _buildDetailRow({
    required String fieldKey,
    required String label,
    required TextEditingController controller,
    String? prefixText,
    Widget? trailing,
    TextInputType? keyboardType,
  }) {
    final isEditing = _editing.contains(fieldKey);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: isEditing
              ? TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: keyboardType,
                  style: TextStyle(color: RMColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: label,
                    prefixText: prefixText,
                    suffixIcon: trailing,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                            color: RMColors.textSecondary, fontSize: 12)),
                    SizedBox(height: 3),
                    Text(
                      controller.text.isEmpty
                          ? '—'
                          : '${prefixText ?? ''}${controller.text}',
                      style: TextStyle(
                          color: RMColors.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 15),
                    ),
                  ],
                ),
        ),
        if (!isEditing)
          IconButton(
            icon: Icon(Icons.edit_outlined,
                size: 18, color: RMColors.textSecondary),
            tooltip: 'Edit $label',
            onPressed: () => setState(() => _editing.add(fieldKey)),
          ),
      ],
    );
  }
}

class _NotificationSettingsSheet extends StatefulWidget {
  _NotificationSettingsSheet();

  @override
  State<_NotificationSettingsSheet> createState() =>
      _NotificationSettingsSheetState();
}

class _NotificationSettingsSheetState
    extends State<_NotificationSettingsSheet> {
  bool _nearbyDrops = true;
  bool _reactions = true;
  bool _newFollowers = false;
  bool _comments = true;
  bool _redrops = true;
  bool _messages = true;
  bool _newsUpdates = false;
  bool _whatsNew = true;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Notifications',
              style: TextStyle(
                  color: RMColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 18)),
          SizedBox(height: 16),
          _SwitchRow(
            label: 'Nearby drops',
            sub: 'Alert when a drop is within range',
            value: _nearbyDrops,
            onChanged: (v) => setState(() => _nearbyDrops = v),
          ),
          _SwitchRow(
            label: 'Reactions',
            sub: 'When someone reacts to your drop',
            value: _reactions,
            onChanged: (v) => setState(() => _reactions = v),
          ),
          _SwitchRow(
            label: 'New followers',
            sub: 'When someone starts following you',
            value: _newFollowers,
            onChanged: (v) => setState(() => _newFollowers = v),
          ),
          _SwitchRow(
            label: 'Comments',
            sub: 'When someone comments on your drop',
            value: _comments,
            onChanged: (v) => setState(() => _comments = v),
          ),
          _SwitchRow(
            label: 'Redrops',
            sub: 'When someone redrops your drop',
            value: _redrops,
            onChanged: (v) => setState(() => _redrops = v),
          ),
          _SwitchRow(
            label: 'Chats',
            sub: 'New messages and updates in your chats',
            value: _messages,
            onChanged: (v) => setState(() => _messages = v),
          ),
          _SwitchRow(
            label: 'News & updates',
            sub: 'Breaking stories and updates picked for you',
            value: _newsUpdates,
            onChanged: (v) => setState(() => _newsUpdates = v),
          ),
          _SwitchRow(
            label: "What's new",
            sub: 'Latest Realm features and app updates',
            value: _whatsNew,
            onChanged: (v) => setState(() => _whatsNew = v),
          ),
          SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ── Privacy settings sheet ───────────────────────────────────────────────────

class _PrivacySettingsSheet extends StatefulWidget {
  _PrivacySettingsSheet();

  @override
  State<_PrivacySettingsSheet> createState() => _PrivacySettingsSheetState();
}

class _PrivacySettingsSheetState extends State<_PrivacySettingsSheet> {
  bool _showOnMap = true;
  bool _allowDiscovery = true;
  bool _showHomeCity = true;
  bool _showDisplayName = true;
  bool _showStats = true;
  bool _allowTagging = true;
  bool _loading = true;

  static const _settingsKey = 'privacy_settings';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) return;

    // Belt-and-suspenders: if a previous change is still queued
    // (e.g. the connectivity-change event was missed while the app
    // was backgrounded), try pushing it now that the sheet's open
    // again rather than waiting on the next network transition.
    PrivacySettingsSyncService.instance.flush();

    // Cache-first, same reasoning as profile stats: show the
    // last-known toggle state immediately rather than spinning while
    // offline, and never lose it to a disposable-cache clear.
    final cached = await AppStorageService.instance.loadMap(_settingsKey);
    if (cached != null && mounted) {
      setState(() {
        _allowDiscovery = cached['allow_discovery'] as bool? ?? true;
        _showHomeCity = cached['show_home_city'] as bool? ?? true;
        _showDisplayName = cached['show_display_name'] as bool? ?? true;
        _showStats = cached['show_stats'] as bool? ?? true;
        _showOnMap = cached['show_on_map'] as bool? ?? true;
        _allowTagging = cached['allow_tagging'] as bool? ?? true;
        _loading = false;
      });
    }

    try {
      final settings = await SupabaseService.instance.fetchPrivacySettings(user.id);
      if (!mounted) return;
      setState(() {
        if (settings != null) {
          _allowDiscovery = settings['allow_discovery'] as bool? ?? true;
          _showHomeCity = settings['show_home_city'] as bool? ?? true;
          _showDisplayName = settings['show_display_name'] as bool? ?? true;
          _showStats = settings['show_stats'] as bool? ?? true;
          _showOnMap = settings['show_on_map'] as bool? ?? true;
          _allowTagging = settings['allow_tagging'] as bool? ?? true;
        }
        _loading = false;
      });
      if (settings != null) {
        await AppStorageService.instance.saveMap(_settingsKey, settings);
      }
    } catch (_) {
      // Offline — keep showing whatever we loaded from storage above.
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  Future<void> _save({
    bool? allowDiscovery,
    bool? showHomeCity,
    bool? showDisplayName,
    bool? showStats,
    bool? showOnMap,
    bool? allowTagging,
  }) async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) return;

    final changed = <String, dynamic>{
      if (allowDiscovery != null) 'allow_discovery': allowDiscovery,
      if (showHomeCity != null) 'show_home_city': showHomeCity,
      if (showDisplayName != null) 'show_display_name': showDisplayName,
      if (showStats != null) 'show_stats': showStats,
      if (showOnMap != null) 'show_on_map': showOnMap,
      if (allowTagging != null) 'allow_tagging': allowTagging,
    };
    if (changed.isEmpty) return;

    // Persist the new value locally right away — a toggle flipped
    // while offline should still "stick" on this device rather than
    // silently reverting next time the sheet opens.
    await AppStorageService.instance.saveMap(_settingsKey, {
      'allow_discovery': allowDiscovery ?? _allowDiscovery,
      'show_home_city': showHomeCity ?? _showHomeCity,
      'show_display_name': showDisplayName ?? _showDisplayName,
      'show_stats': showStats ?? _showStats,
      'show_on_map': showOnMap ?? _showOnMap,
      'allow_tagging': allowTagging ?? _allowTagging,
    });

    // Queue it *before* attempting the push. If the push below
    // succeeds right away, flush() clears the queue immediately after
    // — but if we're offline, it's already durably queued and the
    // connectivity listener in PrivacySettingsSyncService will retry
    // it automatically the moment the device is back online, with no
    // further action needed here.
    await PrivacySettingsSyncService.instance.queue(changed);
    final synced = await _attemptSync();

    if (!synced && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              "Saved on this device — it'll sync automatically once you're back online.")));
    }
  }

  /// Returns true if the pending write actually reached the server.
  Future<bool> _attemptSync() async {
    await PrivacySettingsSyncService.instance.flush();
    final stillPending =
        await AppStorageService.instance.loadMap('privacy_settings_pending');
    return stillPending == null || stillPending.isEmpty;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Privacy',
              style: TextStyle(
                  color: RMColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 18)),
          SizedBox(height: 16),
          if (_loading)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                  child: CircularProgressIndicator(color: RMColors.primary)),
            )
          else ...[
            _SwitchRow(
              label: 'Show in feed',
              sub: 'Allow others to see your public drops nearby',
              value: _showOnMap,
              onChanged: (v) {
                setState(() => _showOnMap = v);
                _save(showOnMap: v);
              },
            ),
            _SwitchRow(
              label: 'Allow discovery',
              sub: 'Let other users find you by username search',
              value: _allowDiscovery,
              onChanged: (v) {
                setState(() => _allowDiscovery = v);
                _save(allowDiscovery: v);
              },
            ),
            _SwitchRow(
              label: 'Allow tagging',
              sub: 'Let others tag you with @username in comments and messages',
              value: _allowTagging,
              onChanged: (v) {
                setState(() => _allowTagging = v);
                _save(allowTagging: v);
              },
            ),
            Divider(color: RMColors.border, height: 24),
            Text('On your public profile',
                style: TextStyle(
                    color: RMColors.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 12)),
            SizedBox(height: 12),
            _SwitchRow(
              label: 'Display name',
              sub: 'Show your display name to visitors',
              value: _showDisplayName,
              onChanged: (v) {
                setState(() => _showDisplayName = v);
                _save(showDisplayName: v);
              },
            ),
            _SwitchRow(
              label: 'Home city',
              sub: 'Show your home city to visitors',
              value: _showHomeCity,
              onChanged: (v) {
                setState(() => _showHomeCity = v);
                _save(showHomeCity: v);
              },
            ),
            _SwitchRow(
              label: 'Drop stats',
              sub: 'Show your drops-made / drops-unlocked counts',
              value: _showStats,
              onChanged: (v) {
                setState(() => _showStats = v);
                _save(showStats: v);
              },
            ),
          ],
        ],
      ),
    );
  }
}

// ── Reusable widgets ──────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: RMColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: RMColors.border),
          ),
          child: Column(
            children: [
              Icon(icon, color: RMColors.primary, size: 22),
              SizedBox(height: 8),
              Text(value,
                  style: TextStyle(
                      color: RMColors.textPrimary,
                      fontSize: 26,
                      fontWeight: FontWeight.w800)),
              Text(label,
                  style: TextStyle(
                      color: RMColors.textSecondary, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge {
  final IconData icon;
  final String label;
  final Color color;

  _Badge(
      {required this.icon, required this.label, required this.color});
}

class _BadgeChip extends StatelessWidget {
  final _Badge badge;
  _BadgeChip({required this.badge});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: badge.color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: badge.color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(badge.icon, color: badge.color, size: 14),
          SizedBox(width: 6),
          Text(badge.label,
              style: TextStyle(
                  color: badge.color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  _SettingsTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? RMColors.danger : RMColors.textPrimary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: 8),
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: RMColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: destructive
                  ? RMColors.danger.withOpacity(0.3)
                  : RMColors.border),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            SizedBox(width: 14),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontWeight: FontWeight.w500)),
            ),
            Icon(Icons.chevron_right_rounded,
                color: destructive
                    ? RMColors.danger.withOpacity(0.5)
                    : RMColors.textHint,
                size: 18),
          ],
        ),
      ),
    );
  }
}

// ── Appearance (light/dark mode) ────────────────────────────────────────────

class _DataSaverSettingsTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: DataSaverService.instance,
      builder: (context, _) {
        final enabled = DataSaverService.instance.enabled;
        return Container(
          margin: EdgeInsets.only(bottom: 8),
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: RMColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: RMColors.border),
          ),
          child: Row(
            children: [
              Icon(
                enabled ? Icons.data_saver_on_rounded : Icons.data_saver_off_rounded,
                color: RMColors.textPrimary,
                size: 20,
              ),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Data saver',
                        style: TextStyle(
                            color: RMColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500)),
                    Text(
                      'Compress uploads, and load media blurred until '
                      'you choose to download it',
                      style: TextStyle(
                          color: RMColors.textSecondary, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Switch(
                value: enabled,
                onChanged: (v) => DataSaverService.instance.setEnabled(v),
                activeColor: RMColors.primary,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Dev Hub opt-in ───────────────────────────────────────────────────────

class _DevHubToggleTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AdvancedFeaturesService.instance,
      builder: (context, _) {
        final enabled = AdvancedFeaturesService.instance.devHubEnabled;
        return Container(
          margin: EdgeInsets.only(bottom: 8),
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: RMColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: RMColors.border),
          ),
          child: Row(
            children: [
              Icon(Icons.code_rounded, color: RMColors.textPrimary, size: 20),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Dev Hub',
                        style: TextStyle(
                            color: RMColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500)),
                    Text(
                      'Connect GitHub, browse and edit repos, commit from the app',
                      style: TextStyle(
                          color: RMColors.textSecondary, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Switch(
                value: enabled,
                onChanged: (v) =>
                    AdvancedFeaturesService.instance.setDevHubEnabled(v),
                activeColor: RMColors.primary,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The "Developer" header + its "Dev Hub" nav tile — both hidden
/// entirely unless [AdvancedFeaturesService.devHubEnabled] is on (see
/// [_DevHubToggleTile] under Additional features), so the whole
/// section just doesn't exist for anyone who hasn't opted in rather
/// than sitting there unused.
class _DeveloperSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AdvancedFeaturesService.instance,
      builder: (context, _) {
        if (!AdvancedFeaturesService.instance.devHubEnabled) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Developer',
                style: TextStyle(
                    color: RMColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15)),
            SizedBox(height: 12),
            _SettingsTile(
              icon: Icons.code_rounded,
              label: 'Dev Hub',
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DevHubScreen())),
            ),
            SizedBox(height: 28),
          ],
        );
      },
    );
  }
}

class _ThemeSettingsTile extends StatelessWidget {
  String _label(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'System';
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) {
        return GestureDetector(
          onTap: () => showModalBottomSheet(
            context: context,
            backgroundColor: RMColors.surface,
            shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.vertical(top: Radius.circular(24))),
            builder: (ctx) => _AppearanceSheet(),
          ),
          child: Container(
            margin: EdgeInsets.only(bottom: 8),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: RMColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: RMColors.border),
            ),
            child: Row(
              children: [
                Icon(
                  ThemeController.instance.isDark
                      ? Icons.dark_mode_outlined
                      : Icons.light_mode_outlined,
                  color: RMColors.textPrimary,
                  size: 20,
                ),
                SizedBox(width: 14),
                Expanded(
                  child: Text('Appearance',
                      style: TextStyle(
                          color: RMColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                ),
                Text(_label(ThemeController.instance.mode),
                    style: TextStyle(
                        color: RMColors.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded,
                    color: RMColors.textHint, size: 18),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AppearanceSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) {
        final current = ThemeController.instance.mode;
        return Padding(
          padding: EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Appearance',
                  style: TextStyle(
                      color: RMColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 18)),
              SizedBox(height: 4),
              Text('Choose how Reality Merge looks on this device.',
                  style: TextStyle(
                      color: RMColors.textSecondary, fontSize: 12)),
              SizedBox(height: 18),
              _AppearanceOption(
                icon: Icons.smartphone_rounded,
                label: 'System',
                sub: 'Match your device setting',
                selected: current == ThemeMode.system,
                onTap: () => ThemeController.instance.setMode(ThemeMode.system),
              ),
              _AppearanceOption(
                icon: Icons.light_mode_rounded,
                label: 'Light',
                sub: 'Bright, paper-white look',
                selected: current == ThemeMode.light,
                onTap: () => ThemeController.instance.setMode(ThemeMode.light),
              ),
              _AppearanceOption(
                icon: Icons.dark_mode_rounded,
                label: 'Dark',
                sub: 'Deep space — the original look',
                selected: current == ThemeMode.dark,
                onTap: () => ThemeController.instance.setMode(ThemeMode.dark),
              ),
              SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

class _AppearanceOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sub;
  final bool selected;
  final VoidCallback onTap;

  _AppearanceOption({
    required this.icon,
    required this.label,
    required this.sub,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: 10),
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? RMColors.primaryDim : RMColors.surfaceAlt,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? RMColors.primary : RMColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon,
                color: selected ? RMColors.primary : RMColors.textSecondary,
                size: 20),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label,
                      style: TextStyle(
                          color: selected
                              ? RMColors.primary
                              : RMColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  Text(sub,
                      style: TextStyle(
                          color: RMColors.textSecondary, fontSize: 11)),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle_rounded,
                  color: RMColors.primary, size: 20),
          ],
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String label;
  final String sub;
  final bool value;
  final ValueChanged<bool> onChanged;

  _SwitchRow({
    required this.label,
    required this.sub,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        color: RMColors.textPrimary,
                        fontWeight: FontWeight.w500,
                        fontSize: 14)),
                Text(sub,
                    style: TextStyle(
                        color: RMColors.textSecondary, fontSize: 12)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: RMColors.primary,
          ),
        ],
      ),
    );
  }
}
