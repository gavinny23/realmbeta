import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/rm_theme.dart';

/// Drop-in replacement for a plain `CircleAvatar` that adds a presence
/// indicator to the bottom-right corner:
///  - a small solid green dot while the person is online (active
///    within [onlineWindow] — kept in sync with how often
///    `PresenceService` sends its heartbeat), or
///  - a compact "5m" / "3h" / "2d" last-seen chip once they've gone
///    quiet, so a glance still tells you roughly when they were last
///    around.
///
/// Pass `lastActiveAt: null` (the default) to render a plain avatar
/// with no badge at all — that's the right call for avatars that
/// don't have presence data wired up (or don't need it, like your
/// own avatar, or a saved local account switcher).
class PresenceAvatar extends StatelessWidget {
  final double radius;
  final String? avatarUrl;
  final Color? backgroundColor;

  /// Shown when [avatarUrl] is null — an icon, initial, etc.
  final Widget? placeholder;

  /// When this person was last active. Null renders no badge at all.
  final DateTime? lastActiveAt;

  /// The color the badge's ring is painted against — should match
  /// whatever surface the avatar sits on so the ring reads as a gap
  /// rather than an outline. Defaults to the card/page surface color.
  /// Nullable (rather than defaulting straight to `RMColors.surface`)
  /// because RMColors' fields are mutable statics that get repointed
  /// on theme switches, not compile-time constants — Dart requires a
  /// constructor default to be a real constant, so the fallback is
  /// resolved at build time instead.
  final Color? badgeBorderColor;

  static const onlineWindow = Duration(minutes: 2);

  const PresenceAvatar({
    super.key,
    required this.radius,
    this.avatarUrl,
    this.backgroundColor,
    this.placeholder,
    this.lastActiveAt,
    this.badgeBorderColor,
  });

  bool get _isOnline => isOnline(lastActiveAt);

  /// Null return means "don't show a last-seen chip" — either they're
  /// online (the dot covers that) or they've been gone long enough
  /// (a week+) that a relative label stops being a useful signal.
  String? get _lastSeenLabel => lastSeenLabel(lastActiveAt);

  /// True if [lastActiveAt] falls within [onlineWindow] of now — kept
  /// as a static helper so screens that need the same "online right
  /// now?" check (e.g. a DM's app bar) don't have to re-derive it.
  static bool isOnline(DateTime? lastActiveAt) =>
      lastActiveAt != null &&
      DateTime.now().difference(lastActiveAt) <= onlineWindow;

  /// Short relative label ("now" / "5m" / "3h" / "2d"), or null once
  /// they've been gone a week+ and a relative label stops being a
  /// useful signal. Doesn't distinguish the online case — check
  /// [isOnline] first if that matters to the caller.
  static String? lastSeenLabel(DateTime? lastActiveAt) {
    if (lastActiveAt == null || isOnline(lastActiveAt)) return null;
    final diff = DateTime.now().difference(lastActiveAt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return null;
  }

  /// Full status line for a DM app bar / profile sheet: "Online",
  /// "Active 5m ago", or null when there's nothing worth showing
  /// (no presence data, or it's stale enough to skip).
  static String? statusLine(DateTime? lastActiveAt) {
    if (lastActiveAt == null) return null;
    if (isOnline(lastActiveAt)) return 'Online';
    final label = lastSeenLabel(lastActiveAt);
    if (label == null) return null;
    return label == 'now' ? 'Active just now' : 'Active $label ago';
  }

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: backgroundColor ?? RMColors.primaryDim,
      backgroundImage:
          avatarUrl != null ? CachedNetworkImageProvider(avatarUrl!) : null,
      child: avatarUrl == null ? placeholder : null,
    );

    if (lastActiveAt == null) return avatar;

    final borderColor = badgeBorderColor ?? RMColors.surface;
    final label = _lastSeenLabel;
    final dotSize = math.max(9.0, size * 0.3);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          if (_isOnline)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: dotSize,
                height: dotSize,
                decoration: BoxDecoration(
                  color: RMColors.success,
                  shape: BoxShape.circle,
                  border: Border.all(color: borderColor, width: 2),
                ),
              ),
            )
          else if (label != null)
            Positioned(
              right: -6,
              bottom: -4,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: RMColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: borderColor, width: 1.5),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: RMColors.textSecondary,
                    fontSize: math.max(8.0, radius * 0.4),
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
