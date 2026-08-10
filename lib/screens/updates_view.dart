import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/news_article.dart';
import '../services/news_service.dart';
import '../services/supabase_service.dart';
import '../services/local_cache_service.dart';
import '../services/article_image_service.dart';
import '../services/ad_service.dart';
import '../services/generated_image_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/native_ad_card.dart';
import '../widgets/news_card.dart';
import 'news_comments_sheet.dart';
import 'news_detail_screen.dart';
import 'news_redrop_sheet.dart';

/// The "Updates" side of the Realm tab's Drops/Updates toggle — real
/// news, syndicated from Kenyan outlets first (general + entertainment),
/// then Africa, then the rest of the world. Every card links back to
/// the original publisher; nothing here is stored or reproduced beyond
/// a headline and a short summary.
class UpdatesView extends StatefulWidget {
  /// Called after a redrop (or share-to-status) actually completes,
  /// so [FeedScreen] can refresh the Drops tab's redrop feed without
  /// the person having to leave and come back to this tab first.
  final VoidCallback? onRedropped;

  const UpdatesView({super.key, this.onRedropped});

  @override
  State<UpdatesView> createState() => UpdatesViewState();
}

class UpdatesViewState extends State<UpdatesView> {
  static const _cacheKey = 'news_updates';

  // Topic filter for the FAB below — matched against NewsArticle.category
  // (see news_service.dart's feed list for which categories actually
  // have real feeds behind them). "News" is its own entry rather than
  // folded into "All" because most stories have category == null, so
  // it needs an explicit bucket to be selectable on its own.
  static final List<_NewsFilterOption> _filterOptions = [
    _NewsFilterOption('All updates', Icons.dynamic_feed_rounded, null),
    _NewsFilterOption('News', Icons.newspaper_rounded, ''),
    _NewsFilterOption('Entertainment', Icons.theater_comedy_rounded, 'Entertainment'),
    _NewsFilterOption('Sports', Icons.sports_soccer_rounded, 'Sports'),
    _NewsFilterOption('Transfers', Icons.swap_horiz_rounded, 'Transfers'),
    _NewsFilterOption('Business', Icons.trending_up_rounded, 'Business'),
    _NewsFilterOption('Technology', Icons.memory_rounded, 'Technology'),
    // Plain world headlines — same "News" bucket (category == null) as
    // the Kenya/Africa stories above, just scoped to NewsTier.world so
    // it's selectable on its own instead of staying mixed into "News".
    _NewsFilterOption('Global News', Icons.public_rounded, '',
        tier: NewsTier.world),
    _NewsFilterOption('Gossip', Icons.record_voice_over_rounded, 'Gossip'),
  ];

  List<NewsArticle> _articles = [];
  bool _loading = true;
  bool _offline = false;
  String? _error;
  int _filterIndex = 0; // index into _filterOptions; 0 = All updates
  bool _hideBreaking = false;

  final _scrollController = ScrollController();
  Timer? _pollTimer;
  // Set once a background poll finds stories not already in _articles.
  // Deliberately kept separate from _articles itself rather than
  // merged straight in — swapping the list out from under someone
  // mid-scroll would yank their scroll position around, which is
  // exactly the jarring behavior the pop-up button below exists to
  // avoid. It only actually replaces _articles once they either tap
  // the button or scroll back to the top themselves.
  List<NewsArticle>? _pendingArticles;
  bool get _hasNewUpdates => _pendingArticles != null;

  // Whether the button is actually visible right now. Deliberately a
  // separate flag from _hasNewUpdates rather than derived straight
  // from it — new stories showing up mid-scroll shouldn't just pop a
  // button into view immediately, that's a jump-scare in the middle
  // of reading. Instead this waits for [_onScroll] to see a natural
  // "pause and reconsider" gesture: scroll down, then reverse and
  // scroll back up (bookmarking that point as _turnaroundOffset), then
  // scroll back down again past that same point — the moment someone
  // shows renewed intent to keep heading down is the moment offering
  // "jump back to the top instead" is actually useful instead of
  // intrusive.
  bool _revealButton = false;
  double _lastScrollOffset = 0;
  double? _turnaroundOffset;
  bool _wasScrollingDown = false;

  // Fallback so the button isn't permanently invisible for someone
  // who just scrolls straight down and never once reverses direction
  // — past this much continuous downward scroll, reveal it anyway
  // rather than waiting forever for a gesture that may never come.
  static const _fallbackRevealOffset = 600.0;

  // Free-floating position for the new-updates button — null until
  // the first time it's shown, at which point _buildNewUpdatesButton
  // seeds it from the screen size. Kept across rebuilds (not just
  // recomputed from scratch each time) so dragging it actually sticks
  // for the rest of this screen's lifetime instead of snapping back.
  double? _fabLeft;
  double? _fabTop;

  List<NewsArticle> get _filteredArticles {
    final option = _filterOptions[_filterIndex];
    Iterable<NewsArticle> result = _articles;
    if (option.category == '') {
      result = result.where((a) => a.category == null); // "News"
    } else if (option.category != null) {
      result = result.where((a) => a.category == option.category);
    } // else "All updates" — no category filtering
    if (option.tier != null) {
      result = result.where((a) => a.tier == option.tier);
    }
    if (_hideBreaking) {
      result = result.where((a) => !a.isBreaking);
    }
    return result.toList();
  }

  bool get _isGossipFilter => _filterOptions[_filterIndex].category == 'Gossip';

  @override
  void initState() {
    super.initState();
    _loadCached();
    refresh();
    _scrollController.addListener(_onScroll);
    // Checks for genuinely new stories every 45s while this screen is
    // actually mounted — it un-mounts (see FeedScreen's Drops/Updates
    // toggle) whenever the person flips back to Drops, which is also
    // what stops this timer, so it's never quietly polling in the
    // background for a tab nobody's looking at.
    _pollTimer = Timer.periodic(
        const Duration(seconds: 45), (_) => _checkForNewStories());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  /// Tracks scroll direction to find the "reconsidered, then
  /// recommitted" gesture described above, and separately still folds
  /// pending updates straight in the instant someone's back near the
  /// top — that part doesn't need any button at all.
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final offset = _scrollController.offset;
    final delta = offset - _lastScrollOffset;
    _lastScrollOffset = offset;

    // Already at (or very near) the top — nothing to protect, apply
    // directly, same as before, and drop any half-tracked gesture
    // state since there's no "point" left worth remembering.
    if (_hasNewUpdates && offset < 80) {
      _turnaroundOffset = null;
      _applyPendingUpdates(animateScroll: false);
      return;
    }

    // Ignore sub-pixel jitter (overscroll bounce, minor relayouts) so
    // this doesn't flip "direction" on noise rather than an actual
    // scroll gesture.
    if (delta.abs() < 4) return;
    final scrollingDown = delta > 0;

    if (_wasScrollingDown && !scrollingDown) {
      // Just reversed from heading down to heading up — bookmark
      // this as the point they'd have to scroll back past to count
      // as "actually continuing on down" rather than just a quick
      // glance back up at something they scrolled past.
      _turnaroundOffset = offset;
    } else if (!_wasScrollingDown &&
        scrollingDown &&
        _turnaroundOffset != null &&
        offset >= _turnaroundOffset!) {
      // Heading down again and just passed that bookmark — the
      // "ok, actually continuing down" signal this whole thing is
      // watching for.
      _turnaroundOffset = null;
      if (_hasNewUpdates && !_revealButton) setState(() => _revealButton = true);
    }
    _wasScrollingDown = scrollingDown;

    if (_hasNewUpdates &&
        !_revealButton &&
        offset >= _fallbackRevealOffset) {
      // Straight-line scrolling with no reversal yet — the gesture
      // above may just never happen this session, so don't leave the
      // button invisible forever.
      setState(() => _revealButton = true);
    }
  }

  /// The quiet background check the pop-up button is watching for —
  /// unlike [refresh], this never touches loading/error state or the
  /// visible list directly, since a failed or slow poll shouldn't be
  /// visible as anything at all.
  Future<void> _checkForNewStories() async {
    if (!mounted) return;
    try {
      final fresh = await NewsService.instance.latest();
      if (!mounted) return;
      final existingIds = _articles.map((a) => a.id).toSet();
      final hasNew = fresh.any((a) => !existingIds.contains(a.id));
      if (!hasNew) return;
      if (!_scrollController.hasClients || _scrollController.offset < 80) {
        // Already at the top (or the list isn't even scrollable yet)
        // — nothing to protect, just apply it directly.
        setState(() {
          _articles = fresh;
          _pendingArticles = null;
        });
        await LocalCacheService.instance
            .saveList(_cacheKey, fresh.map((a) => a.toMap()).toList());
      } else {
        setState(() => _pendingArticles = fresh);
      }
    } catch (_) {
      // Best-effort — a failed background poll just tries again on
      // the next tick, same as any other silent background refresh
      // in this app.
    }
  }

  /// Swaps the pending list in — called by a tap on the pop-up button
  /// (with a scroll-to-top animation, since the person is choosing to
  /// jump there) or by [_onScroll] noticing they've already scrolled
  /// back up on their own (no animation needed, they're already there).
  Future<void> _applyPendingUpdates({required bool animateScroll}) async {
    final pending = _pendingArticles;
    if (pending == null) return;
    setState(() {
      _articles = pending;
      _pendingArticles = null;
      _revealButton = false;
    });
    _turnaroundOffset = null;
    await LocalCacheService.instance
        .saveList(_cacheKey, pending.map((a) => a.toMap()).toList());
    if (animateScroll && _scrollController.hasClients) {
      await _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _loadCached() async {
    final cached = await LocalCacheService.instance.loadList(_cacheKey);
    if (cached != null && cached.isNotEmpty && mounted && _articles.isEmpty) {
      setState(() {
        _articles = cached.map(NewsArticle.fromMap).toList();
        _loading = false;
      });
    }
  }

  /// Called on pull-to-refresh, and whenever the Updates segment is
  /// (re)selected from [FeedScreen] — same "never sit on stale data"
  /// contract as the Drops feed.
  Future<void> refresh() async {
    if (_articles.isEmpty) setState(() { _loading = true; _error = null; });
    try {
      final articles = await NewsService.instance.latest();
      if (mounted) {
        setState(() {
          _articles = articles;
          _offline = false;
          _error = null;
          _pendingArticles = null;
          _revealButton = false;
        });
        _turnaroundOffset = null;
      }
      await LocalCacheService.instance
          .saveList(_cacheKey, articles.map((a) => a.toMap()).toList());
    } catch (e) {
      if (mounted) {
        if (_articles.isNotEmpty) {
          setState(() => _offline = true);
        } else {
          setState(() => _error = 'Could not load news right now.');
        }
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openExternal(NewsArticle article) async {
    final uri = Uri.tryParse(article.link);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _openDetail(NewsArticle article) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NewsDetailScreen(article: article)),
    );
  }

  Future<void> _openComments(NewsArticle article) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => NewsCommentsSheet(article: article),
    );
  }

  Future<RedropOutcome?> _openRedropSheet(NewsArticle article) {
    return showModalBottomSheet<RedropOutcome>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => NewsRedropSheet(article: article),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _articles.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: RMColors.primary),
            SizedBox(height: 16),
            Text('Fetching the latest…',
                style: TextStyle(color: RMColors.textSecondary)),
          ],
        ),
      );
    }
    if (_error != null && _articles.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off_rounded, color: RMColors.textHint, size: 48),
              SizedBox(height: 16),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: RMColors.textSecondary)),
              SizedBox(height: 20),
              OutlinedButton(onPressed: refresh, child: Text('Try again')),
            ],
          ),
        ),
      );
    }

    final filtered = _filteredArticles;

    return Stack(
      children: [
        RefreshIndicator(
          color: RMColors.primary,
          backgroundColor: RMColors.surface,
          onRefresh: refresh,
          child: filtered.isEmpty
              ? _buildEmptyFilterState()
              : ListView.separated(
                  controller: _scrollController,
                  physics: AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 100),
                  itemCount: AdService.itemCountWithAds(filtered.length) +
                      (_offline ? 1 : 0) +
                      (_isGossipFilter ? 1 : 0),
                  separatorBuilder: (_, __) => SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final bannerCount =
                        (_offline ? 1 : 0) + (_isGossipFilter ? 1 : 0);
                    if (_offline && index == 0) {
                      return Container(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: RMColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.cloud_off_rounded,
                                size: 16, color: RMColors.textHint),
                            SizedBox(width: 8),
                            Text('Offline — showing saved stories',
                                style: TextStyle(
                                    color: RMColors.textSecondary, fontSize: 12)),
                          ],
                        ),
                      );
                    }
                    if (_isGossipFilter &&
                        index == (_offline ? 1 : 0)) {
                      return Container(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: RMColors.accent.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: RMColors.accent.withOpacity(0.3)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.report_gmailerrorred_rounded,
                                size: 16, color: RMColors.accent),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Celebrity gossip from entertainment blogs — '
                                'rumor and reader tips, not fact-checked '
                                'reporting. Take it with a grain of salt.',
                                style: TextStyle(
                                    color: RMColors.textSecondary, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    final feedPos = index - bannerCount;
                    if (AdService.isAdSlot(feedPos)) {
                      return NativeAdCard(
                        key: ValueKey('updates_native_ad_$feedPos'),
                      );
                    }
                    final article =
                        filtered[AdService.contentIndexForSlot(feedPos)];
                    return _NewsCardWithCount(
                      key: ValueKey(article.id),
                      article: article,
                      onOpenDetail: _openDetail,
                      onOpenExternal: _openExternal,
                      onOpenComments: _openComments,
                      onOpenRedropSheet: _openRedropSheet,
                      onRedropped: widget.onRedropped,
                    );
                  },
                ),
        ),
        if (_revealButton) _buildNewUpdatesButton(context),
        Positioned(
          right: 16,
          bottom: 16,
          child: _NewsFilterFab(
            options: _filterOptions,
            selectedIndex: _filterIndex,
            onSelect: (index) => setState(() => _filterIndex = index),
            hideBreaking: _hideBreaking,
            onHideBreakingChanged: (value) =>
                setState(() => _hideBreaking = value),
          ),
        ),
      ],
    );
  }

  /// A round, draggable "new stories" button — pops up over the list
  /// itself (not docked to an edge) so it can sit wherever's out of
  /// the way of whatever someone's currently reading, and stays put
  /// at wherever they last dragged it for the rest of this screen's
  /// lifetime. Tapping it is the "take me to the new stuff" action;
  /// dragging it just repositions it and does nothing else.
  Widget _buildNewUpdatesButton(BuildContext context) {
    const size = 52.0;
    final screen = MediaQuery.of(context).size;
    final safePadding = MediaQuery.of(context).padding;
    // Seeded once, top-center — high enough to read as "there's new
    // stuff above you", clear of both the filter FAB (bottom-right)
    // and the offline/gossip banners that can sit at the very top of
    // the list itself.
    _fabLeft ??= (screen.width - size) / 2;
    _fabTop ??= 16.0;

    return Positioned(
      left: _fabLeft,
      top: _fabTop,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _fabLeft = (_fabLeft! + details.delta.dx)
                .clamp(8.0, screen.width - size - 8.0);
            _fabTop = (_fabTop! + details.delta.dy).clamp(
              8.0,
              screen.height - safePadding.top - safePadding.bottom - size - 120.0,
            );
          });
        },
        onTap: () => _applyPendingUpdates(animateScroll: true),
        child: Material(
          color: RMColors.primary,
          shape: const CircleBorder(),
          elevation: 6,
          shadowColor: Colors.black45,
          child: SizedBox(
            width: size,
            height: size,
            child: const Icon(Icons.arrow_upward_rounded,
                color: Colors.white, size: 24),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyFilterState() {
    final option = _filterOptions[_filterIndex];
    final topicLabel = option.category == null ? null : option.label;
    final label = [topicLabel, _hideBreaking ? 'non-breaking' : null]
        .whereType<String>()
        .join(', ');
    return ListView(
      physics: AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(top: 80),
      children: [
        Column(
          children: [
            Icon(Icons.filter_alt_off_rounded, color: RMColors.textHint, size: 40),
            SizedBox(height: 14),
            Text(
              label.isEmpty ? 'No stories right now' : 'No $label stories right now',
              style: TextStyle(color: RMColors.textSecondary),
            ),
            SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => setState(() {
                _filterIndex = 0;
                _hideBreaking = false;
              }),
              child: Text('Show all updates'),
            ),
          ],
        ),
      ],
    );
  }
}

class _NewsFilterOption {
  final String label;
  final IconData icon;
  // null = "All updates" (no filtering). '' = the "News" bucket, i.e.
  // articles with no category at all. Anything else matches
  // NewsArticle.category exactly.
  final String? category;
  // Optional extra narrowing by [NewsTier], on top of whatever
  // [category] already filters by — e.g. "Global News" reuses the
  // "News" (category == null) bucket but scopes it to
  // NewsTier.world, since that bucket otherwise mixes Kenya, Africa,
  // and world stories together.
  final NewsTier? tier;
  const _NewsFilterOption(this.label, this.icon, this.category, {this.tier});
}

/// The FAB "down the Updates tab" that lets someone jump straight to
/// a topic — tapping it opens a short list of options upward (News,
/// Entertainment, Sports, Business, Technology, or everything) rather
/// than navigating to a separate filter screen, since there are only
/// a handful of topics and the whole point is a quick one-tap switch
/// without losing your place in the feed.
class _NewsFilterFab extends StatefulWidget {
  final List<_NewsFilterOption> options;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final bool hideBreaking;
  final ValueChanged<bool> onHideBreakingChanged;

  const _NewsFilterFab({
    required this.options,
    required this.selectedIndex,
    required this.onSelect,
    required this.hideBreaking,
    required this.onHideBreakingChanged,
  });

  @override
  State<_NewsFilterFab> createState() => _NewsFilterFabState();
}

class _NewsFilterFabState extends State<_NewsFilterFab> {
  bool _open = false;

  void _toggle() => setState(() => _open = !_open);

  void _select(int index) {
    widget.onSelect(index);
    setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.options[widget.selectedIndex];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // ── Options list, opening upward above the FAB ─────────────
        AnimatedSwitcher(
          duration: Duration(milliseconds: 160),
          child: _open
              ? Container(
                  key: ValueKey('open'),
                  margin: EdgeInsets.only(bottom: 12),
                  padding: EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: RMColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: RMColors.border),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.25),
                        blurRadius: 16,
                        offset: Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < widget.options.length; i++)
                        _FilterOptionTile(
                          option: widget.options[i],
                          selected: i == widget.selectedIndex,
                          onTap: () => _select(i),
                        ),
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: Divider(height: 1, color: RMColors.border),
                      ),
                      _BreakingToggleTile(
                        value: widget.hideBreaking,
                        onChanged: widget.onHideBreakingChanged,
                      ),
                    ],
                  ),
                )
              : SizedBox.shrink(key: ValueKey('closed')),
        ),
        // ── The FAB itself — icon reflects the active filter, and a
        // small dot marks that a filter (other than "All") or the
        // breaking-news toggle is on, so it's obvious at a glance
        // even when the menu is closed.
        Stack(
          clipBehavior: Clip.none,
          children: [
            FloatingActionButton(
              heroTag: 'updates_filter_fab',
              backgroundColor: RMColors.primary,
              foregroundColor: Colors.white,
              onPressed: _toggle,
              tooltip: 'Filter updates',
              child: Icon(_open ? Icons.close_rounded : selected.icon),
            ),
            if (!_open && (widget.selectedIndex != 0 || widget.hideBreaking))
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: RMColors.success,
                    shape: BoxShape.circle,
                    border: Border.all(color: RMColors.background, width: 2),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _FilterOptionTile extends StatelessWidget {
  final _NewsFilterOption option;
  final bool selected;
  final VoidCallback onTap;

  const _FilterOptionTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 200,
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(option.icon,
                size: 18,
                color: selected ? RMColors.primary : RMColors.textSecondary),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                option.label,
                style: TextStyle(
                  color: selected ? RMColors.primary : RMColors.textPrimary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 14,
                ),
              ),
            ),
            if (selected)
              Icon(Icons.check_rounded, size: 16, color: RMColors.primary),
          ],
        ),
      ),
    );
  }
}

class _BreakingToggleTile extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _BreakingToggleTile({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Container(
        width: 200,
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.notifications_off_outlined,
                size: 18,
                color: value ? RMColors.primary : RMColors.textSecondary),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Hide breaking news',
                style: TextStyle(
                  color: value ? RMColors.primary : RMColors.textPrimary,
                  fontWeight: value ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 13,
                ),
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeColor: RMColors.primary,
            ),
          ],
        ),
      ),
    );
  }
}

/// Wraps [NewsCard] with a lazily-fetched comment count, resolved
/// once per card the same way [DropCard] lazily resolves its place
/// name — cheap, best-effort, and never blocks the card from showing.
class _NewsCardWithCount extends StatefulWidget {
  final NewsArticle article;
  final void Function(NewsArticle) onOpenDetail;
  final void Function(NewsArticle) onOpenExternal;
  final Future<void> Function(NewsArticle) onOpenComments;
  final Future<RedropOutcome?> Function(NewsArticle) onOpenRedropSheet;
  final VoidCallback? onRedropped;

  const _NewsCardWithCount({
    super.key,
    required this.article,
    required this.onOpenDetail,
    required this.onOpenExternal,
    required this.onOpenComments,
    required this.onOpenRedropSheet,
    this.onRedropped,
  });

  @override
  State<_NewsCardWithCount> createState() => _NewsCardWithCountState();
}

class _NewsCardWithCountState extends State<_NewsCardWithCount> {
  int? _count;
  int? _redropCount;
  bool _iRedropped = false;
  int? _likeCount;
  bool _iLiked = false;
  bool _liking = false;
  NewsArticle? _resolvedArticle;

  @override
  void initState() {
    super.initState();
    _loadCount();
    _loadRedropState();
    _loadLikeState();
    _resolveImageIfMissing();
  }

  @override
  void didUpdateWidget(_NewsCardWithCount oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.article.id != widget.article.id) {
      _resolvedArticle = null;
      _resolveImageIfMissing();
    }
  }

  Future<void> _loadCount() async {
    try {
      final count =
          await SupabaseService.instance.fetchNewsCommentCount(widget.article.link);
      if (mounted) setState(() => _count = count);
    } catch (_) {
      // Best-effort — the count pill just stays generic without it.
    }
  }

  Future<void> _loadRedropState() async {
    try {
      final results = await Future.wait([
        SupabaseService.instance.fetchNewsRedropCount(widget.article.link),
        SupabaseService.instance.fetchMyNewsRedrop(widget.article.link),
      ]);
      if (!mounted) return;
      setState(() {
        _redropCount = results[0] as int;
        _iRedropped = (results[1] as Map<String, dynamic>?) != null;
      });
    } catch (_) {
      // Best-effort, same contract as _loadCount above.
    }
  }

  /// If the feed didn't give us an image, first look one up from the
  /// story's own page (see [ArticleImageService]); if that also comes
  /// up empty, fall back to a generated illustration (see
  /// [GeneratedImageService], which is itself a no-op unless the
  /// person running this app has opted in with an API key). Same
  /// "cheap, best-effort, never blocks the card" contract throughout.
  Future<void> _resolveImageIfMissing() async {
    if (widget.article.imageUrl != null) return;
    try {
      final result =
          await ArticleImageService.instance.resolve(widget.article.link);
      if (result != null) {
        if (!mounted) return;
        setState(() {
          _resolvedArticle = widget.article.withResolvedImage(
            imageUrl: result.imageUrl,
            imageCredit: result.credit,
          );
        });
        return;
      }
    } catch (_) {
      // Fall through to the generated-illustration attempt below.
    }

    if (!GeneratedImageService.instance.shouldGenerate(widget.article)) {
      return;
    }
    try {
      final bytes =
          await GeneratedImageService.instance.generate(widget.article);
      if (bytes == null || !mounted) return;
      setState(() {
        _resolvedArticle = widget.article.withGeneratedImage(bytes);
      });
    } catch (_) {
      // No image, generated or otherwise — the card still works fine.
    }
  }

  Future<void> _loadLikeState() async {
    try {
      final results = await Future.wait([
        SupabaseService.instance.fetchNewsLikeCount(widget.article.link),
        SupabaseService.instance.fetchDidILikeNews(widget.article.link),
      ]);
      if (!mounted) return;
      setState(() {
        _likeCount = results[0] as int;
        _iLiked = results[1] as bool;
      });
    } catch (_) {
      // Best-effort, same contract as _loadCount above.
    }
  }

  Future<void> _toggleLike() async {
    if (_liking) return;
    final wasLiked = _iLiked;
    setState(() {
      _liking = true;
      _iLiked = !wasLiked;
      _likeCount = (_likeCount ?? 0) + (_iLiked ? 1 : -1);
    });
    try {
      final nowLiked = await SupabaseService.instance.toggleNewsLike(
        articleLink: widget.article.link,
        articleTitle: widget.article.title,
      );
      if (mounted && nowLiked != _iLiked) {
        setState(() {
          _iLiked = nowLiked;
          _likeCount = (_likeCount ?? 0) + (_iLiked ? 1 : -1);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _iLiked = wasLiked;
          _likeCount = (_likeCount ?? 0) + (wasLiked ? 1 : -1);
        });
      }
    } finally {
      if (mounted) setState(() => _liking = false);
    }
  }


  Future<void> _handleRedrop() async {
    final outcome = await widget.onOpenRedropSheet(_resolvedArticle ?? widget.article);
    if (outcome == null || !mounted) return;
    if (outcome == RedropOutcome.sharedToStatus) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Shared to your status')));
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Redropped')));
    }
    _loadRedropState();
    widget.onRedropped?.call();
  }

  @override
  Widget build(BuildContext context) {
    final resolved = _resolvedArticle ?? widget.article;
    return NewsCard(
      article: resolved,
      commentCount: _count,
      redropCount: _redropCount,
      iRedropped: _iRedropped,
      likeCount: _likeCount,
      iLiked: _iLiked,
      onLike: _toggleLike,
      onOpenDetail: () => widget.onOpenDetail(resolved),
      onOpenExternal: () => widget.onOpenExternal(resolved),
      onOpenComments: () async {
        // Refresh the count once the sheet actually closes, in case
        // the person just added a comment. Passing the resolved
        // article through means the comments sheet's header (if it
        // shows one) also gets the story's image, same as the detail
        // screen and redrop sheet.
        await widget.onOpenComments(resolved);
        _loadCount();
      },
      onRedrop: _handleRedrop,
    );
  }
}
