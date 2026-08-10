import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import '../services/ad_service.dart';
import '../theme/rm_theme.dart';

/// One Native Advanced ad, dropped into the Updates/Drops feeds at a
/// fixed interval (see `updates_view.dart` / `feed_screen.dart`).
///
/// Loads its own ad independently the moment it's built — each slot
/// in the feed gets a fresh [NativeAd], which is the normal pattern
/// for native ads in a scrolling list (they can't be reused between
/// slots the way an image can). Renders nothing (zero height, no
/// placeholder box) if AdMob has nothing to fill, or on any platform
/// ads aren't wired up for, rather than leaving a dead gap in the
/// feed shaped like a failed load.
class NativeAdCard extends StatefulWidget {
  const NativeAdCard({super.key});

  @override
  State<NativeAdCard> createState() => _NativeAdCardState();
}

class _NativeAdCardState extends State<NativeAdCard>
    with AutomaticKeepAliveClientMixin {
  NativeAd? _ad;
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ad = await AdService.instance.loadNativeAd();
    if (!mounted) {
      ad?.dispose();
      return;
    }
    setState(() {
      _ad = ad;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return Container(
        height: 380,
        decoration: BoxDecoration(
          color: RMColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: RMColors.border, width: 1),
        ),
        alignment: Alignment.center,
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: RMColors.textHint,
          ),
        ),
      );
    }
    final ad = _ad;
    if (ad == null) return const SizedBox.shrink();
    return SizedBox(
      height: 380,
      child: AdWidget(ad: ad),
    );
  }
}
