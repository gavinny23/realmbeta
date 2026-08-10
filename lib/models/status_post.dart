/// A single disappearing status post — a photo or short video that's
/// only ever visible for [StatusPost.lifespan] after it's posted. The
/// real enforcement of that lives server-side (see the generated
/// `expires_at` column and its RLS policy in v11-migration.sql) — this
/// class only mirrors the same window client-side so the countdown
/// label can update live without a network round-trip every second.
class StatusPost {
  static const lifespan = Duration(hours: 12);

  final String id;
  final String creatorId;
  final String creatorUsername;
  final String? creatorAvatarUrl;
  final String mediaUrl;
  final String mediaType; // 'photo' or 'video'
  final String? caption;
  final int viewCount;
  final bool isViewedByMe;
  final DateTime createdAt;
  final DateTime? creatorLastActiveAt;

  StatusPost({
    required this.id,
    required this.creatorId,
    required this.creatorUsername,
    this.creatorAvatarUrl,
    required this.mediaUrl,
    required this.mediaType,
    this.caption,
    required this.viewCount,
    required this.isViewedByMe,
    required this.createdAt,
    this.creatorLastActiveAt,
  });

  factory StatusPost.fromMap(Map<String, dynamic> map) {
    return StatusPost(
      id: map['id'] as String,
      creatorId: map['creator_id'] as String,
      creatorUsername: map['creator_username'] as String? ?? 'unknown',
      creatorAvatarUrl: map['creator_avatar_url'] as String?,
      mediaUrl: map['media_url'] as String,
      mediaType: map['media_type'] as String? ?? 'photo',
      caption: map['caption'] as String?,
      viewCount: (map['view_count'] as num?)?.toInt() ?? 0,
      isViewedByMe: map['is_viewed_by_me'] as bool? ?? false,
      createdAt: DateTime.parse(map['created_at'] as String),
      creatorLastActiveAt:
          DateTime.tryParse(map['creator_last_active_at'] as String? ?? ''),
    );
  }

  DateTime get expiresAt => createdAt.add(lifespan);

  /// How much longer this status has before it disappears. Never goes
  /// negative — a status sitting on screen right as it expires (e.g.
  /// mid-view) just reads as "0 left" rather than a negative duration,
  /// and in practice the server stops returning it at that point anyway.
  Duration get timeRemaining {
    final remaining = expiresAt.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool get isExpired => timeRemaining == Duration.zero;

  /// "8 hours left" / "1 hour left" / "45 minutes left" / "Expiring now".
  /// Rounds down (an 8h29m-old status still reads "3h left", not "4h
  /// left") so the label never overpromises how long is actually left.
  String get remainingLabel {
    final remaining = timeRemaining;
    if (remaining == Duration.zero) return 'Expiring now';

    final hours = remaining.inHours;
    if (hours >= 1) return '$hours ${hours == 1 ? 'hour' : 'hours'} left';

    final minutes = remaining.inMinutes;
    if (minutes >= 1) {
      return '$minutes ${minutes == 1 ? 'minute' : 'minutes'} left';
    }

    return 'Expiring now';
  }
}

/// One row in the horizontal status strip — a creator who currently
/// has at least one active status, rolled up with whether *all* of
/// their active statuses have already been viewed by the current user
/// (drives the filled-vs-dim ring, same convention as IG/WhatsApp).
class StatusFeedEntry {
  final String creatorId;
  final String creatorUsername;
  final String? creatorAvatarUrl;
  final int statusCount;
  final bool allViewed;
  final DateTime latestCreatedAt;
  final DateTime? creatorLastActiveAt;

  StatusFeedEntry({
    required this.creatorId,
    required this.creatorUsername,
    this.creatorAvatarUrl,
    required this.statusCount,
    required this.allViewed,
    required this.latestCreatedAt,
    this.creatorLastActiveAt,
  });

  factory StatusFeedEntry.fromMap(Map<String, dynamic> map) {
    return StatusFeedEntry(
      creatorId: map['creator_id'] as String,
      creatorUsername: map['creator_username'] as String? ?? 'unknown',
      creatorAvatarUrl: map['creator_avatar_url'] as String?,
      statusCount: (map['status_count'] as num?)?.toInt() ?? 0,
      allViewed: map['all_viewed'] as bool? ?? false,
      latestCreatedAt: DateTime.parse(map['latest_created_at'] as String),
      creatorLastActiveAt:
          DateTime.tryParse(map['creator_last_active_at'] as String? ?? ''),
    );
  }

  /// "3h ago" / "2d ago", matching [RedropFeedItem.timeAgoLabel] and
  /// [NewsArticle.timeAgoLabel]'s tone elsewhere in the app.
  String get timeAgoLabel {
    final diff = DateTime.now().difference(latestCreatedAt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  /// Mirrors [fromMap]'s field names for local caching, same
  /// convention as [Flick.toMap] / [Drop.toMap].
  Map<String, dynamic> toMap() => {
        'creator_id': creatorId,
        'creator_username': creatorUsername,
        'creator_avatar_url': creatorAvatarUrl,
        'status_count': statusCount,
        'all_viewed': allViewed,
        'latest_created_at': latestCreatedAt.toIso8601String(),
        'creator_last_active_at': creatorLastActiveAt?.toIso8601String(),
      };
}
