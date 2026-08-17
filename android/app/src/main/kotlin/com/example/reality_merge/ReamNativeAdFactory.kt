package com.example.reality_merge

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.RatingBar
import android.widget.TextView
import com.google.android.gms.ads.nativead.MediaView
import com.google.android.gms.ads.nativead.NativeAd
import com.google.android.gms.ads.nativead.NativeAdView
import io.flutter.plugins.googlemobileads.GoogleMobileAdsPlugin

/// Builds the entire visual tree for a native ad in code instead of
/// inflating an XML layout + findViewById.
///
/// That sidesteps the single most common native-ads crash in
/// Flutter/Android integrations: an XML layout id
/// (`findViewById(R.id.ad_headline)`, etc.) silently drifting out of
/// sync with what this factory expects — which throws a
/// NullPointerException the moment an ad actually loads, often only
/// in release builds once R8/resource shrinking has touched the
/// layout, which is exactly the kind of "works on my machine, crashes
/// in prod" bug that's painful to chase down. Every view reference
/// here is a real Kotlin `val`, not a lookup that can miss.
///
/// Registered under [factoryId] "realmFeedNativeAd" in
/// MainActivity.configureFlutterEngine — that string must match
/// AdConfig.nativeAdFactoryId on the Dart side exactly, or
/// NativeAd.load() just resolves through onAdFailedToLoad instead of
/// crashing (see native_ad_card.dart).
class ReamNativeAdFactory(private val context: Context) :
    GoogleMobileAdsPlugin.NativeAdFactory {

    override fun createNativeAd(
        nativeAd: NativeAd,
        customOptions: MutableMap<String, Any>?
    ): NativeAdView {
        val density = context.resources.displayMetrics.density
        fun dp(v: Int): Int = (v * density).toInt()

        // Colors mirror lib/theme/rm_theme.dart's dark palette
        // (RMColors.surface / .border / .textPrimary / .textSecondary)
        // since native views render outside Flutter and can't read
        // ThemeController at all — this deliberately doesn't attempt
        // to track a live light/dark toggle.
        val colorSurface = Color.parseColor("#13131A")
        val colorBorder = Color.parseColor("#2A2A3A")
        val colorTextPrimary = Color.WHITE
        val colorTextSecondary = Color.parseColor("#B4B4C6")
        val colorAccent = Color.parseColor("#5B5BF0")

        val adView = NativeAdView(context)

        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(12), dp(12), dp(12))
            setBackgroundColor(colorSurface)
        }

        // ── Header row: icon + headline + "Ad" badge ──
        val headerRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        val iconView = ImageView(context).apply {
            layoutParams = LinearLayout.LayoutParams(dp(40), dp(40))
            scaleType = ImageView.ScaleType.CENTER_CROP
        }
        headerRow.addView(iconView)

        val headlineView = TextView(context).apply {
            layoutParams = LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
            ).apply { marginStart = dp(10); marginEnd = dp(8) }
            setTextColor(colorTextPrimary)
            textSize = 15f
            typeface = Typeface.DEFAULT_BOLD
            maxLines = 2
        }
        headerRow.addView(headlineView)

        val adBadge = TextView(context).apply {
            text = "Ad"
            setTextColor(colorTextSecondary)
            textSize = 10f
            setPadding(dp(6), dp(2), dp(6), dp(2))
            setBackgroundColor(colorBorder)
        }
        headerRow.addView(adBadge)

        root.addView(headerRow)

        // ── Body text ──
        val bodyView = TextView(context).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(8) }
            setTextColor(colorTextSecondary)
            textSize = 13f
            maxLines = 2
        }
        root.addView(bodyView)

        // ── Media ──
        val mediaView = MediaView(context).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(180)
            ).apply { topMargin = dp(10) }
        }
        root.addView(mediaView)

        // ── Star rating (app-install ads only; hidden otherwise) ──
        val ratingBar = RatingBar(context, null, android.R.attr.ratingBarStyleSmall).apply {
            isEnabled = false
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(8) }
        }
        root.addView(ratingBar)

        // ── CTA button ──
        val ctaView = TextView(context).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(40)
            ).apply { topMargin = dp(10) }
            gravity = Gravity.CENTER
            setTextColor(colorTextPrimary)
            typeface = Typeface.DEFAULT_BOLD
            setBackgroundColor(colorAccent)
            // The click itself is handled by the SDK via
            // adView.callToActionView below, not by this view's own
            // click listener — leaving it non-clickable here avoids
            // fighting that internal wiring.
            isClickable = false
        }
        root.addView(ctaView)

        adView.addView(root)

        // Wire references so the SDK can track impressions and route
        // clicks/media playback correctly. This must happen before
        // adView.setNativeAd() below.
        adView.headlineView = headlineView
        adView.bodyView = bodyView
        adView.mediaView = mediaView
        adView.iconView = iconView
        adView.starRatingView = ratingBar
        adView.callToActionView = ctaView

        // ── Populate from the loaded ad ──
        headlineView.text = nativeAd.headline

        val body = nativeAd.body
        if (body != null) {
            bodyView.text = body
            bodyView.visibility = View.VISIBLE
        } else {
            bodyView.visibility = View.GONE
        }

        val icon = nativeAd.icon
        if (icon != null) {
            iconView.setImageDrawable(icon.drawable)
            iconView.visibility = View.VISIBLE
        } else {
            iconView.visibility = View.GONE
        }

        val rating = nativeAd.starRating
        if (rating != null) {
            ratingBar.rating = rating.toFloat()
            ratingBar.visibility = View.VISIBLE
        } else {
            ratingBar.visibility = View.GONE
        }

        val cta = nativeAd.callToAction
        if (cta != null) {
            ctaView.text = cta
            ctaView.visibility = View.VISIBLE
        } else {
            ctaView.visibility = View.GONE
        }

        adView.setNativeAd(nativeAd)

        return adView
    }
}
