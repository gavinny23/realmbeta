import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Palette ────────────────────────────────────────────────────────────────
// Two palettes — the original deep-space dark UI, and a matching light
// variant — with the same electric-violet/amber personality carried
// across both. RMColors fields are *not* compile-time constants: they're
// plain static fields that ThemeController repoints whenever the person
// switches modes, so every screen that reads e.g. `RMColors.background`
// picks up the new value the next time it rebuilds, without every screen
// needing to know about Theme.of(context) or a provider.
class _Palette {
  final Color background;
  final Color surface;
  final Color surfaceAlt;
  final Color border;
  final Color primary;
  final Color primaryDim;
  final Color accent;
  final Color danger;
  final Color success;
  final Color mention;
  final Color textPrimary;
  final Color textSecondary;
  final Color textHint;

  const _Palette({
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.primary,
    required this.primaryDim,
    required this.accent,
    required this.danger,
    required this.success,
    required this.mention,
    required this.textPrimary,
    required this.textSecondary,
    required this.textHint,
  });
}

// Deep space dark UI, electric violet as the primary accent, amber as
// the discovery/unlock signal color. Inspired by satellite imagery at
// night — city grids glowing.
const _darkPalette = _Palette(
  background: Color(0xFF0A0A0F), // near-black with blue cast
  surface: Color(0xFF13131A), // card surfaces
  surfaceAlt: Color(0xFF1C1C27), // elevated surfaces
  border: Color(0xFF2A2A3A), // subtle borders
  primary: Color(0xFF7B61FF), // electric violet
  primaryDim: Color(0xFF3D2FA0), // dimmed violet for bg
  accent: Color(0xFFFFB830), // amber — unlock signal
  danger: Color(0xFFFF4D6D), // errors
  success: Color(0xFF00E5A0), // unlocked state
  mention: Color(0xFF4FA3FF), // @mention highlight
  textPrimary: Color(0xFFF0F0F8),
  textSecondary: Color(0xFF8888A8),
  textHint: Color(0xFF44445A),
);

// Bright, paper-white counterpart. Same accent hues, deepened slightly
// where needed to keep contrast on a light background.
const _lightPalette = _Palette(
  background: Color(0xFFF6F6FA), // soft off-white
  surface: Color(0xFFFFFFFF),
  surfaceAlt: Color(0xFFEDEDF4), // elevated surfaces
  border: Color(0xFFE0E0EA), // subtle borders
  primary: Color(0xFF6A4FE0), // electric violet, deepened for contrast
  primaryDim: Color(0xFFE8E2FC), // light violet tint for backgrounds
  accent: Color(0xFFC97C00), // amber, deepened — unlock signal
  danger: Color(0xFFD8324F), // errors, deepened
  success: Color(0xFF00966F), // unlocked state, deepened
  mention: Color(0xFF1D6FE0), // @mention highlight, deepened for contrast
  textPrimary: Color(0xFF15151E),
  textSecondary: Color(0xFF5B5B72),
  textHint: Color(0xFF9C9CAE),
);

class RMColors {
  RMColors._();

  static Color background = _darkPalette.background;
  static Color surface = _darkPalette.surface;
  static Color surfaceAlt = _darkPalette.surfaceAlt;
  static Color border = _darkPalette.border;

  static Color primary = _darkPalette.primary;
  static Color primaryDim = _darkPalette.primaryDim;
  static Color accent = _darkPalette.accent;
  static Color danger = _darkPalette.danger;
  static Color success = _darkPalette.success;
  static Color mention = _darkPalette.mention;

  static Color textPrimary = _darkPalette.textPrimary;
  static Color textSecondary = _darkPalette.textSecondary;
  static Color textHint = _darkPalette.textHint;

  static void _apply(_Palette p) {
    background = p.background;
    surface = p.surface;
    surfaceAlt = p.surfaceAlt;
    border = p.border;
    primary = p.primary;
    primaryDim = p.primaryDim;
    accent = p.accent;
    danger = p.danger;
    success = p.success;
    mention = p.mention;
    textPrimary = p.textPrimary;
    textSecondary = p.textSecondary;
    textHint = p.textHint;
  }
}

// ─── Theme mode controller ──────────────────────────────────────────────────
// Persisted light/dark/system preference. RMColors is repointed to the
// right palette every time the mode changes (including live system
// brightness changes while in "system" mode) and listeners are notified
// so the app can rebuild.
class ThemeController extends ChangeNotifier with WidgetsBindingObserver {
  ThemeController._() {
    WidgetsBinding.instance.addObserver(this);
  }

  static final ThemeController instance = ThemeController._();
  static const _prefsKey = 'rm_theme_mode';

  ThemeMode _mode = ThemeMode.dark;
  ThemeMode get mode => _mode;

  bool get isDark {
    if (_mode == ThemeMode.system) {
      final platformBrightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      return platformBrightness == Brightness.dark;
    }
    return _mode == ThemeMode.dark;
  }

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey);
      _mode = switch (saved) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark, // preserves the app's original look by default
      };
    } catch (_) {
      // Prefs unavailable for some reason — just keep the default.
    }
    RMColors._apply(isDark ? _darkPalette : _lightPalette);
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    RMColors._apply(isDark ? _darkPalette : _lightPalette);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, mode.name);
    } catch (_) {
      // Non-fatal — the mode just won't survive a restart.
    }
  }

  @override
  void didChangePlatformBrightness() {
    if (_mode == ThemeMode.system) {
      RMColors._apply(isDark ? _darkPalette : _lightPalette);
      notifyListeners();
    }
  }
}

// ─── Theme ──────────────────────────────────────────────────────────────────
class RMTheme {
  RMTheme._();

  static ThemeData get dark => _themeFor(_darkPalette, Brightness.dark);
  static ThemeData get light => _themeFor(_lightPalette, Brightness.light);

  static ThemeData _themeFor(_Palette c, Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: c.background,
      colorScheme: brightness == Brightness.dark
          ? ColorScheme.dark(
              surface: c.surface,
              primary: c.primary,
              secondary: c.accent,
              error: c.danger,
              onSurface: c.textPrimary,
              onPrimary: Colors.white,
              outline: c.border,
            )
          : ColorScheme.light(
              surface: c.surface,
              primary: c.primary,
              secondary: c.accent,
              error: c.danger,
              onSurface: c.textPrimary,
              onPrimary: Colors.white,
              outline: c.border,
            ),
      cardTheme: CardThemeData(
        color: c.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: c.border, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.background,
        foregroundColor: c.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: c.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: c.surface,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.surface,
        indicatorColor: c.primaryDim,
        labelTextStyle: WidgetStateProperty.all(
          TextStyle(fontSize: 11, color: c.textSecondary),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceAlt,
        labelStyle: TextStyle(color: c.textSecondary),
        hintStyle: TextStyle(color: c.textHint),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.primary, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.primary,
          side: BorderSide(color: c.primary),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          minimumSize: const Size(0, 48),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: c.surfaceAlt,
        selectedColor: c.primaryDim,
        labelStyle: TextStyle(color: c.textPrimary, fontSize: 13),
        side: BorderSide(color: c.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      textTheme: TextTheme(
        displayMedium: TextStyle(
          color: c.textPrimary,
          fontSize: 32,
          fontWeight: FontWeight.w800,
          letterSpacing: -1.0,
        ),
        headlineMedium: TextStyle(
          color: c.textPrimary,
          fontSize: 24,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        titleLarge: TextStyle(
          color: c.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        titleMedium: TextStyle(
          color: c.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(
          color: c.textPrimary,
          fontSize: 15,
          height: 1.5,
        ),
        bodyMedium: TextStyle(
          color: c.textSecondary,
          fontSize: 13,
          height: 1.4,
        ),
        bodySmall: TextStyle(
          color: c.textSecondary,
          fontSize: 11,
          letterSpacing: 0.2,
        ),
        labelSmall: TextStyle(
          color: c.textHint,
          fontSize: 10,
          letterSpacing: 0.5,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
