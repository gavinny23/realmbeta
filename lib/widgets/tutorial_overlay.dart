import 'package:flutter/material.dart';
import '../theme/rm_theme.dart';

class TutorialStep {
  final String title;
  final String body;
  final IconData icon;
  final Alignment alignment; // where the tooltip appears on screen

  TutorialStep({
    required this.title,
    required this.body,
    required this.icon,
    this.alignment = Alignment.center,
  });
}

/// Full-screen tutorial overlay with animated hand pointer and step cards.
/// Dismisses on last step or tap-outside.
class TutorialOverlay extends StatefulWidget {
  final List<TutorialStep> steps;
  final VoidCallback onDone;

  TutorialOverlay({
    super.key,
    required this.steps,
    required this.onDone,
  });

  @override
  State<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends State<TutorialOverlay>
    with TickerProviderStateMixin {
  int _step = 0;
  late AnimationController _handCtrl;
  late AnimationController _cardCtrl;
  late Animation<double> _handBob;
  late Animation<double> _cardFade;
  late Animation<Offset> _cardSlide;

  @override
  void initState() {
    super.initState();

    // Hand bobbing animation
    _handCtrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _handBob = Tween<double>(begin: 0, end: 12).animate(
      CurvedAnimation(parent: _handCtrl, curve: Curves.easeInOut),
    );

    // Card entrance animation
    _cardCtrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 350),
    );

    _cardFade = CurvedAnimation(parent: _cardCtrl, curve: Curves.easeOut);
    _cardSlide = Tween<Offset>(
      begin: Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _cardCtrl, curve: Curves.easeOut));

    _cardCtrl.forward();
  }

  @override
  void dispose() {
    _handCtrl.dispose();
    _cardCtrl.dispose();
    super.dispose();
  }

  void _next() {
    if (_step >= widget.steps.length - 1) {
      widget.onDone();
      return;
    }
    _cardCtrl.reverse().then((_) {
      setState(() => _step++);
      _cardCtrl.forward();
    });
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.steps[_step];
    final size = MediaQuery.of(context).size;

    return GestureDetector(
      onTap: _next,
      child: Material(
        color: Colors.black.withOpacity(0.75),
        child: Stack(
          children: [
            // Animated hand pointer
            AnimatedBuilder(
              animation: _handBob,
              builder: (context, _) {
                return Positioned(
                  left: size.width / 2 - 24,
                  top: size.height / 2 - 60 + _handBob.value,
                  child: _HandIcon(),
                );
              },
            ),

            // Step card
            Positioned(
              left: 24,
              right: 24,
              bottom: 80,
              child: FadeTransition(
                opacity: _cardFade,
                child: SlideTransition(
                  position: _cardSlide,
                  child: _TutorialCard(
                    step: step,
                    current: _step + 1,
                    total: widget.steps.length,
                    onNext: _next,
                  ),
                ),
              ),
            ),

            // Skip button
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              right: 16,
              child: TextButton(
                onPressed: widget.onDone,
                child: Text(
                  'Skip',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HandIcon extends StatelessWidget {
  _HandIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: RMColors.primary.withOpacity(0.2),
        shape: BoxShape.circle,
        border: Border.all(color: RMColors.primary, width: 2),
      ),
      child: Icon(Icons.touch_app, color: RMColors.primary, size: 28),
    );
  }
}

class _TutorialCard extends StatelessWidget {
  final TutorialStep step;
  final int current;
  final int total;
  final VoidCallback onNext;

  _TutorialCard({
    required this.step,
    required this.current,
    required this.total,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: RMColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: RMColors.border),
        boxShadow: [
          BoxShadow(
            color: RMColors.primary.withOpacity(0.15),
            blurRadius: 32,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: RMColors.primaryDim,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(step.icon, color: RMColors.primary, size: 22),
              ),
              Spacer(),
              Text(
                '$current / $total',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
          SizedBox(height: 16),
          Text(step.title, style: Theme.of(context).textTheme.titleLarge),
          SizedBox(height: 8),
          Text(step.body, style: Theme.of(context).textTheme.bodyMedium),
          SizedBox(height: 20),
          // Progress dots
          Row(
            children: List.generate(total, (i) => AnimatedContainer(
              duration: Duration(milliseconds: 250),
              margin: EdgeInsets.only(right: 6),
              width: i == current - 1 ? 20 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i == current - 1
                    ? RMColors.primary
                    : RMColors.border,
                borderRadius: BorderRadius.circular(3),
              ),
            )),
            mainAxisAlignment: MainAxisAlignment.start,
          ),
          SizedBox(height: 20),
          FilledButton(
            onPressed: onNext,
            child: Text(current == total ? 'Got it' : 'Next'),
          ),
        ],
      ),
    );
  }
}
