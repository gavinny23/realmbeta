/// The public-facing view of a profile — exactly what `get_public_profile`
/// returns, which already collapses any field the owner has marked
/// private to null (unless the viewer is the owner). Nothing here needs
/// a second round of client-side filtering; a null field simply means
/// "don't show this", whether that's because the owner hid it or
/// because it was never set.
class PublicProfile {
  final String userId;
  final String username;
  final String? displayName;
  final String? homeCity;
  final String? avatarUrl;
  final int? dropsCreated;
  final int? dropsUnlocked;
  final int followerCount;
  final int followingCount;
  final bool isFollowing;
  final bool isSelf;
  final DateTime? lastActiveAt;
  final bool isBlockedByMe;

  PublicProfile({
    required this.userId,
    required this.username,
    this.displayName,
    this.homeCity,
    this.avatarUrl,
    this.dropsCreated,
    this.dropsUnlocked,
    required this.followerCount,
    required this.followingCount,
    required this.isFollowing,
    required this.isSelf,
    this.lastActiveAt,
    this.isBlockedByMe = false,
  });

  factory PublicProfile.fromMap(Map<String, dynamic> map) {
    return PublicProfile(
      userId: map['user_id'] as String,
      username: map['username'] as String,
      displayName: map['display_name'] as String?,
      homeCity: map['home_city'] as String?,
      avatarUrl: map['avatar_url'] as String?,
      dropsCreated: (map['drops_created'] as num?)?.toInt(),
      dropsUnlocked: (map['drops_unlocked'] as num?)?.toInt(),
      followerCount: (map['follower_count'] as num?)?.toInt() ?? 0,
      followingCount: (map['following_count'] as num?)?.toInt() ?? 0,
      isFollowing: map['is_following'] as bool? ?? false,
      isSelf: map['is_self'] as bool? ?? false,
      lastActiveAt: DateTime.tryParse(map['last_active_at'] as String? ?? ''),
      isBlockedByMe: map['is_blocked_by_me'] as bool? ?? false,
    );
  }
}
