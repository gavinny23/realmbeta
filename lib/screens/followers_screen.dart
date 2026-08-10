import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/presence_avatar.dart';
import 'user_profile_screen.dart';

/// The current user's followers list, reached by tapping the
/// "Followers" stat card on their own profile. Read-only — this isn't
/// the mutual-follow "Friends" list used to start a chat (see
/// SupabaseService.fetchMutualFollows), it's everyone following you,
/// whether or not you follow them back.
class FollowersScreen extends StatefulWidget {
  const FollowersScreen({super.key});

  @override
  State<FollowersScreen> createState() => _FollowersScreenState();
}

class _FollowersScreenState extends State<FollowersScreen> {
  List<Map<String, dynamic>> _followers = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final followers = await SupabaseService.instance.fetchFollowers();
      if (mounted) setState(() => _followers = followers);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        title: Text('Followers'),
        backgroundColor: RMColors.background,
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
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: RMColors.textSecondary)),
              ),
            ),
          ),
        ),
      );
    }
    if (_followers.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.people_outline_rounded,
                      color: RMColors.textHint, size: 48),
                  SizedBox(height: 12),
                  Text('No followers yet.',
                      style: TextStyle(
                          color: RMColors.textPrimary,
                          fontWeight: FontWeight.w600)),
                  SizedBox(height: 4),
                  Text('When someone follows you, they\'ll show up here.',
                      style: TextStyle(color: RMColors.textSecondary)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return ListView.separated(
      physics: AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _followers.length,
      separatorBuilder: (_, __) => SizedBox(height: 8),
      itemBuilder: (context, i) {
        final f = _followers[i];
        final username = f['username'] as String? ?? 'unknown';
        final displayName = f['display_name'] as String?;
        final avatarUrl = f['avatar_url'] as String?;
        final lastActiveAt =
            DateTime.tryParse(f['last_active_at'] as String? ?? '');
        final userId = f['id'] as String;

        return Material(
          color: RMColors.surface,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => UserProfileScreen(
                  userId: userId,
                  username: username,
                ),
              ),
            ),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: RMColors.border),
              ),
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  PresenceAvatar(
                    radius: 22,
                    backgroundColor: RMColors.primaryDim,
                    avatarUrl: avatarUrl,
                    lastActiveAt: lastActiveAt,
                    placeholder: Icon(Icons.person_rounded, color: RMColors.primary),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('@$username',
                            style: TextStyle(
                                color: RMColors.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 14)),
                        if (displayName != null && displayName.isNotEmpty) ...[
                          SizedBox(height: 2),
                          Text(displayName,
                              style: TextStyle(
                                  color: RMColors.textSecondary,
                                  fontSize: 12)),
                        ],
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: RMColors.textHint),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
