import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../theme/rm_theme.dart';

/// A shake-to-flip digital coin. Shaking the phone (measured via the
/// accelerometer) or tapping the coin triggers a spin animation that
/// lands on Heads or Tails, decided by [math.Random] once the flip
/// starts — so the result isn't picked until the shake actually
/// happens, same as a real coin.
class CoinFlipScreen extends StatefulWidget {
  const CoinFlipScreen({super.key});

  @override
  State<CoinFlipScreen> createState() => _CoinFlipScreenState();
}

class _CoinFlipScreenState extends State<CoinFlipScreen>
    with SingleTickerProviderStateMixin {
  static const _shakeThreshold = 22.0; // m/s^2 of jerk to count as a shake
  static const _shakeCooldown = Duration(milliseconds: 1200);

  StreamSubscription<AccelerometerEvent>? _accelSub;
  DateTime? _lastShake;
  double? _lastX, _lastY, _lastZ;

  late final AnimationController _controller;
  late Animation<double> _spin;

  final _rand = math.Random();
  bool? _headsResult; // null until the first flip resolves
  bool _flipping = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _spin = Tween<double>(begin: 0, end: 1).animate(_controller);

    _accelSub = accelerometerEventStream().listen(_onAccel, onError: (_) {
      // No accelerometer available (e.g. some emulators/desktop) — the
      // tap-to-flip button below still works fine without it.
    });
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onAccel(AccelerometerEvent event) {
    final lastX = _lastX, lastY = _lastY, lastZ = _lastZ;
    _lastX = event.x;
    _lastY = event.y;
    _lastZ = event.z;
    if (lastX == null || lastY == null || lastZ == null) return;

    final jerk = ((event.x - lastX).abs() +
        (event.y - lastY).abs() +
        (event.z - lastZ).abs());
    if (jerk < _shakeThreshold) return;

    final now = DateTime.now();
    if (_lastShake != null && now.difference(_lastShake!) < _shakeCooldown) {
      return;
    }
    _lastShake = now;
    _flip();
  }

  void _flip() {
    if (_flipping) return;
    HapticFeedback.mediumImpact();
    // Decided now, not before — a fresh coin toss for every shake.
    final landsHeads = _rand.nextBool();
    // A whole number of full turns, plus a half turn if the result is
    // tails, so the coin visually settles face-up on the right side.
    final extraTurns = 3 + _rand.nextInt(3);
    setState(() {
      _flipping = true;
      _headsResult = null;
    });
    _spin = Tween<double>(
      begin: 0,
      end: extraTurns + (landsHeads ? 0.0 : 0.5),
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller
      ..reset()
      ..forward().whenComplete(() {
        if (!mounted) return;
        HapticFeedback.selectionClick();
        setState(() {
          _flipping = false;
          _headsResult = landsHeads;
        });
      });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        backgroundColor: RMColors.background,
        title: const Text('Coin Flip'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 12),
            Text(
              'Shake your phone — or tap the coin',
              style: TextStyle(color: RMColors.textSecondary, fontSize: 14),
            ),
            Expanded(
              child: Center(
                child: GestureDetector(
                  onTap: _flip,
                  child: AnimatedBuilder(
                    animation: _spin,
                    builder: (context, child) {
                      // spin.value in "turns"; convert to radians and
                      // squash horizontally to fake a 3D flip.
                      final turns = _flipping ? _spin.value : 0.0;
                      final angle = turns * 2 * math.pi;
                      final showingHeads = ((turns * 2).round() % 2 == 0);
                      return Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..setEntry(3, 2, 0.002)
                          ..rotateY(angle),
                        child: _Coin(
                          heads: _flipping
                              ? showingHeads
                              : (_headsResult ?? true),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Padding(
                key: ValueKey(_flipping
                    ? 'flipping'
                    : (_headsResult == null ? 'idle' : _headsResult)),
                padding: const EdgeInsets.only(bottom: 40),
                child: Text(
                  _flipping
                      ? 'Flipping…'
                      : (_headsResult == null
                          ? 'Ready when you are'
                          : (_headsResult! ? 'HEADS' : 'TAILS')),
                  style: TextStyle(
                    color: _flipping
                        ? RMColors.textSecondary
                        : (_headsResult == null
                            ? RMColors.textSecondary
                            : RMColors.accent),
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Coin extends StatelessWidget {
  final bool heads;
  const _Coin({required this.heads});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 180,
      height: 180,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [RMColors.accent, RMColors.primary],
        ),
        border: Border.all(color: RMColors.border, width: 3),
        boxShadow: [
          BoxShadow(
            color: RMColors.primary.withOpacity(0.35),
            blurRadius: 30,
            spreadRadius: 2,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        heads ? 'H' : 'T',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 64,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}
