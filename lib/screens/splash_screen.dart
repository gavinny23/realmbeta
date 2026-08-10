import 'package:flutter/material.dart';
import '../theme/rm_theme.dart';

/// The app's boot screen — shown from the moment Flutter takes over
/// drawing (replacing the plain native launch screen as fast as
/// possible) until env vars, theme/prefs, and Supabase are ready.
///
/// Deliberately simple: animated brand mark, wordmark, tagline, and a
/// thin animated progress bar. No network calls, no async work of its
/// own — it just renders instantly using [RMColors]' default (dark)
/// palette, which is available immediately even before
/// [ThemeController.init] has run.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RMColors.background,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Brand mark — the Realm logo, playing a one-shot
            // fade + scale entrance followed by a soft looping glow
            // pulse behind it for as long as the splash is on screen.
            const _AnimatedBrandMark(size: 128),
            SizedBox(height: 28),
            Text(
              'REALM',
              style: TextStyle(
                color: RMColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: 3,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'The world is no longer empty.',
              style: TextStyle(color: RMColors.textSecondary, fontSize: 13),
            ),
            SizedBox(height: 56),
            _BrandProgressBar(),
          ],
        ),
      ),
    );
  }
}

/// Plays the Realm logo in twice: once as a quick entrance (fade in +
/// scale up from 70% with a slight overshoot), then settles into an
/// indefinite, slow glow-ring pulse behind the mark — signalling
/// "still working" the same way [_BrandProgressBar] does, just as a
/// glow rather than a bar.
class _AnimatedBrandMark extends StatefulWidget {
  final double size;
  const _AnimatedBrandMark({required this.size});

  @override
  State<_AnimatedBrandMark> createState() => _AnimatedBrandMarkState();
}

class _AnimatedBrandMarkState extends State<_AnimatedBrandMark>
    with TickerProviderStateMixin {
  late final AnimationController _entrance;
  late final AnimationController _pulse;
  late final Animation<double> _entranceScale;
  late final Animation<double> _entranceOpacity;
  late final Animation<double> _pulseValue;

  @override
  void initState() {
    super.initState();

    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _entranceScale = CurvedAnimation(
      parent: _entrance,
      curve: Curves.easeOutBack,
    ).drive(Tween(begin: 0.7, end: 1.0));
    _entranceOpacity = CurvedAnimation(
      parent: _entrance,
      curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
    );

    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseValue = CurvedAnimation(parent: _pulse, curve: Curves.easeInOut);

    _entrance.forward();
  }

  @override
  void dispose() {
    _entrance.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_entrance, _pulse]),
      builder: (context, _) {
        final glowStrength = 0.35 + (_pulseValue.value * 0.35); // 0.35–0.70
        final glowScale = 1.0 + (_pulseValue.value * 0.06); // gentle breathing

        return Opacity(
          opacity: _entranceOpacity.value,
          child: Transform.scale(
            scale: _entranceScale.value,
            child: SizedBox(
              width: widget.size * 1.6,
              height: widget.size * 1.6,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Soft glow ring behind the mark, breathing slowly.
                  Transform.scale(
                    scale: glowScale,
                    child: Container(
                      width: widget.size * 1.4,
                      height: widget.size * 1.4,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            RMColors.primary.withOpacity(glowStrength),
                            RMColors.accent.withOpacity(glowStrength * 0.4),
                            RMColors.primary.withOpacity(0.0),
                          ],
                          stops: const [0.0, 0.5, 1.0],
                        ),
                      ),
                    ),
                  ),
                  // The actual logo mark.
                  Image.asset(
                    'assets/branding/realm_logo.png',
                    width: widget.size,
                    height: widget.size,
                    fit: BoxFit.contain,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A slim, rounded, indeterminate progress bar in the app's primary
/// color — deliberately not tied to a real "percent loaded" number
/// (boot work like reading a couple of prefs and opening a Supabase
/// client doesn't have a meaningful progress fraction), just a clear
/// "something's happening" signal in the app's own visual language.
class _BrandProgressBar extends StatelessWidget {
  const _BrandProgressBar();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 160,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LinearProgressIndicator(
          minHeight: 5,
          backgroundColor: RMColors.surfaceAlt,
          valueColor: AlwaysStoppedAnimation(RMColors.primary),
        ),
      ),
    );
  }
}

/// Shown instead of the splash if boot actually fails (e.g. missing
/// `.env`, unreachable Supabase project) — same visual language, but
/// with a message and a way to try again rather than being stuck on
/// an indeterminate bar forever.
class SplashErrorScreen extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const SplashErrorScreen(
      {super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RMColors.background,
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.cloud_off_rounded, color: RMColors.danger, size: 44),
              SizedBox(height: 16),
              Text(
                'Couldn\'t start Reality Merge',
                style: TextStyle(
                    color: RMColors.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 8),
              Text(
                message,
                style: TextStyle(color: RMColors.textSecondary, fontSize: 12),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 24),
              OutlinedButton(onPressed: onRetry, child: Text('Try again')),
            ],
          ),
        ),
      ),
    );
  }
}
