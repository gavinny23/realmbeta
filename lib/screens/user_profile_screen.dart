import 'package:flutter/material.dart';
import '../models/drop.dart';
import '../models/public_profile.dart';
import '../services/location_service.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/drop_card.dart';
import '../widgets/presence_avatar.dart';
import 'drop_detail_screen.dart';

/// Read-only view of someone else's profile, reached by searching their
/// username from the Explore feed. Shows only what that person has
/// chosen to make public — see [PublicProfile] — plus a follow button
/// and their full drop list (locked drops included, each showing its
/// distance) since the Explore feed itself only shows already-unlocked
/// drops. This is the intended way to find a specific locked drop: look
/// up who left it.
class UserProfileScreen extends StatefulWidget {
  final String userId;
  final String username;
  /// Passed down from the feed when already known, so this screen
  /// doesn't have to wait on a fresh GPS fix if one's already in hand.
  final double? currentLat;
  final double? currentLng;

  UserProfileScreen({
    super.key,
    required this.userId,
    required this.username,
    this.currentLat,
    this.currentLng,
  });

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  PublicProfile? _profile;
  List<Drop> _drops = [];
  double? _lat;
  double? _lng;
  bool _loading = true;
  bool _followBusy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _lat = widget.currentLat;
    _lng = widget.currentLng;
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      if (_lat == null || _lng == null) {
        final position = await LocationService.instance.getCurrentPosition();
        _lat = position.latitude;
        _lng = position.longitude;
      }
      final results = await Future.wait([
        SupabaseService.instance.fetchPublicProfile(widget.userId),
        SupabaseService.instance.fetchUserDrops(
          userId: widget.userId,
          lat: _lat!,
          lng: _lng!,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _profile = results[0] as PublicProfile?;
        _drops = results[1] as List<Drop>;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleFollow() async {
    final profile = _profile;
    if (profile == null || _followBusy) return;
    setState(() => _followBusy = true);
    try {
      final nowFollowing = await SupabaseService.instance.toggleFollow(profile.userId);
      if (!mounted) return;
      setState(() {
        _profile = PublicProfile(
          userId: profile.userId,
          username: profile.username,
          displayName: profile.displayName,
          homeCity: profile.homeCity,
          avatarUrl: profile.avatarUrl,
          dropsCreated: profile.dropsCreated,
          dropsUnlocked: profile.dropsUnlocked,
          followerCount: profile.followerCount + (nowFollowing ? 1 : -1),
          followingCount: profile.followingCount,
          isFollowing: nowFollowing,
          isSelf: profile.isSelf,
          isBlockedByMe: profile.isBlockedByMe,
        );
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  Future<void> _openDrop(Drop drop) async {
    if (_lat == null || _lng == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DropDetailScreen(
          drop: drop,
          currentLat: _lat!,
          currentLng: _lng!,
        ),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        backgroundColor: RMColors.background,
        title: Text('@${widget.username}'),
      ),
      body: RefreshIndicator(
        color: RMColors.primary,
        backgroundColor: RMColors.surface,
        onRefresh: _load,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: RMColors.primary));
    }
    if (_error != null) {
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: RMColors.textSecondary)),
                    SizedBox(height: 16),
                    OutlinedButton(onPressed: _load, child: Text('Try again')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final profile = _profile;

    return ListView(
      physics: AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(16, 16, 16, 100),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PresenceAvatar(
              radius: 32,
              backgroundColor: RMColors.primaryDim,
              avatarUrl: profile?.avatarUrl,
              lastActiveAt: profile?.lastActiveAt,
              placeholder:
                  Icon(Icons.person_rounded, color: RMColors.primary, size: 30),
            ),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Username + follow button, right next to each other ──
                  Row(
                    children: [
                      Flexible(
                        child: Text('@${widget.username}',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: RMColors.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 18)),
                      ),
                      if (profile != null && !profile.isSelf) ...[
                        SizedBox(width: 10),
                        _FollowButton(
                          isFollowing: profile.isFollowing,
                          busy: _followBusy,
                          onTap: _toggleFollow,
                        ),
                      ],
                    ],
                  ),
                  // Display name — omitted entirely if the owner has it
                  // set to private (and it's not their own profile).
                  if (profile?.displayName != null) ...[
                    SizedBox(height: 2),
                    Text(profile!.displayName!,
                        style: TextStyle(color: RMColors.textSecondary, fontSize: 13)),
                  ],
                  // Home city — same rule.
                  if (profile?.homeCity != null) ...[
                    SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.place_rounded, size: 13, color: RMColors.textHint),
                        SizedBox(width: 3),
                        Text(profile!.homeCity!,
                            style: TextStyle(color: RMColors.textHint, fontSize: 12)),
                      ],
                    ),
                  ],
                  SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _StatChip(
                          label: 'followers',
                          value: profile?.followerCount ?? 0),
                      _StatChip(
                          label: 'following',
                          value: profile?.followingCount ?? 0),
                      // Drop stats are only shown if the owner allows it
                      // (or this is their own profile) — see get_public_profile.
                      if (profile?.dropsCreated != null)
                        _StatChip(label: 'drops', value: profile!.dropsCreated!),
                      if (profile?.dropsUnlocked != null)
                        _StatChip(label: 'unlocked', value: profile!.dropsUnlocked!),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: 24),
        Text('Drops',
            style: TextStyle(
                color: RMColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 15)),
        SizedBox(height: 12),
        if (_drops.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('No drops from this user yet.',
                  style: TextStyle(color: RMColors.textSecondary)),
            ),
          )
        else
          ..._drops.map((drop) => Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: DropCard(drop: drop, onTap: () => _openDrop(drop)),
              )),
      ],
    );
  }
}

class _FollowButton extends StatelessWidget {
  final bool isFollowing;
  final bool busy;
  final VoidCallback onTap;

  const _FollowButton({
    required this.isFollowing,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: OutlinedButton(
        onPressed: busy ? null : onTap,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.symmetric(horizontal: 14),
          backgroundColor: isFollowing ? Colors.transparent : RMColors.primary,
          side: BorderSide(
              color: isFollowing ? RMColors.border : RMColors.primary),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: busy
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: isFollowing ? RMColors.textSecondary : Colors.white,
                ),
              )
            : Text(
                isFollowing ? 'Following' : 'Follow',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: isFollowing ? RMColors.textSecondary : Colors.white,
                ),
              ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final int value;

  const _StatChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: RMColors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: RMColors.border),
      ),
      child: Text(
        '$value $label',
        style: TextStyle(
            color: RMColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600),
      ),
    );
  }
}
