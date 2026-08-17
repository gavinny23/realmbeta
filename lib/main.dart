import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/auth_gate.dart';
import 'screens/splash_screen.dart';
import 'services/account_manager_service.dart';
import 'services/ad_service.dart';
import 'services/advanced_features_service.dart';
import 'services/cheat_code_service.dart';
import 'services/data_saver_service.dart';
import 'services/privacy_settings_sync_service.dart';
import 'services/profile_fields_sync_service.dart';
import 'services/push_notification_service.dart';
import 'services/sms_gateway_bridge.dart';
import 'theme/rm_theme.dart';

/// Handles a data-only FCM message that arrives while the app is fully
/// backgrounded or terminated. Must be a top-level (or static)
/// function, not a method or closure — FCM invokes this in its own
/// background isolate, which has no access to any state from the main
/// isolate at all, only whatever this function sets up itself via
/// [PushNotificationService.showFromBackground].
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await PushNotificationService.instance.showFromBackground(message);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Call runApp() immediately, before any of the async setup below —
  // that's what lets Flutter start painting our own branded splash
  // screen right away instead of leaving the plain native launch
  // screen up for the whole duration of that setup.
  runApp(RealityMergeApp());
}

class RealityMergeApp extends StatefulWidget {
  RealityMergeApp({super.key});

  @override
  State<RealityMergeApp> createState() => _RealityMergeAppState();
}

class _RealityMergeAppState extends State<RealityMergeApp> {
  late Future<void> _bootstrap = _boot();
  String? _bootstrapError;

  Future<void> _boot() async {
    final startedAt = DateTime.now();
    try {
      await dotenv.load(fileName: '.env');
      await ThemeController.instance.init();
      await DataSaverService.instance.init();
      await AdvancedFeaturesService.instance.init();
      // Supabase.initialize() is the one step here that can genuinely
      // hang rather than fail: if this device already has a saved
      // session, it tries to restore/refresh it over the network, and
      // that call has no timeout of its own. On a slow or flaky
      // connection that means it can just sit there indefinitely —
      // which is exactly what made the splash screen "sometimes work,
      // sometimes not" depending on whatever the network happened to
      // be doing at that moment. Capping it here turns that into a
      // clear, retryable error instead of an unbounded hang.
      //
      // Note that .timeout() only stops *waiting* on the call — it
      // doesn't cancel the underlying initialize(), which can still
      // go on to complete successfully in the background after we've
      // given up on it. If that happens and the person taps "Try
      // again", a second initialize() call would throw ("already
      // initialized") purely because the first one quietly finished
      // late — so that specific error is treated as success here
      // rather than surfaced as a fresh failure.
      try {
        await Supabase.initialize(
          url: dotenv.env['SUPABASE_URL']!,
          anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
        ).timeout(const Duration(seconds: 12));
      } catch (e) {
        if (!e.toString().toLowerCase().contains('already')) rethrow;
      }
      // Whichever account's session Supabase just restored (or none)
      // needs to be reflected in the local caches' namespacing before
      // any screen reads from them — otherwise the very first frame
      // could show an empty cache for an account that actually has
      // plenty of offline data saved. This can also touch the network
      // (see AccountManagerService.rememberCurrentSession) on a
      // first-time-per-device login, so it gets the same ceiling.
      await AccountManagerService.instance
          .applyActiveNamespaceFromCurrentSession()
          .timeout(const Duration(seconds: 12));
      // Dev-hub cheat codes are per-account and purely local — load
      // whatever this account last had saved (toggle + any active
      // verified badge) now that namespacing points at the right one.
      unawaited(CheatCodeService.instance.load());
      // Best-effort and deliberately never allowed to fail boot: until
      // android/app/google-services.json is actually dropped in (see
      // the comment in app/build.gradle.kts), Firebase.initializeApp()
      // throws on Android because the google-services Gradle plugin
      // never ran to generate the resources it depends on. Once that
      // file exists, this silently starts working with no other
      // change needed here.
      try {
        await Firebase.initializeApp();
        FirebaseMessaging.onBackgroundMessage(
            _firebaseMessagingBackgroundHandler);
        unawaited(PushNotificationService.instance.init());
      } catch (_) {
        // No Firebase project wired up yet — the rest of the app
        // works exactly the same without it.
      }
      // Not awaited on purpose: this starts the connectivity listener
      // and attempts an immediate flush of any privacy-setting change
      // left over from a previous offline session, but there's no
      // reason to make the splash screen wait on it — if it's slow or
      // fails, the toggle sheet already shows the locally-saved value
      // either way.
      unawaited(PrivacySettingsSyncService.instance.init());
      // Same contract as the line above, for username/display
      // name/home city edits made from the Edit Profile sheet.
      unawaited(ProfileFieldsSyncService.instance.init());
      // Same reasoning: if this phone was already acting as the SMS
      // gateway and the process simply restarted (not an explicit
      // "turn off"), bring it back online in the background rather
      // than requiring a trip back to the Gateway Setup screen.
      unawaited(SmsGatewayBridge.instance.resumeIfNeeded());
      // Same reasoning again, but more so: an ad network is the last
      // thing that should ever get to hold the splash screen open or
      // turn into a boot-error banner. AdService.init() never throws
      // (see its own doc comment) — this just gets it started early
      // so it's usually already resolved by the time the feed's
      // first native ad slot scrolls into view.
      unawaited(AdService.instance.init());
    } on TimeoutException {
      _bootstrapError =
          'Taking too long to connect — check your internet connection '
          'and try again.';
    } catch (e) {
      _bootstrapError = e.toString();
    }

    // Keep the splash up for a minimum stretch so it reads as an
    // intentional loading moment rather than a single-frame flicker
    // on a warm start / fast connection.
    const minSplash = Duration(milliseconds: 900);
    final elapsed = DateTime.now().difference(startedAt);
    if (elapsed < minSplash) {
      await Future.delayed(minSplash - elapsed);
    }

    // ThemeController.init() repoints RMColors/mode but doesn't itself
    // notify listeners (that's only done on an explicit user toggle
    // later) — this rebuild is what picks up a previously-saved
    // light/dark/system preference for the very first real frame.
    if (mounted) setState(() {});
  }

  void _retry() {
    setState(() {
      _bootstrapError = null;
      _bootstrap = _boot();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) {
        final isDark = ThemeController.instance.isDark;
        SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness:
              isDark ? Brightness.light : Brightness.dark,
        ));

        return MaterialApp(
          title: 'Reality Merge',
          debugShowCheckedModeBanner: false,
          theme: RMTheme.light,
          darkTheme: RMTheme.dark,
          themeMode: ThemeController.instance.mode,
          home: FutureBuilder<void>(
            future: _bootstrap,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SplashScreen();
              }
              if (_bootstrapError != null) {
                return SplashErrorScreen(
                    message: _bootstrapError!, onRetry: _retry);
              }
              return AuthGate();
            },
          ),
        );
      },
    );
  }
}
