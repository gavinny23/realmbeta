/// A single short (<=30s) vertical video in the Flicks feed. Unlike
/// [Drop], flicks aren't location-gated — they're a straight-up
/// swipeable video feed, closer to Reels/TikTok than to the rest of
/// the app's "walk there to unlock it" concept.
class Flick {
  final String id;
  final String creatorId;
  final String creatorUsername;
  final String? creatorAvatarUrl;
  final String? caption;
  final String videoUrl;
  final String? thumbUrl;
  final int durationSeconds;
  int likeCount;
  int commentCount;
  bool isLiked;
  final DateTime createdAt;
  final DateTime? creatorLastActiveAt;

  Flick({
    required this.id,
    required this.creatorId,
    required this.creatorUsername,
    this.creatorAvatarUrl,
    this.caption,
    required this.videoUrl,
    this.thumbUrl,
    required this.durationSeconds,
    required this.likeCount,
    required this.commentCount,
    required this.isLiked,
    required this.createdAt,
    this.creatorLastActiveAt,
  });

  factory Flick.fromMap(Map<String, dynamic> map) {
    return Flick(
      id: map['id'] as String,
      creatorId: map['creator_id'] as String,
      creatorUsername: map['creator_username'] as String? ?? 'unknown',
      creatorAvatarUrl: map['creator_avatar_url'] as String?,
      caption: map['caption'] as String?,
      videoUrl: map['video_url'] as String,
      thumbUrl: map['thumb_url'] as String?,
      durationSeconds: (map['duration_seconds'] as num).toInt(),
      likeCount: (map['like_count'] as num?)?.toInt() ?? 0,
      commentCount: (map['comment_count'] as num?)?.toInt() ?? 0,
      isLiked: map['is_liked'] as bool? ?? false,
      createdAt: DateTime.parse(map['created_at'] as String),
      creatorLastActiveAt:
          DateTime.tryParse(map['creator_last_active_at'] as String? ?? ''),
    );
  }

  /// Mirrors [Flick.fromMap]'s field names for local caching.
  Map<String, dynamic> toMap() => {
        'id': id,
        'creator_id': creatorId,
        'creator_username': creatorUsername,
        'creator_avatar_url': creatorAvatarUrl,
        'caption': caption,
        'video_url': videoUrl,
        'thumb_url': thumbUrl,
        'duration_seconds': durationSeconds,
        'like_count': likeCount,
        'comment_count': commentCount,
        'is_liked': isLiked,
        'created_at': createdAt.toIso8601String(),
      };
}

/// A comment (or, when [parentCommentId] is set, a reply to one) on a
/// flick. Top-level comments and replies share this same shape — the
/// UI treats them differently, but the model doesn't need to.
class FlickComment {
  final String id;
  final String userId;
  final String username;
  final String? avatarUrl;
  final String content;
  int likeCount;
  bool isLiked;
  final int replyCount;
  final DateTime createdAt;
  final DateTime? lastActiveAt;

  FlickComment({
    required this.id,
    required this.userId,
    required this.username,
    this.avatarUrl,
    required this.content,
    required this.likeCount,
    required this.isLiked,
    this.replyCount = 0,
    required this.createdAt,
    this.lastActiveAt,
  });

  factory FlickComment.fromMap(Map<String, dynamic> map) {
    return FlickComment(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      username: map['username'] as String? ?? 'unknown',
      avatarUrl: map['avatar_url'] as String?,
      content: map['content'] as String,
      likeCount: (map['like_count'] as num?)?.toInt() ?? 0,
      isLiked: map['is_liked'] as bool? ?? false,
      replyCount: (map['reply_count'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(map['created_at'] as String),
      lastActiveAt: DateTime.tryParse(map['last_active_at'] as String? ?? ''),
    );
  }
}
