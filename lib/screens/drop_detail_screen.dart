import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../models/drop.dart';
import '../services/supabase_service.dart';
import '../services/drop_events.dart';
import '../services/cached_media.dart';
import '../services/data_saver_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/blur_media.dart';
import 'reactions_screen.dart';

class DropDetailScreen extends StatefulWidget {
  final Drop drop;
  final double currentLat;
  final double currentLng;

  DropDetailScreen({
    super.key,
    required this.drop,
    required this.currentLat,
    required this.currentLng,
  });

  @override
  State<DropDetailScreen> createState() => _DropDetailScreenState();
}

class _DropDetailScreenState extends State<DropDetailScreen> {
  bool _unlocking = false;
  bool _deleting = false;
  String? _error;
  late bool _unlocked;
  int _galleryIndex = 0;
  final _pageCtrl = PageController();

  bool get _isOwner =>
      SupabaseService.instance.currentUser?.id == widget.drop.creatorId;

  @override
  void initState() {
    super.initState();
    _unlocked = widget.drop.isUnlocked;
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    setState(() {
      _unlocking = true;
      _error = null;
    });
    try {
      final success = await SupabaseService.instance.attemptUnlock(
        dropId: widget.drop.id,
        lat: widget.currentLat,
        lng: widget.currentLng,
      );
      if (success) {
        setState(() => _unlocked = true);
      } else {
        setState(() => _error =
            'Still too far away — get within ${widget.drop.unlockRadiusM}m.');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _unlocking = false);
    }
  }

  /// Every attachment on this drop, falling back to the single legacy
  /// media field for drops created before multi-file support existed.
  List<DropMediaItem> get _media {
    final drop = widget.drop;
    if (drop.mediaItems.isNotEmpty) return drop.mediaItems;
    if (drop.mediaUrl != null && drop.mediaType != null) {
      return [
        DropMediaItem(
          url: drop.mediaUrl!,
          type: drop.mediaType!,
          sizeBytes: drop.mediaSizeBytes,
        ),
      ];
    }
    return [];
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: RMColors.surface,
        title: Text('Delete this drop?'),
        content: Text(
            'This removes it for everyone, permanently. This can\'t be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete', style: TextStyle(color: RMColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _deleting = true);
    try {
      await SupabaseService.instance.deleteDrop(widget.drop.id);
      DropEvents.instance.notifyDropCreated();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _deleting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't delete: $e")),
        );
      }
    }
  }

  Future<void> _openOrDownload(String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't open that link.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final drop = widget.drop;
    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        title: Text('Drop'),
        backgroundColor: RMColors.background,
        actions: [
          if (_isOwner)
            _deleting
                ? Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: RMColors.danger),
                    ),
                  )
                : IconButton(
                    icon: Icon(Icons.delete_outline_rounded,
                        color: RMColors.danger),
                    tooltip: 'Delete drop',
                    onPressed: _confirmDelete,
                  ),
        ],
      ),
      body: !_unlocked ? _buildLocked(drop) : _buildUnlocked(drop),
    );
  }

  // ── Locked state ──────────────────────────────────────────────────────

  Widget _buildLocked(Drop drop) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: RMColors.surfaceAlt,
                shape: BoxShape.circle,
                border: Border.all(color: RMColors.border),
              ),
              child: Icon(Icons.lock_outline_rounded,
                  size: 36, color: RMColors.textSecondary),
            ),
            SizedBox(height: 20),
            Text(
              'This Drop is locked.',
              style: TextStyle(
                  color: RMColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 8),
            Text(drop.distanceLabel,
                style: TextStyle(
                    color: RMColors.textSecondary, fontSize: 13)),
            SizedBox(height: 4),
            Text('Get within ${drop.unlockRadiusM}m to unlock',
                style: TextStyle(
                    color: RMColors.textHint, fontSize: 12)),
            SizedBox(height: 28),
            if (_error != null)
              Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(_error!,
                    style: TextStyle(color: RMColors.danger)),
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _unlocking ? null : _unlock,
                child: _unlocking
                    ? SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text('Try to unlock'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Unlocked state ────────────────────────────────────────────────────

  Widget _buildUnlocked(Drop drop) {
    final media = _media;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 19,
                backgroundColor: RMColors.primaryDim,
                child: Icon(Icons.person_rounded,
                    size: 20, color: RMColors.primary),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(drop.creatorUsername,
                        style: TextStyle(
                            color: RMColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700)),
                    SizedBox(height: 1),
                    Row(
                      children: [
                        Text(
                          DateFormat('MMM d, y').format(drop.createdAt),
                          style: TextStyle(
                              color: RMColors.textHint, fontSize: 12),
                        ),
                        if (drop.isRestricted) ...[
                          SizedBox(width: 6),
                          Text('·', style: TextStyle(color: RMColors.textHint)),
                          SizedBox(width: 6),
                          Icon(Icons.lock_rounded,
                              size: 11, color: RMColors.primary),
                          SizedBox(width: 3),
                          Text(
                              drop.isCustom
                                  ? 'Shared with specific people'
                                  : 'Private drop',
                              style: TextStyle(
                                  color: RMColors.primary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          if (media.isNotEmpty) ...[
            _MediaGallery(
              items: media,
              controller: _pageCtrl,
              index: _galleryIndex,
              onPageChanged: (i) => setState(() => _galleryIndex = i),
              allowDownload: drop.allowDownload,
              onOpenOrDownload: _openOrDownload,
            ),
            SizedBox(height: 16),
          ],
          Text(
            drop.caption ?? '',
            style: TextStyle(
                color: RMColors.textPrimary, fontSize: 16, height: 1.5),
          ),
          SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ReactionsScreen(dropId: drop.id),
                ),
              ),
              icon: Icon(Icons.favorite_border_rounded, size: 18),
              label: Text('Reactions & Comments'),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Media gallery ──────────────────────────────────────────────────────────

class _MediaGallery extends StatelessWidget {
  final List<DropMediaItem> items;
  final PageController controller;
  final int index;
  final ValueChanged<int> onPageChanged;
  final bool allowDownload;
  final Future<void> Function(String url) onOpenOrDownload;

  _MediaGallery({
    required this.items,
    required this.controller,
    required this.index,
    required this.onPageChanged,
    required this.allowDownload,
    required this.onOpenOrDownload,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 260,
            child: PageView.builder(
              controller: controller,
              itemCount: items.length,
              onPageChanged: onPageChanged,
              itemBuilder: (context, i) => _MediaTile(
                item: items[i],
                allowDownload: allowDownload,
                onOpenOrDownload: onOpenOrDownload,
              ),
            ),
          ),
        ),
        if (items.length > 1) ...[
          SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < items.length; i++)
                AnimatedContainer(
                  duration: Duration(milliseconds: 200),
                  margin: EdgeInsets.symmetric(horizontal: 3),
                  width: i == index ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == index ? RMColors.primary : RMColors.border,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _MediaTile extends StatelessWidget {
  final DropMediaItem item;
  final bool allowDownload;
  final Future<void> Function(String url) onOpenOrDownload;

  _MediaTile({
    required this.item,
    required this.allowDownload,
    required this.onOpenOrDownload,
  });

  @override
  Widget build(BuildContext context) {
    switch (item.type) {
      case DropMediaType.photo:
        return Stack(
          fit: StackFit.expand,
          children: [
            BlurUpImage(
              url: item.url,
              height: 260,
              borderRadius: BorderRadius.zero,
            ),
            if (allowDownload)
              _DownloadFab(onTap: () => onOpenOrDownload(item.url)),
          ],
        );
      case DropMediaType.video:
        return _VideoTile(
          item: item,
          allowDownload: allowDownload,
          onOpenOrDownload: onOpenOrDownload,
        );
      case DropMediaType.document:
        return _DocumentTile(
          item: item,
          allowDownload: allowDownload,
          onOpenOrDownload: onOpenOrDownload,
        );
    }
  }
}

class _DownloadFab extends StatelessWidget {
  final VoidCallback onTap;
  _DownloadFab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 10,
      top: 10,
      child: Material(
        color: Colors.black.withOpacity(0.55),
        shape: CircleBorder(),
        child: InkWell(
          customBorder: CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(9),
            child: Icon(Icons.download_rounded, color: Colors.white, size: 18),
          ),
        ),
      ),
    );
  }
}

// ── Video ────────────────────────────────────────────────────────────────

class _VideoTile extends StatefulWidget {
  final DropMediaItem item;
  final bool allowDownload;
  final Future<void> Function(String url) onOpenOrDownload;

  _VideoTile({
    required this.item,
    required this.allowDownload,
    required this.onOpenOrDownload,
  });

  @override
  State<_VideoTile> createState() => _VideoTileState();
}

class _VideoTileState extends State<_VideoTile> {
  VideoPlayerController? _controller;
  bool _initializing = true;
  bool _failed = false;

  bool get _gated =>
      DataSaverService.instance.enabled &&
      !DataSaverService.instance.isUnlocked(widget.item.url);

  @override
  void initState() {
    super.initState();
    // Data saver: don't pull the actual video file until the person
    // taps to download it — same gate photos go through, just applied
    // before the network request even starts instead of after.
    if (!_gated) _init();
  }

  void _downloadNow() {
    DataSaverService.instance.unlock(widget.item.url);
    setState(() {});
    _init();
  }

  Future<void> _init() async {
    final cachedFile = await CachedMedia.resolve(widget.item.url);
    final controller = cachedFile != null
        ? VideoPlayerController.file(cachedFile)
        : VideoPlayerController.networkUrl(Uri.parse(widget.item.url));
    try {
      await controller.initialize();
      await controller.setLooping(true);
      // video_player only decodes and uploads a frame to its texture
      // once playback has actually started — right after initialize()
      // the texture is blank, so the "thumbnail" is just a black box
      // until the person taps play. Kick off a play/pause cycle here so
      // the first frame is rendered and paused immediately, giving a
      // real thumbnail instead of a flash of black.
      await controller.play();
      await controller.pause();
      await controller.seekTo(Duration.zero);
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _initializing = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _failed = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    setState(() {
      c.value.isPlaying ? c.pause() : c.play();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: DataSaverService.instance,
      builder: (context, _) {
        if (_gated) {
          return Stack(
            fit: StackFit.expand,
            children: [
              BlurPlaceholder(icon: Icons.videocam_rounded),
              Center(
                child: GestureDetector(
                  onTap: _downloadNow,
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black45,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(Icons.download_rounded,
                        color: Colors.white, size: 26),
                  ),
                ),
              ),
            ],
          );
        }
        return _buildPlayer(context);
      },
    );
  }

  Widget _buildPlayer(BuildContext context) {
    if (_initializing) {
      return Stack(
        fit: StackFit.expand,
        children: [
          BlurPlaceholder(icon: Icons.videocam_rounded),
          Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                  strokeWidth: 2.4, color: RMColors.primary),
            ),
          ),
        ],
      );
    }

    if (_failed || _controller == null) {
      return Container(
        color: RMColors.surfaceAlt,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded,
                  color: RMColors.textHint, size: 36),
              SizedBox(height: 8),
              Text("Couldn't load video",
                  style: TextStyle(color: RMColors.textSecondary)),
              if (widget.allowDownload) ...[
                SizedBox(height: 10),
                TextButton(
                  onPressed: () => widget.onOpenOrDownload(widget.item.url),
                  child: Text('Open externally'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final c = _controller!;
    return GestureDetector(
      onTap: _togglePlay,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: c.value.size.width,
              height: c.value.size.height,
              child: VideoPlayer(c),
            ),
          ),
          AnimatedOpacity(
            opacity: c.value.isPlaying ? 0 : 1,
            duration: Duration(milliseconds: 200),
            child: Container(
              color: Colors.black26,
              child: Center(
                child: Icon(Icons.play_circle_fill_rounded,
                    color: Colors.white, size: 56),
              ),
            ),
          ),
          if (widget.allowDownload)
            _DownloadFab(onTap: () => widget.onOpenOrDownload(widget.item.url)),
        ],
      ),
    );
  }
}

// ── Document ────────────────────────────────────────────────────────────

class _DocumentTile extends StatefulWidget {
  final DropMediaItem item;
  final bool allowDownload;
  final Future<void> Function(String url) onOpenOrDownload;

  _DocumentTile({
    required this.item,
    required this.allowDownload,
    required this.onOpenOrDownload,
  });

  @override
  State<_DocumentTile> createState() => _DocumentTileState();
}

class _DocumentTileState extends State<_DocumentTile> {
  bool _preparing = true;

  @override
  void initState() {
    super.initState();
    // A brief, deliberate "preparing document" beat behind the blur
    // placeholder — mirrors the blur-up feel of the image/video tiles
    // even though there's no real thumbnail to fade in from.
    Future.delayed(Duration(milliseconds: 500), () {
      if (mounted) setState(() => _preparing = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_preparing) {
      return BlurPlaceholder(icon: Icons.insert_drive_file_rounded);
    }

    final ext = widget.item.name?.split('.').last.toUpperCase() ?? 'FILE';
    return Container(
      color: RMColors.surfaceAlt,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: RMColors.primaryDim,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Center(
                child: Text(ext,
                    style: TextStyle(
                        color: RMColors.primary,
                        fontWeight: FontWeight.w800,
                        fontSize: 13)),
              ),
            ),
            SizedBox(height: 12),
            Text(
              widget.item.name ?? 'Attached document',
              style: TextStyle(
                  color: RMColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (widget.item.sizeLabel != null)
              Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text(widget.item.sizeLabel!,
                    style: TextStyle(
                        color: RMColors.textSecondary, fontSize: 11)),
              ),
            SizedBox(height: 14),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  onPressed: () => widget.onOpenOrDownload(widget.item.url),
                  icon: Icon(Icons.open_in_new_rounded, size: 15),
                  label: Text('Open'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: Size(0, 38),
                      padding: EdgeInsets.symmetric(horizontal: 14)),
                ),
                if (widget.allowDownload) ...[
                  SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: () => widget.onOpenOrDownload(widget.item.url),
                    icon: Icon(Icons.download_rounded, size: 15),
                    label: Text('Download'),
                    style: FilledButton.styleFrom(
                        minimumSize: Size(0, 38),
                        padding: EdgeInsets.symmetric(horizontal: 14)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
