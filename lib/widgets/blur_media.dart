import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/data_saver_service.dart';
import '../theme/rm_theme.dart';

/// A soft, animated "blur-up" placeholder shown behind media while it
/// loads — a subtle pulsing gradient seen through a blur, classic
/// progressive-loading feel without needing a low-res thumbnail source.
class BlurPlaceholder extends StatefulWidget {
  final double? height;
  final IconData icon;

  BlurPlaceholder({super.key, this.height, this.icon = Icons.image_rounded});

  @override
  State<BlurPlaceholder> createState() => _BlurPlaceholderState();
}

class _BlurPlaceholderState extends State<BlurPlaceholder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    RMColors.surfaceAlt,
                    Color.lerp(RMColors.primaryDim, RMColors.surfaceAlt,
                        _ctrl.value)!,
                    RMColors.surfaceAlt,
                  ],
                ),
              ),
            ),
          ),
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Center(
              child: Icon(widget.icon,
                  size: 40, color: RMColors.textHint.withOpacity(0.6)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Wraps a network image with a blurred pulsing placeholder that
/// cross-fades into the loaded image once it arrives — the classic
/// "blur-up" progressive image loading pattern.
class BlurUpImage extends StatelessWidget {
  final String url;
  final double? height;
  final BoxFit fit;
  final BorderRadius borderRadius;
  /// Decodes the image at this pixel width instead of its native
  /// resolution — cheap way to cut memory/CPU cost for thumbnails that
  /// never render anywhere near full size (e.g. feed cards). Leave
  /// null for full-resolution decoding (detail screens, galleries).
  final int? cacheWidth;
  /// When true (and [fit] is BoxFit.contain), the empty space left by
  /// showing the full, uncropped image is filled with a blurred,
  /// darkened copy of the same image rather than a flat background —
  /// so every card is the same size without ever hiding part of the
  /// photo or video thumbnail, and the letterbox bars still look
  /// intentional instead of like empty gaps.
  final bool letterboxFill;
  /// Whether this image participates in the Data-saver "blur until
  /// downloaded" gate. Defaults on — turn off only for images that
  /// shouldn't ever be withheld (e.g. the person's own avatar).
  final bool gate;

  BlurUpImage({
    super.key,
    required this.url,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.cacheWidth,
    this.letterboxFill = false,
    this.gate = true,
  });

  @override
  Widget build(BuildContext context) {
    if (gate) {
      return DataSaverMediaGate(
        mediaKey: url,
        previewUrl: url,
        height: height,
        borderRadius: borderRadius,
        previewFit: fit,
        builder: (context) => _buildContent(context),
      );
    }
    return _buildContent(context);
  }

  Widget _buildContent(BuildContext context) {
    final foreground = CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      memCacheWidth: cacheWidth,
      fadeInDuration: Duration(milliseconds: 400),
      progressIndicatorBuilder: (context, url, progress) => Stack(
        fit: StackFit.expand,
        children: [
          BlurPlaceholder(height: height, icon: Icons.image_rounded),
          if (progress.progress != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: SizedBox(
                  width: 80,
                  child: LinearProgressIndicator(
                    value: progress.progress,
                    minHeight: 3,
                    backgroundColor: Colors.black26,
                    valueColor: AlwaysStoppedAnimation(RMColors.primary),
                  ),
                ),
              ),
            ),
        ],
      ),
      errorWidget: (context, url, error) => Container(
        height: height,
        color: RMColors.surfaceAlt,
        child: Center(
          child: Icon(Icons.broken_image_rounded,
              color: RMColors.textHint, size: 32),
        ),
      ),
    );

    return ClipRRect(
      borderRadius: borderRadius,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: letterboxFill
            ? Stack(
                fit: StackFit.expand,
                children: [
                  // Decorative backdrop only — small mem-cache width
                  // since it's blurred into a soft smear anyway, and
                  // its own load/error states don't matter, the
                  // foreground image above carries those.
                  ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                    child: CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      memCacheWidth: 120,
                    ),
                  ),
                  Container(color: Colors.black.withOpacity(0.28)),
                  Center(child: foreground),
                ],
              )
            : foreground,
      ),
    );
  }
}

/// Gates a piece of network media behind Data saver: while it's on and
/// this [mediaKey] hasn't been explicitly downloaded yet, shows the
/// media at the lowest quality possible (a heavily blurred, tiny
/// mem-cache decode of the same file — not a placeholder icon) with a
/// centered download button over it. Tapping the button unlocks that
/// key for the rest of the session and swaps in [builder]'s real
/// content.
///
/// When Data saver is off, or the media's already been unlocked, this
/// renders [builder] straight away with no gate at all.
///
/// [mediaKey] should be a stable, unique id for the file — the media
/// URL itself is almost always the right choice, since that's what
/// ties an "unlocked" decision to one specific file everywhere it
/// shows up (a feed card and its detail screen share the same URL, so
/// unlocking one unlocks the other too).
class DataSaverMediaGate extends StatefulWidget {
  final String mediaKey;
  final String previewUrl;
  final WidgetBuilder builder;
  final double? height;
  final BorderRadius borderRadius;
  final BoxFit previewFit;

  const DataSaverMediaGate({
    super.key,
    required this.mediaKey,
    required this.previewUrl,
    required this.builder,
    this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.previewFit = BoxFit.cover,
  });

  @override
  State<DataSaverMediaGate> createState() => _DataSaverMediaGateState();
}

class _DataSaverMediaGateState extends State<DataSaverMediaGate> {
  void _download() {
    DataSaverService.instance.unlock(widget.mediaKey);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: DataSaverService.instance,
      builder: (context, _) {
        final gated = DataSaverService.instance.enabled &&
            !DataSaverService.instance.isUnlocked(widget.mediaKey);
        if (!gated) return widget.builder(context);

        return ClipRRect(
          borderRadius: widget.borderRadius,
          child: SizedBox(
            height: widget.height,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // The real file, decoded at the smallest possible size
                // and heavily blurred — genuinely the lowest-quality
                // version of the actual image, not a generic stand-in.
                ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                  child: CachedNetworkImage(
                    imageUrl: widget.previewUrl,
                    fit: widget.previewFit,
                    memCacheWidth: 24,
                    errorWidget: (context, url, error) =>
                        BlurPlaceholder(height: widget.height),
                  ),
                ),
                Container(color: Colors.black.withOpacity(0.25)),
                Center(
                  child: GestureDetector(
                    onTap: _download,
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black45,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(
                        Icons.download_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
