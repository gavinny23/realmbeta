import 'news_article.dart';

/// One entry in the redrop feed at the top of the Drops tab (see
/// [SupabaseService.fetchRedropFeed] / v18-migration.sql's
/// `fetch_redrop_feed`). Unlike a plain [NewsArticle] card in the
/// Updates tab, this carries a snapshot of the article as it looked
/// at redrop time — the live RSS list a story came from won't still
/// have it days later, so the redrop row itself has to be
/// self-contained.
class RedropFeedItem {
  final String id;
  final String userId;
  final String redropperUsername;
  final String? redropperAvatarUrl;
  final String articleLink;
  final String articleTitle;
  final String? articleImageUrl;
  final String? articleSourceName;
  final String? quote;
  final int likeCount;
  final bool isLiked;
  final int redropCount;
  final int commentCount;
  final DateTime createdAt;
  final DateTime? redropperLastActiveAt;

  const RedropFeedItem({
    required this.id,
    required this.userId,
    required this.redropperUsername,
    this.redropperAvatarUrl,
    required this.articleLink,
    required this.articleTitle,
    this.articleImageUrl,
    this.articleSourceName,
    this.quote,
    required this.likeCount,
    required this.isLiked,
    required this.redropCount,
    required this.commentCount,
    required this.createdAt,
    this.redropperLastActiveAt,
  });

  factory RedropFeedItem.fromMap(Map<String, dynamic> map) {
    return RedropFeedItem(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      redropperUsername: map['redropper_username'] as String? ?? 'unknown',
      redropperAvatarUrl: map['redropper_avatar_url'] as String?,
      articleLink: map['article_link'] as String,
      articleTitle: map['article_title'] as String? ?? '',
      articleImageUrl: map['article_image_url'] as String?,
      articleSourceName: map['article_source_name'] as String?,
      quote: map['quote'] as String?,
      likeCount: (map['like_count'] as num?)?.toInt() ?? 0,
      isLiked: map['is_liked'] as bool? ?? false,
      redropCount: (map['redrop_count'] as num?)?.toInt() ?? 0,
      commentCount: (map['comment_count'] as num?)?.toInt() ?? 0,
      createdAt:
          DateTime.tryParse(map['created_at'] as String? ?? '') ??
              DateTime.now(),
      redropperLastActiveAt: map['redropper_last_active_at'] != null
          ? DateTime.tryParse(map['redropper_last_active_at'] as String)
          : null,
    );
  }

  /// Reconstructs a thin [NewsArticle] stub from the snapshot, good
  /// enough to hand to [NewsDetailScreen], [NewsCommentsSheet], and
  /// [NewsRedropSheet] — all three only ever key their backend calls
  /// off `article.link`, never `article.id`, so a stub built purely
  /// from this snapshot works exactly like the real thing there.
  /// [tier] defaults to Kenya since it isn't stored on the redrop row
  /// and nothing this stub is used for actually sorts or filters by
  /// it.
  NewsArticle toArticleStub() => NewsArticle(
        id: articleLink,
        title: articleTitle,
        link: articleLink,
        imageUrl: articleImageUrl,
        sourceName: articleSourceName ?? 'Unknown source',
        tier: NewsTier.kenya,
        publishedAt: createdAt,
      );

  /// "3h ago" / "2d ago", matching [NewsArticle.timeAgoLabel] and
  /// [Drop.distanceLabel]'s tone elsewhere in the app.
  String get timeAgoLabel {
    final diff = DateTime.now().difference(createdAt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${(diff.inDays / 7).floor()}w ago';
  }
}
