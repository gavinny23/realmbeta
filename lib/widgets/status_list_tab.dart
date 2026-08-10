import 'package:flutter/material.dart';
import '../models/status_post.dart';
import '../services/supabase_service.dart';
import '../services/local_cache_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/presence_avatar.dart';
import '../screens/create_status_screen.dart';
import '../screens/status_viewer_screen.dart';

/// Vertical, WhatsApp-Status-tab-style list of "who has an active
/// status right now" — replaces the old horizontal strip. Lives
/// inside the Status tab of [MessagesDrawer]. Same cache-first +
/// background-refresh contract as the other feeds (see
/// [LocalCacheService]), and exposes [StatusListTabState.refresh] so
/// the drawer can force a re-check every time the tab is opened.
class StatusListTab extends StatefulWidget {
  const StatusListTab({super.key});

  @override
  State<StatusListTab> createState() => StatusListTabState();
}

class StatusListTabState extends State<StatusListTab> {
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
      // if nothing was cached either, an empty list rather than an
      // error for something this secondary).
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
    if (_loading && _entries.isEmpty) {
      return Center(child: CircularProgressIndicator(color: RMColors.primary));
    }

    final others = _others;
    final mine = _myEntry;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        _StatusRow(
          leading: _RingAvatar(
            avatarUrl: mine?.creatorAvatarUrl,
            filled: mine != null && !mine.allViewed,
            showRing: mine != null,
            addBadge: true,
          ),
          title: 'My status',
          subtitle: mine == null
              ? 'Tap to add status update'
              : mine.timeAgoLabel,
          onTap: mine == null ? _openCreate : () => _openViewer(mine.creatorId),
        ),
        if (others.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
            child: Text(
              'Recent updates',
              style: TextStyle(
                color: RMColors.textSecondary,
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
          ),
          for (final entry in others)
            _StatusRow(
              leading: _RingAvatar(
                avatarUrl: entry.creatorAvatarUrl,
                filled: !entry.allViewed,
                lastActiveAt: entry.creatorLastActiveAt,
              ),
              title: entry.creatorUsername,
              subtitle: entry.timeAgoLabel,
              onTap: () => _openViewer(entry.creatorId),
            ),
        ] else if (mine != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('No other updates right now',
                  style: TextStyle(color: RMColors.textSecondary)),
            ),
          ),
      ],
    );
  }
}

class _RingAvatar extends StatelessWidget {
  final String? avatarUrl;
  final bool filled; // true = unviewed (bright ring), false = all seen (dim ring)
  final bool showRing;
  final bool addBadge;
  final DateTime? lastActiveAt;

  const _RingAvatar({
    required this.avatarUrl,
    required this.filled,
    this.showRing = true,
    this.addBadge = false,
    this.lastActiveAt,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 48,
          height: 48,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: showRing
                ? Border.all(
                    color: filled ? RMColors.primary : RMColors.border,
                    width: 2,
                  )
                : null,
          ),
          child: PresenceAvatar(
            radius: 21,
            backgroundColor: RMColors.primaryDim,
            avatarUrl: avatarUrl,
            lastActiveAt: lastActiveAt,
            placeholder: Icon(Icons.person_rounded, color: RMColors.primary, size: 20),
          ),
        ),
        if (addBadge)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: RMColors.primary,
                border: Border.all(color: RMColors.surface, width: 2),
              ),
              child: const Icon(Icons.add_rounded, color: Colors.white, size: 12),
            ),
          ),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  final Widget leading;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _StatusRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: RMColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: RMColors.textSecondary, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
