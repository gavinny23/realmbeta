import 'package:flutter/material.dart';
import '../models/status_post.dart';
import '../services/supabase_service.dart';
import '../services/local_cache_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/presence_avatar.dart';
import '../screens/create_status_screen.dart';
import '../screens/status_viewer_screen.dart';

/// Horizontal row of "who has an active status right now" — the
/// IG/WhatsApp-style strip. Loads and refreshes itself independently
/// of whatever screen embeds it (same cache-first + background-refresh
/// contract as the other feeds — see [LocalCacheService]), and exposes
/// [StatusStripState.refresh] so a host screen can force a re-check,
/// e.g. every time its own tab is reselected.
class StatusStrip extends StatefulWidget {
  const StatusStrip({super.key});

  @override
  State<StatusStrip> createState() => StatusStripState();
}

class StatusStripState extends State<StatusStrip> {
  static const _cacheKey = 'status_feed';

  List<StatusFeedEntry> _entries = [];
  bool _loading = true;

  String? get _myId => SupabaseService.instance.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> refresh() => _load();

  Future<void> _load() async {
    final cached = await LocalCacheService.instance.loadList(_cacheKey);
    if (cached != null && mounted) {
      setState(() {
        _entries = cached.map(StatusFeedEntry.fromMap).toList();
        _loading = false;
      });
    }

    try {
      final entries = await SupabaseService.instance.fetchStatusFeed();
      if (mounted) setState(() { _entries = entries; _loading = false; });
      await LocalCacheService.instance
          .saveList(_cacheKey, entries.map((e) => e.toMap()).toList());
    } catch (_) {
      // Offline or failed — just keep showing whatever's cached (or,
      // if nothing was cached either, the strip quietly stays empty
      // rather than showing an error for something this secondary).
      if (mounted) setState(() => _loading = false);
    }
  }

  StatusFeedEntry? get _myEntry {
    final id = _myId;
    if (id == null) return null;
    for (final e in _entries) {
      if (e.creatorId == id) return e;
    }
    return null;
  }

  List<StatusFeedEntry> get _others =>
      _entries.where((e) => e.creatorId != _myId).toList();

  Future<void> _openViewer(String creatorId) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StatusViewerScreen(creatorId: creatorId),
      ),
    );
    _load();
  }

  Future<void> _openCreate() async {
    final posted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const CreateStatusScreen()),
    );
    if (posted == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    // Nothing worth showing yet and nothing cached — rather than a
    // strip of skeleton loaders for a feature nobody's posted to yet,
    // just show the "add yours" bubble alone once loading settles.
    if (_loading && _entries.isEmpty) {
      return const SizedBox(height: 100);
    }

    final others = _others;
    final mine = _myEntry;

    return SizedBox(
      height: 100,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          _OwnBubble(
            entry: mine,
            onTap: mine == null ? _openCreate : () => _openViewer(mine.creatorId),
            onAddMore: mine == null ? null : _openCreate,
          ),
          for (final entry in others)
            _StatusBubble(
              entry: entry,
              onTap: () => _openViewer(entry.creatorId),
            ),
        ],
      ),
    );
  }
}

class _RingAvatar extends StatelessWidget {
  final String? avatarUrl;
  final bool filled; // true = unviewed (bright ring), false = all seen (dim ring)
  final bool showRing;

  /// Left null for [_OwnBubble] — that bubble already uses the
  /// bottom-right corner for its "+" add-more button, so it doesn't
  /// get a presence badge there too. [_StatusBubble] (everyone else's
  /// stories) passes it through.
  final DateTime? lastActiveAt;

  const _RingAvatar({
    required this.avatarUrl,
    required this.filled,
    this.showRing = true,
    this.lastActiveAt,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 62,
      height: 62,
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: showRing
            ? Border.all(
                color: filled ? RMColors.primary : RMColors.border,
                width: 2.5,
              )
            : null,
      ),
      child: PresenceAvatar(
        radius: 27,
        backgroundColor: RMColors.primaryDim,
        avatarUrl: avatarUrl,
        lastActiveAt: lastActiveAt,
        placeholder: Icon(Icons.person_rounded, color: RMColors.primary, size: 26),
      ),
    );
  }
}

class _StatusBubble extends StatelessWidget {
  final StatusFeedEntry entry;
  final VoidCallback onTap;

  const _StatusBubble({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: SizedBox(
          width: 68,
          child: Column(
            children: [
              _RingAvatar(
                avatarUrl: entry.creatorAvatarUrl,
                filled: !entry.allViewed,
                lastActiveAt: entry.creatorLastActiveAt,
              ),
              const SizedBox(height: 4),
              Text(
                entry.creatorUsername,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OwnBubble extends StatelessWidget {
  final StatusFeedEntry? entry;
  final VoidCallback onTap;
  final VoidCallback? onAddMore;

  const _OwnBubble({required this.entry, required this.onTap, this.onAddMore});

  @override
  Widget build(BuildContext context) {
    final hasStatus = entry != null;
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: SizedBox(
          width: 68,
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  _RingAvatar(
                    avatarUrl: entry?.creatorAvatarUrl,
                    filled: hasStatus && !entry!.allViewed,
                    showRing: hasStatus,
                  ),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: GestureDetector(
                      onTap: onAddMore ?? onTap,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: RMColors.primary,
                          border: Border.all(
                              color: RMColors.background, width: 2),
                        ),
                        child: const Icon(Icons.add_rounded,
                            color: Colors.white, size: 15),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Your status',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
