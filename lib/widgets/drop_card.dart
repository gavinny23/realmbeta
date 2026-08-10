import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../models/drop.dart';
import '../services/geocoding_service.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../screens/reactions_screen.dart';
import '../screens/drop_redrop_sheet.dart';
import 'media_thumbnail.dart';

/// The single visual representation of a drop, shared by every place a
/// drop can be listed (the Explore feed, the Compass tab's nearby list,
/// etc.) so a drop looks and behaves identically no matter where you
/// found it — same media thumbnail (including video frames), same
/// location badge, same lock/unlock affordance.
class DropCard extends StatefulWidget {
  final Drop drop;
  final VoidCallback onTap;

  const DropCard({super.key, required this.drop, required this.onTap});

  @override
  State<DropCard> createState() => _DropCardState();
}

class _DropCardState extends State<DropCard> {
  String? _placeLabel;

  // Like/comment/redrop state — only meaningful (and only fetched)
  // once the drop is actually unlocked, since a locked card has no
  // revealed content to react to yet.
  int _likeCount = 0;
  bool _hasLiked = false;
  int _commentCount = 0;
  int _redropCount = 0;
  bool _hasRedropped = false;

  // ─── Attached music playback ────────────────────────────────────
  // Only one card plays at a time across the whole app — starting a
  // second one stops whichever was already going, same as a normal
  // feed (TikTok/Instagram) rather than letting tracks overlap.
  static _DropCardState? _activePlayer;
  AudioPlayer? _audioPlayer;
  bool _musicLoaded = false;
  bool _musicPlaying = false;

  @override
  void initState() {
    super.initState();
    _resolveLocation();
    _loadInteractions();
  }

  @override
  void didUpdateWidget(covariant DropCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.drop.id != widget.drop.id) {
      _placeLabel = null;
      _resolveLocation();
      _loadInteractions();
      _pauseMusic();
      _musicLoaded = false;
    }
  }

  @override
  void dispose() {
    if (_activePlayer == this) _activePlayer = null;
    _audioPlayer?.dispose();
    super.dispose();
  }

  /// Toggles the attached music clip. Starting playback here stops
  /// whichever other card was playing, so only one track is ever
  /// audible at once.
  Future<void> _toggleMusic() async {
    final drop = widget.drop;
    if (!drop.hasMusic) return;

    if (_musicPlaying) {
      await _pauseMusic();
      return;
    }

    if (_activePlayer != null && _activePlayer != this) {
      await _activePlayer!._pauseMusic();
    }

    final player = _audioPlayer ??= AudioPlayer();
    try {
      if (!_musicLoaded) {
        await player.setUrl(drop.musicUrl!);
        await player.setLoopMode(LoopMode.one);
        _musicLoaded = true;
      }
      await player.play();
      _activePlayer = this;
      if (mounted) setState(() => _musicPlaying = true);
    } catch (_) {
      // Best-effort — a track that fails to load just stays silent
      // rather than crashing the card.
    }
  }

  Future<void> _pauseMusic() async {
    await _audioPlayer?.pause();
    if (_activePlayer == this) _activePlayer = null;
    if (mounted) setState(() => _musicPlaying = false);
  }

  Future<void> _loadInteractions() async {
    final drop = widget.drop;
    if (!drop.isUnlocked) return;
    try {
      final currentUser = SupabaseService.instance.currentUser;
      final results = await Future.wait([
        SupabaseService.instance.fetchInteractions(dropId: drop.id),
        SupabaseService.instance.fetchDropRedropCount(drop.id),
        SupabaseService.instance.fetchMyDropRedrop(drop.id),
      ]);
      if (!mounted) return;
      final interactions = results[0] as List<Map<String, dynamic>>;
      setState(() {
        _likeCount = interactions.where((i) => i['type'] == 'like').length;
        _hasLiked = interactions.any(
            (i) => i['type'] == 'like' && i['user_id'] == currentUser?.id);
        _commentCount =
            interactions.where((i) => i['type'] == 'comment').length;
        _redropCount = results[1] as int;
        _hasRedropped = (results[2] as Map<String, dynamic>?) != null;
      });
    } catch (_) {
      // Best-effort — a card that fails to load counts just shows
      // zeros rather than blocking the rest of the feed.
    }
  }

  Future<void> _toggleLike() async {
    final drop = widget.drop;
    final wasLiked = _hasLiked;
    setState(() {
      _hasLiked = !wasLiked;
      _likeCount += wasLiked ? -1 : 1;
    });
    try {
      if (wasLiked) {
        await SupabaseService.instance.removeLike(dropId: drop.id);
      } else {
        await SupabaseService.instance.addLike(dropId: drop.id);
      }
    } catch (_) {
      // Roll back the optimistic update if the write failed.
      if (mounted) {
        setState(() {
          _hasLiked = wasLiked;
          _likeCount += wasLiked ? 1 : -1;
        });
      }
    }
  }

  Future<void> _openComments() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => ReactionsScreen(dropId: widget.drop.id)),
    );
    // Counts may have changed while the comments screen was open.
    _loadInteractions();
  }

  Future<void> _openRedrop() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: RMColors.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DropRedropSheet(drop: widget.drop),
    );
    if (result != null) _loadInteractions();
  }

  /// Best-effort place name for the location badge on top of the post.
  /// Falls back silently to the distance label if this never resolves
  /// (offline, rate-limited, etc.) — see _locationText.
  Future<void> _resolveLocation() async {
    final drop = widget.drop;
    if (drop.dropLat == null || drop.dropLng == null) return;
    final label = await GeocodingService.instance
        .reverseGeocode(drop.dropLat!, drop.dropLng!);
    if (mounted && label != null) setState(() => _placeLabel = label);
  }

  String get _locationText {
    final drop = widget.drop;
    // Locked drops intentionally keep their exact location a mystery —
    // only the distance is meaningful until the drop is unlocked.
    if (!drop.isUnlocked) return drop.distanceLabel;
    return _placeLabel ?? drop.distanceLabel;
  }

  @override
  Widget build(BuildContext context) {
    final drop = widget.drop;
    final locked = !drop.isUnlocked;
    final canUnlock = drop.isWithinUnlockRange && locked;
    final media = drop.mediaItems.isNotEmpty
        ? drop.mediaItems.first
        : (drop.mediaUrl != null && drop.mediaType != null
            ? DropMediaItem(
                url: drop.mediaUrl!,
                type: drop.mediaType!,
                sizeBytes: drop.mediaSizeBytes)
            : null);

    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: RMColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: canUnlock
                ? RMColors.accent.withOpacity(0.6)
                : drop.isUnlocked
                    ? RMColors.success.withOpacity(0.3)
                    : RMColors.border,
            width: canUnlock ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Location badge — always on top of the post ──────────
            Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(
                children: [
                  Icon(Icons.location_on_rounded,
                      size: 15,
                      color: locked ? RMColors.textHint : RMColors.primary),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _locationText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color:
                            locked ? RMColors.textHint : RMColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (locked && drop.isRestricted) ...[
                    Container(
                      padding:
                          EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: RMColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        '${drop.unlockRadiusM}m radius',
                        style: TextStyle(
                            color: RMColors.textSecondary,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3),
                      ),
                    ),
                    SizedBox(width: 6),
                  ],
                  if (drop.isRestricted)
                    Container(
                      padding:
                          EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: RMColors.primaryDim,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        drop.visibilityLabel,
                        style: TextStyle(
                            color: RMColors.primary,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5),
                      ),
                    ),
                ],
              ),
            ),

            // ── Media thumbnail ───────────────────────────────────────
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Stack(
                children: [
                  MediaThumbnailPreview(
                    item: media,
                    locked: locked,
                    height: 260,
                  ),
                  if (!locked && drop.hasMusic)
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: _MusicToggleButton(
                        playing: _musicPlaying,
                        onTap: _toggleMusic,
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(height: 14),

            // ── Caption + meta + unlock affordance ────────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: locked
                          ? RMColors.surfaceAlt
                          : RMColors.success.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      locked
                          ? (canUnlock
                              ? Icons.lock_open_rounded
                              : Icons.lock_rounded)
                          : Icons.lock_open_rounded,
                      color: locked
                          ? (canUnlock ? RMColors.accent : RMColors.textHint)
                          : RMColors.success,
                      size: 19,
                    ),
                  ),
                  SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          locked ? 'Locked drop' : (drop.caption ?? ''),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: locked
                                ? RMColors.textSecondary
                                : RMColors.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            fontStyle:
                                locked ? FontStyle.italic : FontStyle.normal,
                          ),
                        ),
                        if (!locked) ...[
                          SizedBox(height: 3),
                          Text('by ${drop.creatorUsername}',
                              style: Theme.of(context).textTheme.bodySmall),
                          if (drop.hasMusic) ...[
                            SizedBox(height: 3),
                            Row(
                              children: [
                                Icon(Icons.music_note_rounded,
                                    size: 13, color: RMColors.textHint),
                                SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    drop.musicLabel!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: RMColors.textHint,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                  if (canUnlock)
                    Container(
                      padding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: RMColors.accent.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: RMColors.accent.withOpacity(0.4)),
                      ),
                      child: Text(
                        'Unlock',
                        style: TextStyle(
                            color: RMColors.accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w700),
                      ),
                    )
                  else
                    Icon(Icons.chevron_right_rounded,
                        color: RMColors.textHint),
                ],
              ),
            ),

            // ── Like / comment / redrop row — only once content is
            // actually revealed; a locked card has nothing to react to.
            if (drop.isUnlocked) ...[
              Divider(height: 1, color: RMColors.border),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    _ActionButton(
                      icon: _hasLiked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: _hasLiked ? RMColors.danger : null,
                      label: _likeCount > 0 ? '$_likeCount' : 'Like',
                      onTap: _toggleLike,
                    ),
                    _ActionButton(
                      icon: Icons.mode_comment_outlined,
                      label: _commentCount > 0 ? '$_commentCount' : 'Comment',
                      onTap: _openComments,
                    ),
                    _ActionButton(
                      icon: Icons.repeat_rounded,
                      color: _hasRedropped ? RMColors.success : null,
                      label: _redropCount > 0 ? '$_redropCount' : 'Redrop',
                      onTap: _openRedrop,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The bottom-right speaker button overlaid on a drop's media — muted
/// (crossed-out speaker) by default, switches to an animated "playing"
/// look once tapped. Mirrors the mute affordance from video-first feeds
/// (TikTok/Instagram) but for a music clip attached to a photo/video.
class _MusicToggleButton extends StatelessWidget {
  final bool playing;
  final VoidCallback onTap;

  const _MusicToggleButton({required this.playing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Duration(milliseconds: 150),
        padding: EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.55),
          shape: BoxShape.circle,
          border: Border.all(
            color: playing
                ? RMColors.primary.withOpacity(0.8)
                : Colors.white.withOpacity(0.4),
            width: 1.2,
          ),
        ),
        child: Icon(
          playing ? Icons.volume_up_rounded : Icons.volume_off_rounded,
          color: Colors.white,
          size: 18,
        ),
      ),
    );
  }
}

/// One entry in the like/comment/redrop row — icon + count/label,
/// tappable, sharing the same compact footprint so all three sit
/// evenly across the card regardless of which has a number yet.
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: color ?? RMColors.textSecondary),
              SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: color ?? RMColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Animated entrance wrapper (fade + slight upward slide, staggered by
/// list index) around a [DropCard] — shared by the Explore feed and the
/// Compass tab's nearby list so both lists animate in identically.
class AnimatedDropCard extends StatefulWidget {
  final Drop drop;
  final int index;
  final VoidCallback onTap;

  const AnimatedDropCard({
    super.key,
    required this.drop,
    required this.index,
    required this.onTap,
  });

  @override
  State<AnimatedDropCard> createState() => _AnimatedDropCardState();
}

class _AnimatedDropCardState extends State<AnimatedDropCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 350 + widget.index * 60),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: Offset(0, 0.12),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    Future.delayed(Duration(milliseconds: widget.index * 60), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: DropCard(drop: widget.drop, onTap: widget.onTap),
        ),
      ),
    );
  }
}
