import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import '../services/ad_service.dart';
import '../theme/rm_theme.dart';

/// A native ad slotted into the Drops feed (see FeedScreenState._buildList),
/// styled to sit alongside [AnimatedDropCard]/[RedropFeedCard] without
/// pretending to be one — the "Ad" label the native factory renders
/// (ReamNativeAdFactory.kt) keeps that honest per AdMob policy.
///
/// Every failure mode here — SDK not initialized yet, load timeout,
/// load error — collapses to the same outcome: this widget renders
/// nothing. A feed with an occasional missing ad slot reads as
/// normal; a feed with a broken-looking placeholder box does not, and
/// there's no situation where surfacing "this ad failed" helps
/// anyone. Give this a stable ValueKey per slot from the caller so a
/// pull-to-refresh rebuild doesn't tear down and reload every ad
/// already on screen.
class NativeAdCard extends StatefulWidget {
  const NativeAdCard({super.key});

  @override
  State<NativeAdCard> createState() => _NativeAdCardState();
}

class _NativeAdCardState extends State<NativeAdCard> {
  NativeAd? _ad;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // AdService.init() is fire-and-forget from main.dart's bootstrap,
    // so by the time a feed card actually scrolls into view it's
    // almost always already resolved one way or the other — but if
    // it hasn't, this gives it one more short chance rather than
    // permanently giving up on every ad slot for the rest of the
    // session just because this particular card mounted early.
    if (!AdService.instance.ready) {
      await AdService.instance.init();
    }
    if (!AdService.instance.ready || !mounted) return;

    final ad = NativeAd(
      adUnitId: AdConfig.nativeAdUnitId,
      factoryId: AdConfig.nativeAdFactoryId,
      request: const AdRequest(),
      listener: NativeAdListener(
        onAdLoaded: (loadedAd) {
          if (!mounted) {
            loadedAd.dispose();
            return;
          }
          setState(() => _ad = loadedAd as NativeAd);
        },
        onAdFailedToLoad: (loadedAd, error) {
          loadedAd.dispose();
          // Deliberately no setState/error UI — see class doc.
        },
      ),
    );

    try {
      await ad.load();
    } catch (_) {
      ad.dispose();
    }
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (ad == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(
          color: RMColors.surface,
          border: Border.all(color: RMColors.border),
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        constraints: const BoxConstraints(minHeight: 280),
        child: AdWidget(ad: ad),
      ),
    );
  }
}
