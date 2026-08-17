import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:cached_network_image/cached_network_image.dart';
import '../models/drop.dart';
import '../models/redrop_feed_item.dart';
import '../services/location_service.dart';
import '../services/supabase_service.dart';
import '../services/onboarding_service.dart';
import '../services/local_cache_service.dart';
import '../services/gesture_exclusion_service.dart';
import '../services/push_notification_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/tutorial_overlay.dart';
import '../widgets/drop_card.dart';
import '../widgets/native_ad_card.dart';
import '../widgets/redrop_feed_card.dart';
import '../widgets/messages_drawer.dart';
import 'create_drop_screen.dart';
import 'profile_screen.dart';
import 'drop_detail_screen.dart';
import 'user_search_screen.dart';
import 'news_comments_sheet.dart';
import 'news_detail_screen.dart';
import 'news_redrop_sheet.dart';
import 'updates_view.dart';

class FeedScreen extends StatefulWidget {
  FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => FeedScreenState();
}

class FeedScreenState extends State<FeedScreen> with TickerProviderStateMixin {
  static const _cacheKey = 'nearby_drops';

  List<Drop> _drops = [];
  geo.Position? _position;
  bool _loading = true;
  bool _offline = false;
  String? _error;
  bool _showTutorial = false;
  StreamSubscription<geo.Position>? _positionSub;
  late AnimationController _fabCtrl;
  late Animation<double> _fabScale;
  DateTime? _lastFetchAt;
  bool _fetchInFlight = false;
  String? _avatarUrl;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _updatesKey = GlobalKey<UpdatesViewState>();

  // Drops / Updates segmented toggle at the top of this tab. Kept as
  // local UI state (not persisted) — always opens back on Drops,
  // which is this tab's primary purpose.
  int _section = 0; // 0 = Drops, 1 = Updates

  // Redrops surfaced at the top of the Drops list — every redrop
  // across Realm, newest first (see fetch_redrop_feed, v18-migration.sql).
  // Deliberately not folded into _drops/_visibleDrops: a redrop has no
  // location, distance, or unlock radius, so it can't go through the
  // same nearby-drops query — it's laid over the top of that list
  // instead.
  List<RedropFeedItem> _redrops = [];

  StreamSubscription<PendingNewsAction>? _pendingActionSub;

  @override
  void initState() {
    super.initState();
    _fabCtrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 600),
    );
    _fabScale = CurvedAnimation(parent: _fabCtrl, curve: Curves.elasticOut);
    _loadCachedDrops();
    _initLocation();
    _checkTutorial();
    _loadAvatar();
    _loadRedrops();
    // Reserve the left edge for the drawer's open-swipe instead of
    // letting Android's gesture-nav back swipe steal it — only while
    // this tab (the one with the drawer) is actually on screen.
    GestureExclusionService.instance.enable();

    // Push notifications: by the time this tab exists, sign-in has
    // definitely completed, which covers the case in
    // PushNotificationService._saveToken where the very first token
    // arrived before that was true. A tap that's already pending
    // (app cold-started from a notification) gets handled once, right
    // after the first frame, since opening a modal sheet before that
    // has a BuildContext to work with would fail.
    PushNotificationService.instance.registerTokenForCurrentUser();
    _pendingActionSub = PushNotificationService.instance.pendingActions
        .listen(_handlePendingNewsAction);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final initial = PushNotificationService.instance.consumeInitialAction();
      if (initial != null) _handlePendingNewsAction(initial);
    });
  }

  /// Own avatar for the profile shortcut top-right — loaded once here
  /// and refreshed after returning from the profile screen, since
  /// that's the only place it can change (see _openProfile).
  Future<void> _loadAvatar() async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) return;
    final stats = await SupabaseService.instance.fetchProfileStats(user.id);
    if (mounted) setState(() => _avatarUrl = stats?.avatarUrl);
  }

  /// The redrop feed shown above the nearby-drop cards. Called on
  /// initial load, on pull-to-refresh, whenever this tab is switched
  /// back to (see [refresh]), whenever someone flips from Updates
  /// back to Drops (see [_sectionTab]), and right after a redrop
  /// completes from the Updates side (see the `onRedropped` callback
  /// passed to [UpdatesView] below) — so a fresh redrop shows up here
  /// as immediately as it reasonably can without a realtime subscription.
  Future<void> _loadRedrops() async {
    try {
      final redrops = await SupabaseService.instance.fetchRedropFeed();
      if (mounted) setState(() => _redrops = redrops);
    } catch (_) {
      // Best-effort — the Drops list still works fine without this;
      // it just won't show any redrops until the next successful load.
    }
  }

  Future<void> _openRedropDetail(RedropFeedItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => NewsDetailScreen(article: item.toArticleStub())),
    );
  }

  Future<void> _openRedropComments(RedropFeedItem item) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => NewsCommentsSheet(article: item.toArticleStub()),
    );
    _loadRedrops();
  }

  Future<void> _openRedropSheet(RedropFeedItem item) async {
    final outcome = await showModalBottomSheet<RedropOutcome>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => NewsRedropSheet(article: item.toArticleStub()),
    );
    if (outcome != null) _loadRedrops();
  }

  /// A tap on a "new story" push notification, or on its Redrop/
  /// Comment action button (see PushNotificationService) — jumps
  /// straight to Updates, then opens whichever sheet the action
  /// button asked for. A plain tap (no action button) just opens the
  /// story itself, same as tapping any other card would.
  Future<void> _handlePendingNewsAction(PendingNewsAction action) async {
    if (mounted && _section != 1) setState(() => _section = 1);
    switch (action.type) {
      case 'redrop':
        final outcome = await showModalBottomSheet<RedropOutcome>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => NewsRedropSheet(article: action.article),
        );
        if (outcome != null) _loadRedrops();
        break;
      case 'comment':
        await showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => NewsCommentsSheet(article: action.article),
        );
        break;
      default:
        await Navigator.of(context).push(
          MaterialPageRoute(
              builder: (_) => NewsDetailScreen(article: action.article)),
        );
    }
  }

  Future<void> _openProfile() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ProfileScreen()),
    );
    _loadAvatar();
  }

  /// Shows whatever drops were cached last time immediately, before
  /// location has even been acquired — so re-opening the app doesn't
  /// mean staring at a spinner (or, offline, an error) for content
  /// that was already sitting on the device.
  Future<void> _loadCachedDrops() async {
    final cached = await LocalCacheService.instance.loadList(_cacheKey);
    if (cached != null && cached.isNotEmpty && mounted && _drops.isEmpty) {
      setState(() {
        _drops = cached.map(Drop.fromMap).toList();
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _pendingActionSub?.cancel();
    _fabCtrl.dispose();
    GestureExclusionService.instance.disable();
    super.dispose();
  }

  /// Called by [HomeShell] every time this tab is selected (including
  /// switching back to it), so the feed never sits on stale data.
  Future<void> refresh() async {
    if (_position != null) {
      await _fetchDrops(_position!, force: true);
    } else {
      await _initLocation();
    }
    _loadRedrops();
    _updatesKey.currentState?.refresh();
  }

  Future<void> _checkTutorial() async {
    final show = await OnboardingService.instance.shouldShowFeedTutorial();
    if (mounted) setState(() => _showTutorial = show);
  }

  Future<void> _initLocation() async {
    if (_drops.isEmpty) setState(() { _loading = true; _error = null; });
    try {
      final position = await LocationService.instance.getCurrentPosition();
      setState(() => _position = position);
      await _fetchDrops(position, force: true);
      _fabCtrl.forward();

      _positionSub = LocationService.instance.watchPosition().listen((pos) {
        setState(() => _position = pos);
        // Walking updates the compass/distance labels via _position
        // above regardless; the (comparatively expensive) drops
        // re-fetch + list rebuild is throttled separately in
        // _fetchDrops so a stream of GPS ticks while the user is
        // scrolling doesn't stutter the feed.
        _fetchDrops(pos);
      });
    } catch (e) {
      if (_drops.isNotEmpty) {
        // Already showing cached drops — don't replace them with an
        // error screen, just note that this refresh didn't go through.
        setState(() => _offline = true);
      } else {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Re-fetches nearby drops, but skips the round trip (and, more
  /// importantly, the list rebuild it triggers) if we just fetched a
  /// few seconds ago, and skips the `setState` entirely if the result
  /// is unchanged from what's already on screen. `watchPosition` can
  /// tick every ~3s while walking; without this, every single tick was
  /// tearing down and rebuilding the whole visible list — including
  /// mid-scroll — which is what made the feed hang while scrolling.
  Future<void> _fetchDrops(geo.Position position, {bool force = false}) async {
    if (_fetchInFlight) return;
    final now = DateTime.now();
    if (!force &&
        _lastFetchAt != null &&
        now.difference(_lastFetchAt!) < Duration(seconds: 8)) {
      return;
    }
    _fetchInFlight = true;
    try {
      final drops = await SupabaseService.instance.fetchNearbyDrops(
        lat: position.latitude,
        lng: position.longitude,
      );
      _lastFetchAt = DateTime.now();
      if (mounted) {
        if (!_sameDrops(_drops, drops)) {
          setState(() { _drops = drops; _offline = false; });
        } else if (_offline) {
          setState(() => _offline = false);
        }
      }
      // Cache the data itself (not the media — that's disk-cached
      // separately, see cached_media.dart) so the next app open shows
      // these same posts instantly instead of waiting on a fresh
      // fetch, and still shows them at all if that fetch fails.
      await LocalCacheService.instance
          .saveList(_cacheKey, drops.map((d) => d.toMap()).toList());
    } catch (_) {
      if (mounted && _drops.isNotEmpty) setState(() => _offline = true);
    } finally {
      _fetchInFlight = false;
    }
  }

  /// Cheap equality check (id + lock state + rounded distance) — good
  /// enough to tell "nothing worth redrawing changed" apart from a
  /// real update, without deep-comparing every field.
  bool _sameDrops(List<Drop> a, List<Drop> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x.id != y.id ||
          x.isUnlocked != y.isUnlocked ||
          (x.distanceM / 5).round() != (y.distanceM / 5).round()) {
        return false;
      }
    }
    return true;
  }

  /// Drops actually shown on the feed. Locked drops are deliberately
  /// left out here — a feed full of blurred, unrevealed cards is a
  /// confusing first impression, especially for a brand-new account
  /// with nothing unlocked yet. Locked drops still exist and are still
  /// findable — just intentionally, by searching the person who left
  /// them and opening their profile — rather than cluttering this list.
  List<Drop> get _visibleDrops => _drops.where((d) => d.isUnlocked).toList();

  Future<void> _openUserSearch() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserSearchScreen(
          currentLat: _position?.latitude,
          currentLng: _position?.longitude,
        ),
      ),
    );
  }

  Future<void> _openDrop(Drop drop) async {
    if (_position == null) return;
    await Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, animation, __) => FadeTransition(
          opacity: animation,
          child: DropDetailScreen(
            drop: drop,
            currentLat: _position!.latitude,
            currentLng: _position!.longitude,
          ),
        ),
        transitionDuration: Duration(milliseconds: 300),
      ),
    );
    if (_position != null) await _fetchDrops(_position!, force: true);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          key: _scaffoldKey,
          backgroundColor: RMColors.background,
          drawer: const MessagesDrawer(),
          drawerEdgeDragWidth: 40,
          appBar: AppBar(
            backgroundColor: RMColors.background,
            leading: IconButton(
              icon: Icon(Icons.mail_outline_rounded),
              tooltip: 'Status & messages',
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Realm'),
                if (_section == 0 &&
                    (_position != null || (_offline && _drops.isNotEmpty)))
                  Text(
                    _offline
                        ? '${_visibleDrops.length} drops nearby · offline, showing saved posts'
                        : '${_visibleDrops.length} drops nearby',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
            actions: [
              IconButton(
                icon: Icon(Icons.search_rounded),
                tooltip: 'Find a user',
                onPressed: _openUserSearch,
              ),
              IconButton(
                icon: CircleAvatar(
                  radius: 14,
                  backgroundColor: RMColors.primaryDim,
                  backgroundImage: _avatarUrl != null
                      ? CachedNetworkImageProvider(_avatarUrl!)
                      : null,
                  child: _avatarUrl == null
                      ? Icon(Icons.person_rounded,
                          size: 16, color: RMColors.primary)
                      : null,
                ),
                onPressed: _openProfile,
              ),
            ],
          ),
          body: Column(
            children: [
              _buildSectionToggle(),
              Expanded(
                child: _section == 0
                    ? RefreshIndicator(
                        color: RMColors.primary,
                        backgroundColor: RMColors.surface,
                        onRefresh: _initLocation,
                        child: _buildBody(),
                      )
                    : UpdatesView(key: _updatesKey, onRedropped: _loadRedrops),
              ),
            ],
          ),
          floatingActionButton: _section == 0
              ? ScaleTransition(
                  scale: _fabScale,
                  child: FloatingActionButton.extended(
                    onPressed: () async {
                      if (_position == null) return;
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => CreateDropScreen(
                            lat: _position!.latitude,
                            lng: _position!.longitude,
                          ),
                        ),
                      );
                      if (_position != null) {
                        await _fetchDrops(_position!, force: true);
                      }
                    },
                    backgroundColor: RMColors.primary,
                    foregroundColor: Colors.white,
                    icon: Icon(Icons.add_location_alt_rounded),
                    label: Text('Drop here'),
                  ),
                )
              : null,
        ),
        if (_showTutorial)
          TutorialOverlay(
            steps: [
              TutorialStep(
                icon: Icons.explore_rounded,
                title: 'Welcome to Reality Merge',
                body: 'The world around you is full of hidden content. Walk to locked drops to reveal what people left behind.',
              ),
              TutorialStep(
                icon: Icons.lock_rounded,
                title: 'Locked drops',
                body: 'Drops show how far they are. Get close enough and tap to unlock — the content only reveals when you\'re physically there.',
              ),
              TutorialStep(
                icon: Icons.add_location_alt_rounded,
                title: 'Leave your mark',
                body: 'Tap "Drop here" to pin a photo, video, or message to your exact location. Set it public or private with a specific allowlist.',
              ),
            ],
            onDone: () async {
              await OnboardingService.instance.markFeedTutorialSeen();
              if (mounted) setState(() => _showTutorial = false);
            },
          ),
      ],
    );
  }

  /// Drops/Updates switch, styled to match the app's existing pill
  /// controls rather than the default Material segmented button —
  /// keeps this feeling like part of Realm rather than a bolted-on
  /// news reader.
  Widget _buildSectionToggle() {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Container(
        padding: EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: RMColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(child: _sectionTab('Drops', Icons.explore_rounded, 0)),
            Expanded(
                child: _sectionTab('Updates', Icons.public_rounded, 1)),
          ],
        ),
      ),
    );
  }

  Widget _sectionTab(String label, IconData icon, int index) {
    final selected = _section == index;
    return GestureDetector(
      onTap: () {
        if (_section == index) return;
        setState(() => _section = index);
        if (index == 0) _loadRedrops();
      },
      child: AnimatedContainer(
        duration: Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: selected ? RMColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 16,
                color: selected ? Colors.white : RMColors.textSecondary),
            SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : RMColors.textSecondary,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: RMColors.primary),
            SizedBox(height: 16),
            Text('Finding your location…',
                style: TextStyle(color: RMColors.textSecondary)),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.location_off_rounded,
                  color: RMColors.textHint, size: 48),
              SizedBox(height: 16),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: RMColors.textSecondary)),
              SizedBox(height: 20),
              OutlinedButton(
                  onPressed: _initLocation, child: Text('Try again')),
            ],
          ),
        ),
      );
    }
    final visible = _visibleDrops;

    if (visible.isEmpty && _redrops.isEmpty) {
      final hasLockedNearby = _drops.isNotEmpty;
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.location_on_outlined,
                        color: RMColors.textHint, size: 48),
                    SizedBox(height: 12),
                    Text('No drops nearby yet.',
                        style: TextStyle(
                            color: RMColors.textPrimary,
                            fontWeight: FontWeight.w600)),
                    SizedBox(height: 4),
                    Text(
                      hasLockedNearby
                          ? 'There are locked drops nearby — search for who left them to find them.'
                          : 'Be the first to leave something here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: RMColors.textSecondary),
                    ),
                    if (hasLockedNearby) ...[
                      SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: _openUserSearch,
                        icon: Icon(Icons.search_rounded),
                        label: Text('Find a user'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Redrops sit above the nearby-drop cards — they carry no
    // location/distance of their own, so they can't be sorted into
    // the same list by proximity; showing them first is what makes a
    // fresh redrop "automatically appear on the Drops tab" the moment
    // it happens, rather than requiring a scroll past every nearby
    // drop first.
    final redropCount = _redrops.length;
    final realCount = redropCount + visible.length;
    // One native ad slotted in after every _adInterval real feed
    // items (redrops + drops combined, in on-screen order) — never
    // before the first _adInterval, and never at all for a feed too
    // short to have a natural break in it. adCount here must agree
    // exactly with the isAdSlot/realIndex math in itemBuilder below,
    // or the two get out of sync and either crash on an out-of-range
    // index or silently drop a real item.
    const adInterval = 6;
    final adCount = realCount ~/ adInterval;
    final itemCount = realCount + adCount;

    return ListView.builder(
      physics: AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(16, 8, 16, 100),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        final isAdSlot = (index + 1) % (adInterval + 1) == 0;
        if (isAdSlot) {
          return NativeAdCard(key: ValueKey('ad_$index'));
        }
        final realIndex = index - (index ~/ (adInterval + 1));

        if (realIndex < redropCount) {
          final item = _redrops[realIndex];
          return Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: RedropFeedCard(
              key: ValueKey('redrop_${item.id}'),
              item: item,
              onOpenDetail: _openRedropDetail,
              onOpenComments: _openRedropComments,
              onOpenRedropSheet: _openRedropSheet,
            ),
          );
        }
        final drop = visible[realIndex - redropCount];
        return AnimatedDropCard(
          key: ValueKey(drop.id),
          drop: drop,
          index: realIndex - redropCount,
          onTap: () => _openDrop(drop),
        );
      },
    );
  }
}
