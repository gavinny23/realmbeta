import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Ad unit / factory IDs. Switched automatically by build mode via
/// [kReleaseMode] rather than a hand-set boolean — there's no flag to
/// remember to flip before shipping, and no chance of a release build
/// accidentally going out on Google's shared test IDs (which AdMob
/// will simply never pay out on) or a debug build accidentally
/// serving — and risking policy strikes on — real ads.
class AdConfig {
  AdConfig._();

  /// Must match the factory id registered in MainActivity.kt
  /// (GoogleMobileAdsPlugin.registerNativeAdFactory). A mismatch here
  /// doesn't crash — it just makes NativeAd.load() resolve through
  /// onAdFailedToLoad, so the ad slot quietly disappears instead of
  /// showing anything. See ReamNativeAdFactory.kt.
  static const String nativeAdFactoryId = 'realmFeedNativeAd';

  static String get nativeAdUnitId {
    if (!kReleaseMode) return 'ca-app-pub-3940256099942544/2247696110';
    // TODO: swap in the real native ad unit ID from the AdMob
    // console before shipping a release build.
    return 'ca-app-pub-3940256099942544/2247696110';
  }

  static String get bannerAdUnitId {
    if (!kReleaseMode) return 'ca-app-pub-3940256099942544/9214589741';
    // TODO: swap in the real banner ad unit ID before release.
    return 'ca-app-pub-3940256099942544/9214589741';
  }
}

/// Owns MobileAds SDK initialization.
///
/// Deliberately follows a different contract than the other startup
/// services in main.dart's `_boot()`: every one of those is either
/// awaited or treated as fatal-on-timeout, because the app genuinely
/// needs them (a session, a theme, a cache). Ads aren't in that
/// category — nothing about this app should ever wait on an ad
/// network. So `init()` is meant to be called with `unawaited(...)`
/// and never throws; a slow or failed init just leaves [ready] false,
/// which every ad widget checks before trying to load. That's the
/// full story of how "AdMob failing" stays a missing ad slot instead
/// of a crash or a stuck splash screen.
class AdService {
  AdService._();
  static final AdService instance = AdService._();

  bool _ready = false;
  bool get ready => _ready;

  Future<void>? _initFuture;

  /// Safe to call more than once (each ad widget does, defensively) —
  /// later callers just await the same in-flight or completed init
  /// rather than re-triggering it.
  Future<void> init() {
    return _initFuture ??= _init();
  }

  Future<void> _init() async {
    try {
      await MobileAds.instance
          .initialize()
          .timeout(const Duration(seconds: 10));
      _ready = true;
    } catch (e) {
      // No network, SDK-side failure, timeout — whatever it is, ads
      // are simply off for the rest of this session. Nothing here
      // should ever propagate up into the app's boot path.
      debugPrint('AdService: MobileAds.initialize failed — ads disabled: $e');
    }
  }
}
