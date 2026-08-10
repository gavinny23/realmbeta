import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/news_article.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/cheat_code_trigger.dart';
import '../widgets/emoji_input.dart';
import '../widgets/mention_composer_field.dart';
import '../widgets/presence_avatar.dart';

/// Real commenting on a syndicated news story — same visual language
/// as [ReactionsScreen]'s comment thread on a drop. Opened as a modal
/// bottom sheet from a [NewsCard] so it can be dismissed with a swipe
/// without losing the person's place in the Updates list.
class NewsCommentsSheet extends StatefulWidget {
  final NewsArticle article;
  const NewsCommentsSheet({super.key, required this.article});

  @override
  State<NewsCommentsSheet> createState() => _NewsCommentsSheetState();
}

class _NewsCommentsSheetState extends State<NewsCommentsSheet> {
  List<Map<String, dynamic>> _comments = [];
  bool _loading = true;
  bool _posting = false;
  final _commentCtrl = MentionTextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final comments = await SupabaseService.instance
          .fetchNewsComments(widget.article.link);
      if (mounted) setState(() => _comments = comments);
    } catch (_) {
      // Comments are secondary to the story itself — fail quietly and
      // just show an empty thread rather than blocking the sheet.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _postComment() async {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty || _posting) return;
    setState(() => _posting = true);
    try {
      await SupabaseService.instance.addNewsComment(
        articleLink: widget.article.link,
        articleTitle: widget.article.title,
        content: text,
      );
      _commentCtrl.clear();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not post comment')));
      }
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _openStory() async {
    final uri = Uri.tryParse(widget.article.link);
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: RMColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: RMColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // ── Story header ────────────────────────────────────
              Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.article.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: RMColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    SizedBox(height: 8),
                    Row(
                      children: [
                        Text(widget.article.sourceName,
                            style: TextStyle(
                                color: RMColors.textSecondary, fontSize: 12)),
                        Spacer(),
                        TextButton.icon(
                          onPressed: _openStory,
                          icon: Icon(Icons.open_in_new_rounded, size: 15),
                          label: Text('View full story'),
                          style: TextButton.styleFrom(
                              foregroundColor: RMColors.primary,
                              padding: EdgeInsets.symmetric(horizontal: 4)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: RMColors.border),

              // ── Comments ─────────────────────────────────────────
              Expanded(
                child: _loading
                    ? Center(
                        child: CircularProgressIndicator(
                            color: RMColors.primary))
                    : _comments.isEmpty
                        ? Center(
                            child: Text(
                              'No comments yet — be the first to weigh in.',
                              style:
                                  TextStyle(color: RMColors.textSecondary),
                            ),
                          )
                        : ListView.separated(
                            controller: scrollController,
                            padding: EdgeInsets.all(16),
                            itemCount: _comments.length,
                            separatorBuilder: (_, __) => SizedBox(height: 16),
                            itemBuilder: (context, index) {
                              final c = _comments[index];
                              final createdAt = DateTime.tryParse(
                                      c['created_at'] as String? ?? '') ??
                                  DateTime.now();
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  PresenceAvatar(
                                    radius: 16,
                                    backgroundColor: RMColors.primaryDim,
                                    avatarUrl:
                                        c['profiles']?['avatar_url'] as String?,
                                    lastActiveAt: DateTime.tryParse(
                                        c['profiles']?['last_active_at']
                                                as String? ??
                                            ''),
                                    placeholder: Icon(Icons.person,
                                        size: 16, color: RMColors.primary),
                                  ),
                                  SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              c['profiles']?['username']
                                                      as String? ??
                                                  'unknown',
                                              style: TextStyle(
                                                  color: RMColors.textPrimary,
                                                  fontWeight:
                                                      FontWeight.w600),
                                            ),
                                            SizedBox(width: 8),
                                            Text(
                                              DateFormat('MMM d, h:mm a')
                                                  .format(createdAt),
                                              style: TextStyle(
                                                  color: RMColors.textHint,
                                                  fontSize: 12),
                                            ),
                                          ],
                                        ),
                                        SizedBox(height: 2),
                                        Text(c['content'] as String? ?? '',
                                            style: TextStyle(
                                                color: RMColors.textPrimary)),
                                      ],
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
              ),

              // ── Comment input ────────────────────────────────────
              SafeArea(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: MentionComposerField(
                          controller: _commentCtrl,
                          style: TextStyle(color: RMColors.textPrimary),
                          onChanged: (v) => CheatCodeTrigger.watch(
                              context, _commentCtrl, v),
                          decoration: InputDecoration(
                            hintText: 'Add a comment... (@ to tag someone)',
                            hintStyle: TextStyle(color: RMColors.textHint),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12)),
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            suffixIcon:
                                EmojiSheetButton(controller: _commentCtrl),
                          ),
                          onSubmitted: (_) => _postComment(),
                        ),
                      ),
                      SizedBox(width: 8),
                      IconButton.filled(
                        style: IconButton.styleFrom(
                            backgroundColor: RMColors.primary),
                        onPressed: _posting ? null : _postComment,
                        icon: _posting
                            ? SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : Icon(Icons.send, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
