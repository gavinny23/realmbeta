# Add project specific ProGuard rules here.
# Flutter's own defaults (getDefaultProguardFile) already handle the
# Flutter engine itself — these are extra rules for common plugins used
# in this project so release (minified) builds don't crash at runtime.

# Keep Play Core / deferred components classes Flutter references
# reflectively (safe to keep even if you don't use split APKs).
-keep class com.google.android.play.core.** { *; }
-dontwarn com.google.android.play.core.**

# Supabase / Gotrue / Realtime use Kotlin serialization + reflection.
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
-keep class io.supabase.** { *; }
-keep class kotlinx.serialization.** { *; }
-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Mapbox
-keep class com.mapbox.** { *; }
-dontwarn com.mapbox.**

# AdMob / Google Mobile Ads (google_mobile_ads) — the native ad
# factory (ReamNativeAdFactory.kt) and the SDK's own reflective
# lookups need these kept, or a minified release build crashes on
# the first ad load / init instead of the debug build you tested.
-keep class com.google.android.gms.ads.** { *; }
-keep class com.google.ads.** { *; }
-keep interface com.google.android.gms.ads.** { *; }
-keep class io.flutter.plugins.googlemobileads.** { *; }
-dontwarn com.google.android.gms.ads.**

# OkHttp / Retrofit (transitively used by several plugins)
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }

# Gson (if any dependency uses it for JSON)
-keepattributes Signature
-keep class com.google.gson.** { *; }
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer

# Keep your app's model classes if you rely on reflection-based
# (de)serialization anywhere — uncomment and adjust the package if so:
# -keep class com.yourcompany.realm.models.** { *; }
