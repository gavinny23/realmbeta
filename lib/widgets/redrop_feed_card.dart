import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/redrop_feed_item.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import 'blur_media.dart';
import 'presence_avatar.dart';

/// A redrop as it shows up at the top of the Drops tab — same rounded
/// surface/border as [DropCard]/[NewsCard] so it doesn't feel like a
/// bolted-on third card style. The requote (if there is one) sits
/// above the nested article snippet, same visual order as a
/// quote-repost anywhere else: your words first, the thing you're
/// reacting to underneath.
///
/// All three actions here — like, redrop, comment — act on the
/// *original story*, not this specific redrop row: liking/commenting
/// updates the same counts a [NewsCard] for that story would show
/// back in Updates, and redropping again just opens the same
/// [NewsRedropSheet] (which already knows how to turn into "update
/// your redrop" if this is the person's own).
class RedropFeedCard extends StatefulWidget {
  final RedropFeedItem item;
  final ValueChanged<RedropFeedItem> onOpenDetail;
  final ValueChanged<RedropFeedItem> onOpenComments;
  final ValueChanged<RedropFeedItem> onOpenRedropSheet;

  const RedropFeedCard({
    super.key,
    required this.item,
    required this.onOpenDetail,
    required this.onOpenComments,
    required this.onOpenRedropSheet,
  });

  @override
  State<RedropFeedCard> createState() => _RedropFeedCardState();
}

class _RedropFeedCardState extends State<RedropFeedCard> {
  late bool _liked = widget.item.isLiked;
  late int _likeCount = widget.item.likeCount;
  bool _liking = false;

  Future<void> _toggleLike() async {
    if (_liking) return;
    // Optimistic — the whole point of a like button is that it feels
    // instant; a failed toggle just quietly reverts.
    final wasLiked = _liked;
    setState(() {
      _liking = true;
      _liked = !wasLiked;
      _likeCount += _liked ? 1 : -1;
    });
    try {
      final nowLiked = await SupabaseService.instance.toggleNewsLike(
        articleLink: widget.item.articleLink,
        articleTitle: widget.item.articleTitle,
      );
      if (mounted && nowLiked != _liked) {
        setState(() {
          _liked = nowLiked;
          _likeCount += _liked ? 1 : -1;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _liked = wasLiked;
          _likeCount += wasLiked ? 1 : -1;
        });
      }
    } finally {
      if (mounted) setState(() => _liking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Container(
      decoration: BoxDecoration(
        color: RMColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: RMColors.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Redropper byline ─────────────────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(14, 14, 14, 8),
            child: Row(
              children: [
                PresenceAvatar(
                  radius: 14,
                  avatarUrl: item.redropperAvatarUrl,
                  lastActiveAt: item.redropperLastActiveAt,
                  badgeBorderColor: RMColors.surface,
                  placeholder: Icon(Icons.person_rounded,
                      size: 16, color: RMColors.textSecondary),
                ),
                SizedBox(width: 8),
                Icon(Icons.repeat_rounded, size: 14, color: RMColors.primary),
                SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '@${item.redropperUsername} redropped',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: RMColors.textSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(item.timeAgoLabel,
                    style: TextStyle(color: RMColors.textHint, fontSize: 12)),
              ],
            ),
          ),

          // ── Requote — sits above the original story, not below ──
          if (item.quote != null && item.quote!.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Text(
                item.quote!,
                style: TextStyle(
                  color: RMColors.textPrimary,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ),

          // ── Nested original-story card ───────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: GestureDetector(
              onTap: () => widget.onOpenDetail(item),
              child: Container(
                decoration: BoxDecoration(
                  color: RMColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: RMColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (item.articleImageUrl != null)
                      ClipRRect(
                        borderRadius:
                            BorderRadius.vertical(top: Radius.circular(14)),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: DataSaverMediaGate(
                            mediaKey: item.articleImageUrl!,
                            previewUrl: item.articleImageUrl!,
                            borderRadius: BorderRadius.zero,
                            builder: (context) => CachedNetworkImage(
                              imageUrl: item.articleImageUrl!,
                              fit: BoxFit.cover,
                              placeholder: (_, __) =>
                                  Container(color: RMColors.border),
                              errorWidget: (_, __, ___) =>
                                  Container(color: RMColors.border),
                            ),
                          ),
                        ),
                      ),
                    Padding(
                      padding: EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (item.articleSourceName != null)
                            Text(
                              item.articleSourceName!,
                              style: TextStyle(
                                color: RMColors.accent,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.3,
                              ),
                            ),
                          SizedBox(height: 4),
                          Text(
                            item.articleTitle,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: RMColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          Divider(height: 1, color: RMColors.border),

          // ── Actions: like/redrop the original, comment on it ──
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: _toggleLike,
                    style: TextButton.styleFrom(
                        padding: EdgeInsets.symmetric(horizontal: 8)),
                    icon: Icon(
                      _liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                      size: 16,
                      color: _liked ? RMColors.danger : RMColors.textSecondary,
                    ),
                    label: Text(
                      _likeCount == 0 ? 'Like' : '$_likeCount',
                      style: TextStyle(
                        color: _liked ? RMColors.danger : RMColors.textSecondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    onPressed: () => widget.onOpenRedropSheet(item),
                    style: TextButton.styleFrom(
                        padding: EdgeInsets.symmetric(horizontal: 8)),
                    icon: Icon(Icons.repeat_rounded,
                        size: 16, color: RMColors.textSecondary),
                    label: Text(
                      item.redropCount == 0 ? 'Redrop' : '${item.redropCount}',
                      style: TextStyle(
                        color: RMColors.textSecondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    onPressed: () => widget.onOpenComments(item),
                    style: TextButton.styleFrom(
                        padding: EdgeInsets.symmetric(horizontal: 8)),
                    icon: Icon(Icons.mode_comment_outlined,
                        size: 16, color: RMColors.textSecondary),
                    label: Text(
                      item.commentCount == 0 ? 'Comment' : '${item.commentCount}',
                      style: TextStyle(
                        color: RMColors.textSecondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
