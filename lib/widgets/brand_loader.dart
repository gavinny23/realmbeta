import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/rm_theme.dart';

/// The app's animated brand mark — a pulsing gradient orb with a
/// slowly orbiting glow ring around Reality Merge's location/globe
/// icon. Used full-size on the splash screen, and can be dropped in
/// at [size] 40-56 anywhere else a centered "loading" state needs to
/// feel like the app rather than a bare spinner.
///
/// Three animations run independently so nothing ever looks static:
/// - a ring of light sweeps around the orb (continuous rotation)
/// - the orb's glow breathes in and out (pulse)
/// - the icon itself has a very subtle scale breathe, slightly out of
///   phase with the glow so it doesn't read as one flat "blink"
class BrandLoader extends StatefulWidget {
  final double size;
  final IconData icon;

  const BrandLoader({
    super.key,
    this.size = 92,
    this.icon = Icons.travel_explore_rounded,
  });

  @override
  State<BrandLoader> createState() => _BrandLoaderState();
}

class _BrandLoaderState extends State<BrandLoader>
    with TickerProviderStateMixin {
  late final AnimationController _rotateCtrl = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 3200),
  )..repeat();

  late final AnimationController _pulseCtrl = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _rotateCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ringSize = widget.size * 1.36;

    return SizedBox(
      width: ringSize,
      height: ringSize,
      child: AnimatedBuilder(
        animation: Listenable.merge([_rotateCtrl, _pulseCtrl]),
        builder: (context, child) {
          final pulse = _pulseCtrl.value; // 0..1..0
          final glow = 0.30 + (pulse * 0.30);
          final iconScale = 1.0 + (math.sin(pulse * math.pi) * 0.06);

          return Stack(
            alignment: Alignment.center,
            children: [
              // Orbiting light ring — a short gradient arc that spins
              // continuously around the orb, like a loading ring but
              // shaped to the brand's palette instead of a generic bar.
              Transform.rotate(
                angle: _rotateCtrl.value * 2 * math.pi,
                child: SizedBox(
                  width: ringSize,
                  height: ringSize,
                  child: CustomPaint(
                    painter: _OrbitRingPainter(color: RMColors.primary),
                  ),
                ),
              ),
              // The orb itself — gradient sphere with a breathing glow.
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [RMColors.primary, RMColors.primaryDim],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: RMColors.primary.withOpacity(glow),
                      blurRadius: 32,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Transform.scale(
                  scale: iconScale,
                  child: Icon(
                    widget.icon,
                    color: Colors.white,
                    size: widget.size * 0.5,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Paints a short, soft-edged gradient arc — the piece that visually
/// "orbits" the orb as [_BrandLoaderState._rotateCtrl] spins its
/// parent Transform.rotate.
class _OrbitRingPainter extends CustomPainter {
  final Color color;
  const _OrbitRingPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = size.width / 2 - 3;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        colors: [
          color.withOpacity(0),
          color.withOpacity(0),
          color.withOpacity(0.9),
          color.withOpacity(0),
        ],
        stops: [0.0, 0.62, 0.82, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));

    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(covariant _OrbitRingPainter oldDelegate) =>
      oldDelegate.color != color;
}
