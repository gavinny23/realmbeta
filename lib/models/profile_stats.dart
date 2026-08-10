class ProfileStats {
  final String userId;
  final String username;
  final String? avatarUrl;
  final int dropsCreated;
  final int dropsUnlocked;
  final int followerCount;

  /// Soft, informational marker from Sightengine's "genai" model,
  /// set by the check-ai-image Edge Function shortly after upload —
  /// never blocks the avatar itself, see v28-migration.sql for why.
  /// Null until the background check has run at least once.
  final double? avatarAiScore;
  final bool avatarAiFlagged;

  ProfileStats({
    required this.userId,
    required this.username,
    this.avatarUrl,
    required this.dropsCreated,
    required this.dropsUnlocked,
    this.followerCount = 0,
    this.avatarAiScore,
    this.avatarAiFlagged = false,
  });

  factory ProfileStats.fromMap(Map<String, dynamic> map) {
    return ProfileStats(
      userId: map['user_id'] as String,
      username: map['username'] as String,
      avatarUrl: map['avatar_url'] as String?,
      dropsCreated: (map['drops_created'] as num).toInt(),
      dropsUnlocked: (map['drops_unlocked'] as num).toInt(),
      followerCount: (map['follower_count'] as num?)?.toInt() ?? 0,
      avatarAiScore: (map['avatar_ai_score'] as num?)?.toDouble(),
      avatarAiFlagged: map['avatar_ai_flagged'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
        'user_id': userId,
        'username': username,
        'avatar_url': avatarUrl,
        'drops_created': dropsCreated,
        'drops_unlocked': dropsUnlocked,
        'follower_count': followerCount,
        'avatar_ai_score': avatarAiScore,
        'avatar_ai_flagged': avatarAiFlagged,
      };
}
