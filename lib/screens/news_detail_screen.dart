import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/news_article.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/emoji_input.dart';
import '../widgets/blur_media.dart';
import '../widgets/presence_avatar.dart';
import 'news_redrop_sheet.dart';

/// Full-page view of a single story: the headline and summary up top,
/// an engagement row (redrops + comments), and the comment thread
/// underneath — opened by tapping a [NewsCard] instead of jumping
/// straight out to the publisher's site, so someone can see what
/// Realm's own community made of a story before (or without ever)
/// leaving the app.
class NewsDetailScreen extends StatefulWidget {
  final NewsArticle article;
  const NewsDetailScreen({super.key, required this.article});

  @override
  State<NewsDetailScreen> createState() => _NewsDetailScreenState();
}

class _NewsDetailScreenState extends State<NewsDetailScreen> {
  List<Map<String, dynamic>> _comments = [];
  int? _redropCount;
  bool _iRedropped = false;
  bool _loading = true;
  bool _posting = false;
  final _commentCtrl = TextEditingController();

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
      final results = await Future.wait([
        SupabaseService.instance.fetchNewsComments(widget.article.link),
        SupabaseService.instance.fetchNewsRedropCount(widget.article.link),
        SupabaseService.instance.fetchMyNewsRedrop(widget.article.link),
      ]);
      if (!mounted) return;
      setState(() {
        _comments = results[0] as List<Map<String, dynamic>>;
        _redropCount = results[1] as int;
        _iRedropped = (results[2] as Map<String, dynamic>?) != null;
      });
    } catch (_) {
      // A story is still worth reading even if engagement data can't
      // be pulled right now — the summary above still renders fine.
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
    } catch (_) {
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

  Future<void> _openRedropSheet() async {
    final outcome = await showModalBottomSheet<RedropOutcome>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => NewsRedropSheet(article: widget.article),
    );
    if (outcome == null || !mounted) return;
    if (outcome == RedropOutcome.sharedToStatus) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Shared to your status')));
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Redropped')));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final article = widget.article;
    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        backgroundColor: RMColors.background,
        title: Text('Story'),
        actions: [
          IconButton(
            icon: Icon(Icons.open_in_new_rounded),
            tooltip: 'View full story',
            onPressed: _openStory,
          ),
        ],
      ),
      body: RefreshIndicator(
        color: RMColors.primary,
        backgroundColor: RMColors.surface,
        onRefresh: _load,
        child: ListView(
          physics: AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(0, 0, 0, 90),
          children: [
            _buildHeader(article),
            _buildEngagementBar(),
            Divider(height: 1, color: RMColors.border),
            SizedBox(height: 8),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Comments',
                style: TextStyle(
                    color: RMColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15),
              ),
            ),
            if (_loading)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child:
                    Center(child: CircularProgressIndicator(color: RMColors.primary)),
              )
            else if (_comments.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                child: Text(
                  'No comments yet — be the first to weigh in.',
                  style: TextStyle(color: RMColors.textSecondary),
                ),
              )
            else
              ...List.generate(_comments.length, (index) {
                final c = _comments[index];
                final createdAt =
                    DateTime.tryParse(c['created_at'] as String? ?? '') ??
                        DateTime.now();
                return Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      PresenceAvatar(
                        radius: 16,
                        backgroundColor: RMColors.primaryDim,
                        avatarUrl: c['profiles']?['avatar_url'] as String?,
                        lastActiveAt: DateTime.tryParse(
                            c['profiles']?['last_active_at'] as String? ?? ''),
                        placeholder: Icon(Icons.person, size: 16, color: RMColors.primary),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  c['profiles']?['username'] as String? ?? 'unknown',
                                  style: TextStyle(
                                      color: RMColors.textPrimary,
                                      fontWeight: FontWeight.w600),
                                ),
                                SizedBox(width: 8),
                                Text(
                                  DateFormat('MMM d, h:mm a').format(createdAt),
                                  style:
                                      TextStyle(color: RMColors.textHint, fontSize: 12),
                                ),
                              ],
                            ),
                            SizedBox(height: 2),
                            Text(c['content'] as String? ?? '',
                                style: TextStyle(color: RMColors.textPrimary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _commentCtrl,
                  style: TextStyle(color: RMColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Add a comment...',
                    hintStyle: TextStyle(color: RMColors.textHint),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    suffixIcon: EmojiSheetButton(controller: _commentCtrl),
                  ),
                  onSubmitted: (_) => _postComment(),
                ),
              ),
              SizedBox(width: 8),
              IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: RMColors.primary),
                onPressed: _posting ? null : _postComment,
                icon: _posting
                    ? SizedBox(
                        height: 18,
                        width: 18,
                        child:
                            CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Icon(Icons.send, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(NewsArticle article) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                article.category != null
                    ? '${article.sourceName} · ${article.category}'
                    : article.sourceName,
                style: TextStyle(
                    color: RMColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
              SizedBox(width: 8),
              Text('·', style: TextStyle(color: RMColors.textHint)),
              SizedBox(width: 8),
              Text(article.timeAgoLabel,
                  style: TextStyle(color: RMColors.textHint, fontSize: 12)),
            ],
          ),
          SizedBox(height: 8),
          Text(
            article.title,
            style: TextStyle(
                color: RMColors.textPrimary,
                fontWeight: FontWeight.w800,
                fontSize: 20,
                height: 1.25),
          ),
          if (article.imageUrl != null) ...[
            SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: DataSaverMediaGate(
                  mediaKey: article.imageUrl!,
                  previewUrl: article.imageUrl!,
                  borderRadius: BorderRadius.zero,
                  builder: (context) => CachedNetworkImage(
                    imageUrl: article.imageUrl!,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(color: RMColors.surfaceAlt),
                    errorWidget: (_, __, ___) => Container(color: RMColors.surfaceAlt),
                  ),
                ),
              ),
            ),
            if (article.imageCredit != null)
              Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(article.imageCredit!,
                    style: TextStyle(color: RMColors.textHint, fontSize: 11)),
              ),
          ] else if (article.generatedImageBytes != null) ...[
            SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.memory(article.generatedImageBytes!, fit: BoxFit.cover),
              ),
            ),
          ],
          if (article.summary != null) ...[
            SizedBox(height: 14),
            Text(
              article.summary!,
              style: TextStyle(color: RMColors.textSecondary, fontSize: 14.5, height: 1.45),
            ),
          ],
          SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _openStory,
            icon: Icon(Icons.open_in_new_rounded, size: 16),
            label: Text('View full story on ${article.sourceName}'),
            style: OutlinedButton.styleFrom(
              foregroundColor: RMColors.primary,
              minimumSize: Size(0, 38),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEngagementBar() {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          _EngagementStat(
            icon: Icons.repeat_rounded,
            value: _redropCount,
            filled: _iRedropped,
          ),
          SizedBox(width: 20),
          _EngagementStat(
            icon: Icons.mode_comment_outlined,
            value: _comments.isEmpty && _loading ? null : _comments.length,
          ),
          Spacer(),
          TextButton.icon(
            onPressed: _openRedropSheet,
            icon: Icon(Icons.repeat_rounded,
                size: 17, color: _iRedropped ? RMColors.success : RMColors.primary),
            label: Text(
              _iRedropped ? 'Redropped' : 'Redrop',
              style: TextStyle(
                  color: _iRedropped ? RMColors.success : RMColors.primary,
                  fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _EngagementStat extends StatelessWidget {
  final IconData icon;
  final int? value;
  final bool filled;

  const _EngagementStat({required this.icon, this.value, this.filled = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: filled ? RMColors.success : RMColors.textSecondary),
        SizedBox(width: 5),
        Text(
          value == null ? '—' : '$value',
          style: TextStyle(
              color: filled ? RMColors.success : RMColors.textSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 13),
        ),
      ],
    );
  }
}
