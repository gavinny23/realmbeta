/// Where the caller stands relative to every other profile, by
/// followers and by engagement (likes + comments received across
/// their drops). Returned by the `get_profile_rank` RPC — see
/// supabase/v21-migration.sql.
class ProfileRank {
  final int followerCount;
  final int followerRank;
  final int engagementCount;
  final int engagementRank;
  final int totalProfiles;

  ProfileRank({
    required this.followerCount,
    required this.followerRank,
    required this.engagementCount,
    required this.engagementRank,
    required this.totalProfiles,
  });

  /// 1 = you're ahead of (almost) everyone; 100 = you're behind
  /// (almost) everyone. Whole percent, rounded up so "rank 1 of 1"
  /// still reads as top 1% rather than top 0%.
  int get followerPercentile =>
      totalProfiles == 0 ? 100 : ((followerRank / totalProfiles) * 100).ceil();

  int get engagementPercentile => totalProfiles == 0
      ? 100
      : ((engagementRank / totalProfiles) * 100).ceil();

  factory ProfileRank.fromMap(Map<String, dynamic> map) {
    return ProfileRank(
      followerCount: (map['follower_count'] as num?)?.toInt() ?? 0,
      followerRank: (map['follower_rank'] as num?)?.toInt() ?? 1,
      engagementCount: (map['engagement_count'] as num?)?.toInt() ?? 0,
      engagementRank: (map['engagement_rank'] as num?)?.toInt() ?? 1,
      totalProfiles: (map['total_profiles'] as num?)?.toInt() ?? 1,
    );
  }
}
