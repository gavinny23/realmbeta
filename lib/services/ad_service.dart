import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../config/env_config.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Native Advanced ads for the Updates and Drops feeds. Video native
/// ads for the Flicks tab are a separate, later piece of work — this
/// only ever requests image creatives (see [loadNativeAd]).
///
/// Follows the same singleton + `init()`-at-boot pattern as the other
/// services in this folder (see `DataSaverService`): [init] is called
/// once from `main.dart`'s boot sequence, and is safe to call more
/// than once.
///
/// Ad unit IDs default to Google's public *test* IDs (safe to ship —
/// they only ever serve clearly-labeled test creatives, never real
/// ads or real revenue). To go live, set `ADMOB_NATIVE_AD_UNIT_ID` in
/// `.env` to the real native-advanced ad unit ID from the AdMob
/// console, and swap the App ID in AndroidManifest.xml too (see the
/// comment there).
class AdService {
  AdService._();
  static final AdService instance = AdService._();

  /// Must match the factoryId `MainActivity.kt` registers via
  /// `GoogleMobileAdsPlugin.registerNativeAdFactory` (see
  /// `NativeAdFactoryImpl.kt`).
  static const nativeFactoryId = 'realmFeedCard';

  // Google's official test ad-unit ID for Native Advanced — always
  // available, always returns fill, never real inventory.
  static const _testNativeAdUnitId = 'ca-app-pub-3940256099942544/2247696110';

  bool _initialized = false;
  bool _available = false;

  /// False before [init] runs, on any platform this hasn't been wired
  /// up for (there's no `ios/` project in this app yet), or if SDK
  /// init itself failed — callers check this instead of needing to
  /// catch platform exceptions everywhere an ad card would go.
  bool get available => _available;

  String get _nativeAdUnitId {
    final fromEnv = EnvConfig.admobNativeAdUnitId;
    if (fromEnv.trim().isNotEmpty) return fromEnv.trim();
    return _testNativeAdUnitId;
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    if (!Platform.isAndroid) return;
    try {
      await MobileAds.instance.initialize();
      _available = true;
    } catch (e) {
      _available = false;
      debugPrint('AdService: MobileAds init failed — ads disabled ($e)');
    }
  }

  /// Loads one Native Advanced ad, image creative only (no video asset
  /// is requested, so AdMob won't hand back a video-backed native ad
  /// here — that's a separate Flicks-tab feature to add later).
  ///
  /// Returns null on failure. Callers should treat that as "no ad
  /// here" rather than an error — a failed fill is routine (no
  /// network, no inventory for this device/region, etc.), not
  /// exceptional.
  Future<NativeAd?> loadNativeAd() async {
    if (!_available) return null;
    final completer = Completer<NativeAd?>();
    final ad = NativeAd(
      adUnitId: _nativeAdUnitId,
      factoryId: nativeFactoryId,
      request: const AdRequest(),
      nativeAdOptions: NativeAdOptions(
        adChoicesPlacement: AdChoicesPlacement.topRightCorner,
        mediaAspectRatio: MediaAspectRatio.landscape,
      ),
      listener: NativeAdListener(
        onAdLoaded: (ad) {
          if (!completer.isCompleted) completer.complete(ad as NativeAd);
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          debugPrint('AdService: native ad failed to load — $error');
          if (!completer.isCompleted) completer.complete(null);
        },
      ),
    );
    await ad.load();
    return completer.future;
  }

  // ─── Feed ad-slot interleaving ──────────────────────────────────
  // Shared by UpdatesView (news) and FeedScreen (drops) so both tabs
  // insert ads on the same rhythm and the math only lives in one
  // place. One ad after every [feedAdInterval] content items — e.g.
  // with the default of 6: items 0-5 are content, item 6 is an ad,
  // items 7-12 are content, item 13 is an ad, and so on. A trailing
  // group that doesn't reach a full 6 content items just doesn't get
  // a trailing ad, rather than showing one early.

  static const feedAdInterval = 6;

  /// Total list length (content + inserted ad slots) for [contentCount]
  /// real items.
  static int itemCountWithAds(int contentCount,
      {int interval = feedAdInterval}) {
    if (contentCount <= 0) return contentCount;
    final numAds = contentCount ~/ interval;
    return contentCount + numAds;
  }

  /// Whether list position [position] (0-based, within the
  /// content+ads region only — after any fixed banners) is an ad slot
  /// rather than a content item.
  static bool isAdSlot(int position, {int interval = feedAdInterval}) {
    final groupSize = interval + 1;
    return (position + 1) % groupSize == 0;
  }

  /// Maps a content+ads list position to the index into the original
  /// (ad-free) content list. Only meaningful when [isAdSlot] is false
  /// for the same position.
  static int contentIndexForSlot(int position,
      {int interval = feedAdInterval}) {
    final groupSize = interval + 1;
    final adsBefore = (position + 1) ~/ groupSize;
    return position - adsBefore;
  }
}
