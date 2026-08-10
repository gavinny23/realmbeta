import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import '../models/flick.dart';
import '../services/supabase_service.dart';
import '../services/cached_media.dart';
import '../services/local_cache_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/emoji_input.dart';
import '../widgets/presence_avatar.dart';
import 'create_flick_screen.dart';

/// Instagram-Reels-style video feed — except pages swipe *left/right*
/// (horizontal) instead of the usual up/down, per product direction.
/// Each flick carries its own always-visible, expandable comment
/// carousel anchored near the bottom of the video (see
/// [_FlickCommentsCarousel]).
class FlicksScreen extends StatefulWidget {
  /// Whether the Flicks tab is the one currently selected in the bottom
  /// nav. FlicksScreen is kept alive inside HomeShell's IndexedStack even
  /// while a different tab is showing, so this is the only reliable
  /// signal for "should any video here actually be playing right now" —
  /// the feed's own internal page index isn't enough, since that stays
  /// put (and would read as "active") even while a completely different
  /// tab is on screen.
  final bool isActive;

  const FlicksScreen({super.key, this.isActive = true});

  @override
  State<FlicksScreen> createState() => FlicksScreenState();
}

class FlicksScreenState extends State<FlicksScreen> {
  static const _cacheKey = 'flicks_feed';

  final _pageCtrl = PageController();
  List<Flick> _flicks = [];
  int _currentIndex = 0;
  bool _loading = true;
  bool _offline = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  /// Called on first load and by [HomeShell] whenever this tab is
  /// (re)selected, same refresh contract as the other tabs.
  Future<void> refresh() => _load();

  Future<void> _load() async {
    // 1. Show whatever was cached from last time immediately — no
    // spinner, no network wait, and it works with zero connection.
    final cached = await LocalCacheService.instance.loadList(_cacheKey);
    final hadCache = cached != null && cached.isNotEmpty;
    if (hadCache && mounted) {
      setState(() {
        _flicks = cached.map(Flick.fromMap).toList();
        _loading = false;
      });
    }

    // 2. Refresh from the network in the background. Only replace
    // what's on screen if this actually succeeds — a failed refresh
    // (e.g. offline) just leaves the cached posts exactly as they were,
    // instead of showing an error where content used to be.
    if (!hadCache) setState(() { _loading = true; _error = null; });
    try {
      final flicks = await SupabaseService.instance.fetchFlicks();
      if (mounted) {
        setState(() {
          _flicks = flicks;
          _currentIndex = 0;
          _offline = false;
          _error = null;
        });
      }
      await LocalCacheService.instance
          .saveList(_cacheKey, flicks.map((f) => f.toMap()).toList());
    } catch (e) {
      if (mounted) {
        setState(() {
          if (hadCache) {
            _offline = true; // keep showing cached posts, just note it
          } else {
            _error = e.toString();
          }
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openCreate() async {
    final posted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const CreateFlickScreen()),
    );
    if (posted == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Stack(
          children: [
            if (_loading)
              Center(child: CircularProgressIndicator(color: RMColors.primary))
            else if (_error != null)
              Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70)),
                      SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: _load,
                        style: OutlinedButton.styleFrom(
                            side: BorderSide(color: Colors.white38)),
                        child: Text('Try again',
                            style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                ),
              )
            else if (_flicks.isEmpty)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.movie_creation_outlined,
                        color: Colors.white38, size: 48),
                    SizedBox(height: 12),
                    Text('No flicks yet.',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600)),
                    SizedBox(height: 4),
                    Text('Be the first to post one.',
                        style: TextStyle(color: Colors.white54)),
                  ],
                ),
              )
            else
              PageView.builder(
                controller: _pageCtrl,
                scrollDirection: Axis.horizontal,
                itemCount: _flicks.length,
                onPageChanged: (i) => setState(() => _currentIndex = i),
                itemBuilder: (context, i) => _FlickPage(
                  key: ValueKey(_flicks[i].id),
                  flick: _flicks[i],
                  isActive: widget.isActive && i == _currentIndex,
                ),
              ),
            Positioned(
              top: 12,
              left: 16,
              child: Text('Flicks',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      shadows: [Shadow(blurRadius: 8, color: Colors.black)])),
            ),
            Positioned(
              top: 8,
              right: 12,
              child: IconButton(
                icon: Icon(Icons.add_box_outlined, color: Colors.white, size: 28),
                onPressed: _openCreate,
              ),
            ),
            if (_offline && _flicks.isNotEmpty)
              Positioned(
                top: 44,
                left: 16,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_off_rounded, color: Colors.white70, size: 13),
                      SizedBox(width: 5),
                      Text('Offline — showing saved flicks',
                          style: TextStyle(color: Colors.white70, fontSize: 11)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One full-bleed video page: player + right-side like button + bottom
/// caption/creator row + the comments carousel.
class _FlickPage extends StatefulWidget {
  final Flick flick;
  final bool isActive;

  const _FlickPage({super.key, required this.flick, required this.isActive});

  @override
  State<_FlickPage> createState() => _FlickPageState();
}

class _FlickPageState extends State<_FlickPage> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _muted = false;
  late bool _liked;
  late int _likeCount;

  @override
  void initState() {
    super.initState();
    _liked = widget.flick.isLiked;
    _likeCount = widget.flick.likeCount;
    _initController();
  }

  Future<void> _initController() async {
    // Try to resolve (and, if needed, populate) a disk-cached copy of
    // this video first. A previously-watched flick then plays back
    // instantly and works with no connection at all; a brand-new one
    // just downloads once here and is cached for next time.
    final cachedFile = await CachedMedia.resolve(widget.flick.videoUrl);
    if (!mounted) return;
    final ctrl = cachedFile != null
        ? VideoPlayerController.file(cachedFile)
        : VideoPlayerController.networkUrl(Uri.parse(widget.flick.videoUrl));
    _controller = ctrl;
    await ctrl.initialize();
    ctrl.setLooping(true);
    if (!mounted) return;
    setState(() => _initialized = true);
    if (widget.isActive) ctrl.play();
  }

  @override
  void didUpdateWidget(covariant _FlickPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ctrl = _controller;
    if (ctrl == null || !_initialized) return;
    if (widget.isActive && !oldWidget.isActive) {
      ctrl.play();
    } else if (!widget.isActive && oldWidget.isActive) {
      ctrl.pause();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    final ctrl = _controller;
    if (ctrl == null) return;
    setState(() => ctrl.value.isPlaying ? ctrl.pause() : ctrl.play());
  }

  Future<void> _toggleLike() async {
    setState(() {
      _liked = !_liked;
      _likeCount += _liked ? 1 : -1;
    });
    try {
      await SupabaseService.instance.toggleFlickLike(widget.flick.id);
    } catch (_) {
      // Revert on failure.
      if (mounted) {
        setState(() {
          _liked = !_liked;
          _likeCount += _liked ? 1 : -1;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final flick = widget.flick;
    return GestureDetector(
      onTap: _togglePlayPause,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: Colors.black),
          if (_initialized && _controller != null)
            Center(
              child: AspectRatio(
                aspectRatio: _controller!.value.aspectRatio,
                child: VideoPlayer(_controller!),
              ),
            )
          else if (flick.thumbUrl != null)
            CachedNetworkImage(imageUrl: flick.thumbUrl!, fit: BoxFit.cover)
          else
            Center(child: CircularProgressIndicator(color: RMColors.primary)),

          // Gradient for legibility of the bottom overlay text.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 220,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
              ),
            ),
          ),

          // Right-side action column (like Reels' like/comment rail).
          Positioned(
            right: 12,
            bottom: 190,
            child: Column(
              children: [
                GestureDetector(
                  onTap: _toggleLike,
                  child: Column(
                    children: [
                      Icon(
                        _liked ? Icons.favorite : Icons.favorite_border,
                        color: _liked ? RMColors.danger : Colors.white,
                        size: 32,
                      ),
                      SizedBox(height: 2),
                      Text('$_likeCount',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                SizedBox(height: 20),
                GestureDetector(
                  onTap: () => setState(() {
                    _muted = !_muted;
                    _controller?.setVolume(_muted ? 0 : 1);
                  }),
                  child: Icon(
                    _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              ],
            ),
          ),

          // Creator + caption, bottom-left.
          Positioned(
            left: 16,
            right: 90,
            bottom: 190,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    PresenceAvatar(
                      radius: 15,
                      backgroundColor: RMColors.primaryDim,
                      avatarUrl: flick.creatorAvatarUrl,
                      lastActiveAt: flick.creatorLastActiveAt,
                      badgeBorderColor: Colors.black.withOpacity(0.6),
                      placeholder:
                          Icon(Icons.person_rounded, size: 16, color: RMColors.primary),
                    ),
                    SizedBox(width: 8),
                    Text('@${flick.creatorUsername}',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 14)),
                  ],
                ),
                if (flick.caption != null && flick.caption!.isNotEmpty) ...[
                  SizedBox(height: 6),
                  Text(flick.caption!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white, fontSize: 13)),
                ],
              ],
            ),
          ),

          // The comments carousel — always visible near the bottom.
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: _FlickCommentsCarousel(
              flickId: flick.id,
              initialCommentCount: flick.commentCount,
            ),
          ),
        ],
      ),
    );
  }
}

/// A compact, always-on-screen comments widget: one comment shows at a
/// time in a small rounded rectangle. Swiping up/down on the rectangle
/// moves to the next/previous comment (rather than opening a separate
/// full-screen comments page). Tapping "N replies" expands a reply
/// panel that grows *upward* from the rectangle (the rectangle itself
/// stays anchored to the same bottom position), showing every reply
/// plus a small box to add one.
class _FlickCommentsCarousel extends StatefulWidget {
  final String flickId;
  final int initialCommentCount;

  const _FlickCommentsCarousel({
    required this.flickId,
    required this.initialCommentCount,
  });

  @override
  State<_FlickCommentsCarousel> createState() => _FlickCommentsCarouselState();
}

class _FlickCommentsCarouselState extends State<_FlickCommentsCarousel> {
  List<FlickComment> _comments = [];
  bool _loading = true;
  int _index = 0;

  String? _expandedCommentId;
  final Map<String, List<FlickComment>> _replies = {};
  bool _repliesLoading = false;
  final _replyCtrl = TextEditingController();
  bool _postingReply = false;

  final _newCommentCtrl = TextEditingController();
  bool _postingComment = false;

  double _dragAccum = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _replyCtrl.dispose();
    _newCommentCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final comments =
          await SupabaseService.instance.fetchFlickComments(widget.flickId);
      if (mounted) {
        setState(() {
          _comments = comments;
          _index = 0;
        });
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _goTo(int delta) {
    if (_comments.isEmpty) return;
    setState(() {
      _index = (_index + delta).clamp(0, _comments.length - 1);
      _expandedCommentId = null; // collapse replies when switching comment
    });
  }

  Future<void> _toggleReplies(FlickComment comment) async {
    if (_expandedCommentId == comment.id) {
      setState(() => _expandedCommentId = null);
      return;
    }
    setState(() {
      _expandedCommentId = comment.id;
      _repliesLoading = !_replies.containsKey(comment.id);
    });
    if (!_replies.containsKey(comment.id)) {
      try {
        final replies =
            await SupabaseService.instance.fetchCommentReplies(comment.id);
        if (mounted) setState(() => _replies[comment.id] = replies);
      } catch (_) {
        if (mounted) setState(() => _replies[comment.id] = []);
      } finally {
        if (mounted) setState(() => _repliesLoading = false);
      }
    }
  }

  Future<void> _toggleCommentLike(FlickComment comment) async {
    setState(() {
      comment.isLiked = !comment.isLiked;
      comment.likeCount += comment.isLiked ? 1 : -1;
    });
    try {
      await SupabaseService.instance.toggleCommentLike(comment.id);
    } catch (_) {
      if (mounted) {
        setState(() {
          comment.isLiked = !comment.isLiked;
          comment.likeCount += comment.isLiked ? 1 : -1;
        });
      }
    }
  }

  Future<void> _postReply(FlickComment parent) async {
    final text = _replyCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _postingReply = true);
    try {
      await SupabaseService.instance.addFlickComment(
        flickId: widget.flickId,
        content: text,
        parentCommentId: parent.id,
      );
      _replyCtrl.clear();
      final replies = await SupabaseService.instance.fetchCommentReplies(parent.id);
      if (mounted) setState(() => _replies[parent.id] = replies);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _postingReply = false);
    }
  }

  Future<void> _postComment() async {
    final text = _newCommentCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _postingComment = true);
    try {
      await SupabaseService.instance.addFlickComment(
        flickId: widget.flickId,
        content: text,
      );
      _newCommentCtrl.clear();
      await _load(); // newest first, so this also lands on the new comment
    } catch (_) {
    } finally {
      if (mounted) setState(() => _postingComment = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return SizedBox(height: 56);
    if (_comments.isEmpty) {
      return _ComposeRow(
        controller: _newCommentCtrl,
        posting: _postingComment,
        onSubmit: _postComment,
        hint: 'Be the first to comment…',
      );
    }

    final comment = _comments[_index.clamp(0, _comments.length - 1)];
    final expanded = _expandedCommentId == comment.id;
    final replies = _replies[comment.id] ?? [];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Replies panel — sits ABOVE the comment rectangle, so opening
        // it visually grows the whole widget upward while the
        // rectangle itself stays put.
        AnimatedSize(
          duration: Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: !expanded
              ? SizedBox(width: double.infinity)
              : Container(
                  margin: EdgeInsets.only(bottom: 6),
                  constraints: BoxConstraints(maxHeight: 220),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.65),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: EdgeInsets.all(10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        child: _repliesLoading
                            ? Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: Center(
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white70),
                                  ),
                                ),
                              )
                            : replies.isEmpty
                                ? Padding(
                                    padding: EdgeInsets.symmetric(vertical: 8),
                                    child: Text('No replies yet.',
                                        style: TextStyle(
                                            color: Colors.white54, fontSize: 12)),
                                  )
                                : ListView.builder(
                                    shrinkWrap: true,
                                    physics: ClampingScrollPhysics(),
                                    itemCount: replies.length,
                                    itemBuilder: (context, i) =>
                                        _ReplyTile(reply: replies[i]),
                                  ),
                      ),
                      Divider(color: Colors.white24, height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _replyCtrl,
                              style: TextStyle(color: Colors.white, fontSize: 13),
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: 'Reply to @${comment.username}…',
                                hintStyle: TextStyle(color: Colors.white38),
                                border: InputBorder.none,
                              ),
                              onSubmitted: (_) => _postReply(comment),
                            ),
                          ),
                          EmojiSheetButton(
                            controller: _replyCtrl,
                            color: Colors.white70,
                            iconSize: 18,
                            compact: true,
                          ),
                          SizedBox(width: 6),
                          _postingReply
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white70),
                                )
                              : IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: BoxConstraints(),
                                  icon: Icon(Icons.send_rounded,
                                      color: RMColors.primary, size: 18),
                                  onPressed: () => _postReply(comment),
                                ),
                        ],
                      ),
                    ],
                  ),
                ),
        ),

        // The comment rectangle itself — swipe vertically to move
        // between top-level comments.
        GestureDetector(
          onVerticalDragUpdate: (details) {
            _dragAccum += details.delta.dy;
          },
          onVerticalDragEnd: (_) {
            if (_dragAccum < -18) {
              _goTo(1); // dragged up -> next comment
            } else if (_dragAccum > 18) {
              _goTo(-1); // dragged down -> previous comment
            }
            _dragAccum = 0;
          },
          child: AnimatedSwitcher(
            duration: Duration(milliseconds: 180),
            child: Container(
              key: ValueKey(comment.id),
              padding: EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PresenceAvatar(
                    radius: 14,
                    backgroundColor: RMColors.primaryDim,
                    avatarUrl: comment.avatarUrl,
                    lastActiveAt: comment.lastActiveAt,
                    badgeBorderColor: Colors.black.withOpacity(0.6),
                    placeholder:
                        Icon(Icons.person_rounded, size: 14, color: RMColors.primary),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '@${comment.username}  ',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12.5),
                              ),
                              TextSpan(
                                text: comment.content,
                                style: TextStyle(color: Colors.white, fontSize: 12.5),
                              ),
                            ],
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        SizedBox(height: 4),
                        Row(
                          children: [
                            GestureDetector(
                              onTap: () => _toggleCommentLike(comment),
                              child: Row(
                                children: [
                                  Icon(
                                    comment.isLiked
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    size: 14,
                                    color: comment.isLiked
                                        ? RMColors.danger
                                        : Colors.white60,
                                  ),
                                  SizedBox(width: 3),
                                  Text('${comment.likeCount}',
                                      style: TextStyle(
                                          color: Colors.white60, fontSize: 11)),
                                ],
                              ),
                            ),
                            SizedBox(width: 16),
                            GestureDetector(
                              onTap: () => _toggleReplies(comment),
                              child: Text(
                                comment.replyCount == 0
                                    ? 'Reply'
                                    : (expanded
                                        ? 'Hide replies'
                                        : '${comment.replyCount} ${comment.replyCount == 1 ? 'reply' : 'replies'}'),
                                style: TextStyle(
                                    color: Colors.white60,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (_comments.length > 1)
                    Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.keyboard_arrow_up_rounded,
                              size: 14,
                              color: _index > 0 ? Colors.white54 : Colors.white24),
                          Text('${_index + 1}/${_comments.length}',
                              style: TextStyle(color: Colors.white38, fontSize: 9)),
                          Icon(Icons.keyboard_arrow_down_rounded,
                              size: 14,
                              color: _index < _comments.length - 1
                                  ? Colors.white54
                                  : Colors.white24),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(height: 6),
        _ComposeRow(
          controller: _newCommentCtrl,
          posting: _postingComment,
          onSubmit: _postComment,
          hint: 'Add a comment…',
        ),
      ],
    );
  }
}

class _ReplyTile extends StatelessWidget {
  final FlickComment reply;
  const _ReplyTile({required this.reply});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PresenceAvatar(
            radius: 10,
            backgroundColor: RMColors.primaryDim,
            avatarUrl: reply.avatarUrl,
            lastActiveAt: reply.lastActiveAt,
            badgeBorderColor: Colors.black.withOpacity(0.65),
            placeholder: Icon(Icons.person_rounded, size: 11, color: RMColors.primary),
          ),
          SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '@${reply.username}  ',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5),
                  ),
                  TextSpan(
                    text: reply.content,
                    style: TextStyle(color: Colors.white70, fontSize: 11.5),
                  ),
                ],
              ),
            ),
          ),
          Icon(
            reply.isLiked ? Icons.favorite : Icons.favorite_border,
            size: 12,
            color: reply.isLiked ? RMColors.danger : Colors.white38,
          ),
        ],
      ),
    );
  }
}

/// Small always-visible "add a top-level comment" input row.
class _ComposeRow extends StatelessWidget {
  final TextEditingController controller;
  final bool posting;
  final VoidCallback onSubmit;
  final String hint;

  const _ComposeRow({
    required this.controller,
    required this.posting,
    required this.onSubmit,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              style: TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: hint,
                hintStyle: TextStyle(color: Colors.white54),
              ),
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          EmojiSheetButton(
            controller: controller,
            color: Colors.white70,
            iconSize: 18,
            compact: true,
          ),
          SizedBox(width: 6),
          posting
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                )
              : IconButton(
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(),
                  icon: Icon(Icons.send_rounded, color: RMColors.primary, size: 18),
                  onPressed: onSubmit,
                ),
        ],
      ),
    );
  }
}
