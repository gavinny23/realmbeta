package com.example.reality_merge

import android.content.Context
import android.view.LayoutInflater
import android.widget.RatingBar
import com.google.android.gms.ads.nativead.NativeAd
import com.google.android.gms.ads.nativead.NativeAdView
import io.flutter.plugins.googlemobileads.GoogleMobileAdsPlugin

/// Renders a loaded [NativeAd] into res/layout/native_ad_card.xml —
/// the Android-side half of Dart's `AdWidget(factoryId: "realmFeedCard")`.
/// google_mobile_ads calls [createNativeAd] once per ad the Dart side
/// asks it to render; everything here is just wiring AdMob's asset
/// strings/views onto the views declared in that XML.
///
/// Image-only in practice: the test native-advanced ad unit (and any
/// real native-advanced unit under normal AdMob settings) only ever
/// serves image creatives here, so MediaView is enough — no separate
/// video-vs-image branching needed. Video ads are being handled
/// separately for the Flicks tab later.
class NativeAdFactoryImpl(private val context: Context) : GoogleMobileAdsPlugin.NativeAdFactory {

    override fun createNativeAd(
        nativeAd: NativeAd,
        customOptions: MutableMap<String, Any>?
    ): NativeAdView {
        val adView = LayoutInflater.from(context)
            .inflate(R.layout.native_ad_card, null) as NativeAdView

        val headlineView = adView.findViewById<android.widget.TextView>(R.id.ad_headline)
        val bodyView = adView.findViewById<android.widget.TextView>(R.id.ad_body)
        val advertiserView = adView.findViewById<android.widget.TextView>(R.id.ad_advertiser)
        val iconView = adView.findViewById<android.widget.ImageView>(R.id.ad_app_icon)
        val mediaView = adView.findViewById<com.google.android.gms.ads.nativead.MediaView>(R.id.ad_media)
        val ctaView = adView.findViewById<android.widget.Button>(R.id.ad_cta)
        val starsView = adView.findViewById<RatingBar>(R.id.ad_stars)

        // Headline is the one asset AdMob guarantees is always present.
        headlineView.text = nativeAd.headline
        adView.headlineView = headlineView

        if (nativeAd.body.isNullOrBlank()) {
            bodyView.visibility = android.view.View.GONE
        } else {
            bodyView.visibility = android.view.View.VISIBLE
            bodyView.text = nativeAd.body
        }
        adView.bodyView = bodyView

        adView.mediaView = mediaView
        nativeAd.mediaContent?.let { mediaView.mediaContent = it }

        val advertiser = nativeAd.advertiser ?: nativeAd.store
        if (advertiser.isNullOrBlank()) {
            advertiserView.visibility = android.view.View.GONE
        } else {
            advertiserView.visibility = android.view.View.VISIBLE
            advertiserView.text = advertiser
        }
        adView.advertiserView = advertiserView

        val icon = nativeAd.icon
        if (icon != null) {
            iconView.setImageDrawable(icon.drawable)
            iconView.visibility = android.view.View.VISIBLE
        } else {
            iconView.visibility = android.view.View.GONE
        }
        adView.iconView = iconView

        val rating = nativeAd.starRating
        if (rating != null && rating > 0) {
            starsView.rating = rating.toFloat()
            starsView.visibility = android.view.View.VISIBLE
        } else {
            starsView.visibility = android.view.View.GONE
        }
        adView.starRatingView = starsView

        if (nativeAd.callToAction.isNullOrBlank()) {
            ctaView.visibility = android.view.View.GONE
        } else {
            ctaView.visibility = android.view.View.VISIBLE
            ctaView.text = nativeAd.callToAction
        }
        // AdMob requires the CTA to be registered even when it's also
        // acting as a plain label — clicks anywhere AdMob has wired up
        // (which can include the whole card) route through this.
        adView.callToActionView = ctaView

        adView.setNativeAd(nativeAd)
        return adView
    }
}
