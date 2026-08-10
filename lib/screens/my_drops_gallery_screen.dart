import 'package:flutter/material.dart';
import '../models/drop.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/blur_media.dart';
import 'drop_detail_screen.dart';

/// A grid gallery of every drop the current user has made, reached by
/// tapping the "Dropped" stat card on their own profile. Every tile
/// runs through the same cached-image system as the rest of the app
/// (BlurUpImage/CachedNetworkImage) so thumbnails that have already
/// been viewed once render instantly offline.
class MyDropsGalleryScreen extends StatefulWidget {
  const MyDropsGalleryScreen({super.key});

  @override
  State<MyDropsGalleryScreen> createState() => _MyDropsGalleryScreenState();
}

class _MyDropsGalleryScreenState extends State<MyDropsGalleryScreen> {
  List<Drop> _drops = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final drops = await SupabaseService.instance.fetchMyDrops();
      if (mounted) setState(() => _drops = drops);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openDrop(Drop drop) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DropDetailScreen(
          drop: drop,
          // It's always your own drop here, already unlocked — the
          // detail screen just needs *some* coordinate pair to render
          // distance/map context with, so reuse the drop's own
          // location rather than requesting a fresh GPS fix just to
          // look at something you already dropped.
          currentLat: drop.dropLat ?? 0,
          currentLng: drop.dropLng ?? 0,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        title: Text('Dropped'),
        backgroundColor: RMColors.background,
      ),
      body: RefreshIndicator(
        color: RMColors.primary,
        backgroundColor: RMColors.surface,
        onRefresh: _load,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: RMColors.primary));
    }
    if (_error != null) {
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: RMColors.textSecondary)),
              ),
            ),
          ),
        ),
      );
    }
    if (_drops.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_location_alt_rounded,
                      color: RMColors.textHint, size: 48),
                  SizedBox(height: 12),
                  Text('No drops yet.',
                      style: TextStyle(
                          color: RMColors.textPrimary,
                          fontWeight: FontWeight.w600)),
                  SizedBox(height: 4),
                  Text('Everything you drop shows up here.',
                      style: TextStyle(color: RMColors.textSecondary)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return GridView.builder(
      physics: AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.all(10),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
        childAspectRatio: 1,
      ),
      itemCount: _drops.length,
      itemBuilder: (context, i) => _GalleryTile(
        drop: _drops[i],
        onTap: () => _openDrop(_drops[i]),
      ),
    );
  }
}

/// A single square gallery cell — deliberately BoxFit.cover, unlike
/// the feed cards. A dense grid overview is expected to crop to a
/// uniform square (this is the classic profile-grid convention); the
/// full, uncropped media is always one tap away in DropDetailScreen.
class _GalleryTile extends StatelessWidget {
  final Drop drop;
  final VoidCallback onTap;

  const _GalleryTile({required this.drop, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final media = drop.mediaItems.isNotEmpty
        ? drop.mediaItems.first
        : (drop.mediaUrl != null && drop.mediaType != null
            ? DropMediaItem(
                url: drop.mediaUrl!,
                type: drop.mediaType!,
                sizeBytes: drop.mediaSizeBytes)
            : null);

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _tileMedia(media),
            if (media?.type == DropMediaType.video)
              IgnorePointer(
                child: Center(
                  child: Icon(Icons.play_circle_fill_rounded,
                      color: Colors.white.withOpacity(0.92), size: 26),
                ),
              ),
            if (drop.isRestricted)
              Positioned(
                top: 5,
                right: 5,
                child: Icon(
                  drop.isPrivate
                      ? Icons.lock_rounded
                      : Icons.group_rounded,
                  color: Colors.white,
                  size: 15,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tileMedia(DropMediaItem? media) {
    if (media == null) {
      return Container(
        color: RMColors.surfaceAlt,
        child: Center(
          child: Icon(Icons.add_location_alt_rounded,
              color: RMColors.textHint, size: 26),
        ),
      );
    }
    switch (media.type) {
      case DropMediaType.photo:
        return BlurUpImage(
          url: media.url,
          fit: BoxFit.cover,
          borderRadius: BorderRadius.zero,
          cacheWidth: 360,
        );
      case DropMediaType.video:
        return media.thumbUrl != null
            ? BlurUpImage(
                url: media.thumbUrl!,
                fit: BoxFit.cover,
                borderRadius: BorderRadius.zero,
                cacheWidth: 360,
              )
            : Container(
                color: RMColors.surfaceAlt,
                child: Center(
                  child: Icon(Icons.videocam_rounded,
                      color: RMColors.textHint, size: 26),
                ),
              );
      case DropMediaType.document:
        return Container(
          color: RMColors.surfaceAlt,
          child: Center(
            child: Icon(Icons.insert_drive_file_rounded,
                color: RMColors.textHint, size: 26),
          ),
        );
    }
  }
}
