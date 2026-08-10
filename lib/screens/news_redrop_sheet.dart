import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/news_article.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/emoji_input.dart';

/// What happened when the sheet closed — [UpdatesView] (or wherever
/// this was opened from) uses this to refresh the right count without
/// having to guess which action the person actually took.
enum RedropOutcome { redropped, sharedToStatus }

/// Bottom sheet for redropping a story — either as a lightweight
/// in-app repost (with an optional requote, [NewsCard]'s counterpart
/// to a retweet), or shared out to the person's own 12h status with
/// that same requote burned into the image.
///
/// The live preview at the top *is* what gets captured for the status
/// share — [_previewKey]'s [RenderRepaintBoundary] is rasterized
/// straight to PNG bytes, so what the person sees is exactly what
/// gets posted.
class NewsRedropSheet extends StatefulWidget {
  final NewsArticle article;
  const NewsRedropSheet({super.key, required this.article});

  @override
  State<NewsRedropSheet> createState() => _NewsRedropSheetState();
}

class _NewsRedropSheetState extends State<NewsRedropSheet> {
  final _quoteCtrl = TextEditingController();
  final _previewKey = GlobalKey();
  bool _busy = false;
  bool _alreadyRedropped = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadExisting();
    // precacheImage needs a valid BuildContext attached to the tree to
    // read MediaQuery (via createLocalImageConfiguration) — that's not
    // guaranteed yet in initState(), and it turns out didChangeDependencies
    // isn't a reliably safe substitute here either (this sheet is mounted
    // via showModalBottomSheet mid-route-transition, and that ordering
    // isn't as clean as it is for a normally-pushed screen). addPostFrameCallback
    // sidesteps the ambiguity entirely: it only runs once the whole first
    // frame — every initState, didChangeDependencies, build, layout, and
    // paint in it — has actually finished, so there's no lifecycle window
    // left for this to race.
    if (widget.article.imageUrl != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Warm the image cache so the preview (and anything captured
        // from it) never shows a blank frame while a network fetch is
        // still in flight.
        precacheImage(
            CachedNetworkImageProvider(widget.article.imageUrl!), context);
      });
    }
  }

  Future<void> _loadExisting() async {
    try {
      final existing =
          await SupabaseService.instance.fetchMyNewsRedrop(widget.article.link);
      if (existing != null && mounted) {
        setState(() {
          _alreadyRedropped = true;
          _quoteCtrl.text = existing['quote'] as String? ?? '';
        });
      }
    } catch (_) {
      // Not knowing whether they've already redropped just means the
      // button starts out reading "Redrop" instead of "Update redrop"
      // — harmless, and it'll upsert correctly either way.
    }
  }

  @override
  void dispose() {
    _quoteCtrl.dispose();
    super.dispose();
  }

  String? get _quote =>
      _quoteCtrl.text.trim().isEmpty ? null : _quoteCtrl.text.trim();

  Future<void> _redrop() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await SupabaseService.instance.addOrUpdateNewsRedrop(
        articleLink: widget.article.link,
        articleTitle: widget.article.title,
        articleImageUrl: widget.article.imageUrl,
        articleSourceName: widget.article.sourceName,
        quote: _quote,
      );
      if (mounted) Navigator.of(context).pop(RedropOutcome.redropped);
    } catch (e) {
      if (mounted) setState(() => _error = "Couldn't redrop that story.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareToStatus() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      // Let the frame the preview is currently showing actually
      // settle before capturing it — matters most right after
      // precacheImage resolves, when the boundary hasn't repainted
      // with the real image yet.
      await WidgetsBinding.instance.endOfFrame;
      final boundary = _previewKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) throw Exception('Preview not ready');

      final image = await boundary.toImage(pixelRatio: 2.5);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData!.buffer.asUint8List();

      await SupabaseService.instance.createStatus(
        mediaBytes: bytes,
        mediaType: 'photo',
        extension: 'png',
        caption: _quote,
      );

      if (mounted) Navigator.of(context).pop(RedropOutcome.sharedToStatus);
    } catch (e) {
      if (mounted) {
        setState(() => _error = "Couldn't share that to your status.");
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final article = widget.article;
    return DraggableScrollableSheet(
      initialChildSize: 0.82,
      minChildSize: 0.55,
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
              Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Row(
                  children: [
                    Icon(Icons.repeat_rounded, color: RMColors.primary, size: 20),
                    SizedBox(width: 8),
                    Text(
                      _alreadyRedropped ? 'Update your redrop' : 'Redrop this story',
                      style: TextStyle(
                        color: RMColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    // ── Live preview — also the source for the status
                    // capture, so it's built at status proportions.
                    Center(
                      child: AspectRatio(
                        aspectRatio: 9 / 16,
                        child: RepaintBoundary(
                          key: _previewKey,
                          child: _RedropPreview(
                            article: article,
                            quote: _quote,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: 16),
                    TextField(
                      controller: _quoteCtrl,
                      maxLength: 280,
                      maxLines: 3,
                      onChanged: (_) => setState(() {}),
                      style: TextStyle(color: RMColors.textPrimary),
                      decoration: InputDecoration(
                        hintText: 'Add your take (optional)…',
                        hintStyle: TextStyle(color: RMColors.textHint),
                        filled: true,
                        fillColor: RMColors.surfaceAlt,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        suffixIcon: EmojiSheetButton(controller: _quoteCtrl),
                      ),
                    ),
                    if (_error != null)
                      Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(_error!,
                            style: TextStyle(color: RMColors.danger, fontSize: 13)),
                      ),
                    SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _busy ? null : _redrop,
                      icon: _busy
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : Icon(Icons.repeat_rounded, size: 18),
                      label: Text(_alreadyRedropped
                          ? 'Update redrop'
                          : 'Redrop to Realm'),
                    ),
                    SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _shareToStatus,
                      icon: Icon(Icons.auto_awesome_motion_outlined, size: 18),
                      label: Text('Share to your status'),
                    ),
                    SizedBox(height: 4),
                    Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'Redropping keeps the story on Realm with a comment '
                        'count of its own. Sharing to status posts it as a '
                        'photo that disappears after 12 hours.',
                        style: TextStyle(color: RMColors.textHint, fontSize: 11.5),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The actual card that gets rasterized for a status share — a
/// vertical, story-shaped composition: the person's requote up top
/// (if they added one) sitting over the app's background gradient,
/// the original story rendered underneath as a smaller card so it's
/// unmistakably clear this is a repost, not their own words presented
/// as the headline.
class _RedropPreview extends StatelessWidget {
  final NewsArticle article;
  final String? quote;

  const _RedropPreview({required this.article, required this.quote});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [RMColors.background, RMColors.primaryDim],
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  Icon(Icons.repeat_rounded, size: 15, color: Colors.white70),
                  SizedBox(width: 6),
                  Text('Redropped',
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              if (quote != null && quote!.isNotEmpty) ...[
                SizedBox(height: 14),
                Text(
                  quote!,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
              ],
              SizedBox(height: 18),
              // ── Nested mini article card ─────────────────────────
              Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white24, width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (article.imageUrl != null)
                      ClipRRect(
                        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: CachedNetworkImage(
                            imageUrl: article.imageUrl!,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(color: Colors.white10),
                            errorWidget: (_, __, ___) =>
                                Container(color: Colors.white10),
                          ),
                        ),
                      )
                    else if (article.generatedImageBytes != null)
                      ClipRRect(
                        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Image.memory(article.generatedImageBytes!,
                              fit: BoxFit.cover),
                        ),
                      ),
                    Padding(
                      padding: EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            article.sourceName,
                            style: TextStyle(
                                color: RMColors.accent,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.3),
                          ),
                          SizedBox(height: 4),
                          Text(
                            article.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                height: 1.25),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset('assets/branding/realm_icon_mark.png',
                      height: 16,
                      errorBuilder: (_, __, ___) => SizedBox.shrink()),
                  SizedBox(width: 6),
                  Text('via Realm',
                      style: TextStyle(color: Colors.white54, fontSize: 11)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
