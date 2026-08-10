import 'package:flutter/material.dart';
import '../theme/rm_theme.dart';

/// Inverts a light-on-white line-art image so it reads as light lines
/// on a dark ground, without needing a second dark-mode asset.
const _kInvertFilter = ColorFilter.matrix(<double>[
  -1, 0, 0, 0, 255,
  0, -1, 0, 0, 255,
  0, 0, -1, 0, 255,
  0, 0, 0, 1, 0,
]);

/// The default chat wallpaper — the Realm doodle sheet, tiled behind
/// the message list in both 1:1 and group chats. It's just a wash: low
/// opacity, inverted in dark mode so the (originally ink-on-paper)
/// artwork reads as faint light linework on the app's near-black
/// background instead of a bright rectangle. Sits behind [child],
/// which should be transparent so the pattern shows through.
class ChatBackground extends StatelessWidget {
  final Widget child;

  const ChatBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = ThemeController.instance.isDark;

    Widget pattern = Image.asset(
      'assets/backgrounds/chat_doodle.png',
      repeat: ImageRepeat.repeat,
      alignment: Alignment.topLeft,
      // The doodle sheet is dense enough that showing it near actual
      // size (rather than stretched to cover) is what keeps individual
      // sketches legible as a pattern instead of a blur.
      scale: 2.2,
    );

    if (isDark) {
      pattern = ColorFiltered(colorFilter: _kInvertFilter, child: pattern);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Base fill — matches the theme's background exactly, so any
        // uncovered edge (or a slow asset decode) never flashes wrong.
        ColoredBox(color: RMColors.background),
        Opacity(
          opacity: isDark ? 0.16 : 0.09,
          child: pattern,
        ),
        child,
      ],
    );
  }
}
