/// Compile-time secrets, injected via --dart-define at build time.
/// Never read from a bundled asset file — dart-define values are
/// baked into the binary as constants, not shipped as a readable
/// file inside the APK/IPA/web bundle.
class EnvConfig {
  EnvConfig._();

  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY');
  static const String mapboxAccessToken =
      String.fromEnvironment('MAPBOX_ACCESS_TOKEN');
  static const String openaiApiKey = String.fromEnvironment('OPENAI_API_KEY');
  static const String auddApiKey = String.fromEnvironment('AUDD_API_KEY');
  static const String admobNativeAdUnitId =
      String.fromEnvironment('ADMOB_NATIVE_AD_UNIT_ID');
}
