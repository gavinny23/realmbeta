import 'package:flutter/material.dart';
import '../models/drop.dart';
import '../services/data_saver_service.dart';
import '../theme/rm_theme.dart';
import 'blur_media.dart';

/// A compact preview of a drop's first attachment for use in feed cards.
/// - Locked drops (or drops with no media) show a blurred lock placeholder.
/// - Photos use the existing blur-up progressive loader.
/// - Videos show the pre-generated static thumbnail frame (uploaded
///   alongside the video — see [DropMediaItem.thumbUrl]) with a small
///   play badge. This is deliberately NOT a real video player: spinning
///   up a `VideoPlayerController` (which opens a network connection and
///   buffers) for every video card that scrolls into view is what used
///   to make the feed hang while scrolling. A drop with no thumbnail
///   yet (older drops, uploaded before this existed) falls back to a
///   plain icon tile rather than paying that cost.
/// - Documents show a generic file tile.
class MediaThumbnailPreview extends StatelessWidget {
  final DropMediaItem? item;
  final bool locked;
  final double height;
  final BorderRadius borderRadius;

  const MediaThumbnailPreview({
    super.key,
    required this.item,
    required this.locked,
    this.height = 160,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
  });

  @override
  Widget build(BuildContext context) {
    final media = item;
    if (locked || media == null) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: BlurPlaceholder(
          height: height,
          icon: locked ? Icons.lock_rounded : Icons.location_on_rounded,
        ),
      );
    }

    switch (media.type) {
      case DropMediaType.photo:
        return BlurUpImage(
          url: media.url,
          height: height,
          borderRadius: borderRadius,
          // Every card shows the full photo, uncropped — a portrait
          // shot next to a landscape one still gets the exact same
          // card height, just with the difference absorbed as a
          // blurred letterbox instead of chopping off part of either.
          fit: BoxFit.contain,
          letterboxFill: true,
          // Feed cards never render wider than the screen, so there's
          // no reason to decode a multi-megapixel photo at full
          // resolution just to show a ~350dp-wide card.
          cacheWidth: 900,
        );
      case DropMediaType.video:
        return ClipRRect(
          borderRadius: borderRadius,
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: media.thumbUrl != null
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      BlurUpImage(
                        url: media.thumbUrl!,
                        height: height,
                        borderRadius: BorderRadius.zero,
                        fit: BoxFit.contain,
                        letterboxFill: true,
                        cacheWidth: 900,
                      ),
                      // The gate inside BlurUpImage already puts a
                      // download button front and center while this
                      // thumbnail is blurred — showing the play badge
                      // too would stack two competing icons on top of
                      // each other, so it only appears once the frame
                      // is actually visible.
                      AnimatedBuilder(
                        animation: DataSaverService.instance,
                        builder: (context, _) {
                          final gated = DataSaverService.instance.enabled &&
                              !DataSaverService.instance
                                  .isUnlocked(media.thumbUrl!);
                          if (gated) return const SizedBox.shrink();
                          return IgnorePointer(
                            child: Center(
                              child: Icon(Icons.play_circle_fill_rounded,
                                  color: Colors.white.withOpacity(0.92),
                                  size: 40),
                            ),
                          );
                        },
                      ),
                    ],
                  )
                : Container(
                    color: RMColors.surfaceAlt,
                    child: Center(
                      child: Icon(Icons.videocam_rounded,
                          color: RMColors.textHint, size: 32),
                    ),
                  ),
          ),
        );
      case DropMediaType.document:
        return ClipRRect(
          borderRadius: borderRadius,
          child: Container(
            height: height,
            width: double.infinity,
            color: RMColors.surfaceAlt,
            child: Center(
              child: Icon(Icons.insert_drive_file_rounded,
                  color: RMColors.textHint, size: 36),
            ),
          ),
        );
    }
  }
}
