import 'package:flutter/material.dart';
import '../models/profile_rank.dart';
import '../services/cheat_code_service.dart';
import '../theme/rm_theme.dart';

/// Drop this into any text field's `onChanged` (or `onSubmitted`) to
/// make it recognize cheat codes:
///
/// ```dart
/// TextField(
///   controller: _msgCtrl,
///   onChanged: (v) => CheatCodeTrigger.watch(context, _msgCtrl, v),
///   ...
/// )
/// ```
///
/// When the field's text exactly matches a known trigger phrase, this
/// clears the field (so the phrase never gets sent as a real message/
/// comment) and runs the loading -> pass/fail dialog flow.
class CheatCodeTrigger {
  CheatCodeTrigger._();

  static void watch(
    BuildContext context,
    TextEditingController controller,
    String text,
  ) {
    final trigger = CheatCodeService.instance.matchTrigger(text);
    if (trigger == null) return;
    controller.clear();
    _run(context, trigger);
  }

  static Future<void> _run(BuildContext context, String trigger) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _CheatLoadingDialog(),
    );

    final result = await CheatCodeService.instance.redeem(trigger);

    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // close loading dialog

    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => _CheatResultDialog(result: result),
    );
  }
}

class _CheatLoadingDialog extends StatelessWidget {
  const _CheatLoadingDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: RMColors.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: RMColors.primary,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Running cheat code…',
              style: TextStyle(
                  color: RMColors.textPrimary, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _CheatResultDialog extends StatelessWidget {
  final CheatCodeResult result;
  const _CheatResultDialog({required this.result});

  @override
  Widget build(BuildContext context) {
    final color = result.passed ? RMColors.success : RMColors.danger;
    return Dialog(
      backgroundColor: RMColors.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withOpacity(0.15),
              ),
              child: Icon(
                result.passed ? Icons.check_rounded : Icons.close_rounded,
                color: color,
                size: 32,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              result.title,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: RMColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              result.message,
              textAlign: TextAlign.center,
              style: TextStyle(color: RMColors.textSecondary),
            ),
            if (result.rank != null) ...[
              const SizedBox(height: 20),
              _RankCard(rank: result.rank!),
            ] else if (result.passed) ...[
              const SizedBox(height: 20),
              const _GenericPassPreview(),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Nice'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rank/percentile breakdown shown after "/my-rank" — real numbers
/// from the server, not a local cheat state.
class _RankCard extends StatelessWidget {
  final ProfileRank rank;
  const _RankCard({required this.rank});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: RMColors.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          _rankRow(
            icon: Icons.people_alt_rounded,
            label: 'Followers',
            rank: rank.followerRank,
            total: rank.totalProfiles,
            percentile: rank.followerPercentile,
          ),
          const SizedBox(height: 10),
          Divider(height: 1, color: RMColors.border),
          const SizedBox(height: 10),
          _rankRow(
            icon: Icons.bolt_rounded,
            label: 'Engagement',
            rank: rank.engagementRank,
            total: rank.totalProfiles,
            percentile: rank.engagementPercentile,
          ),
        ],
      ),
    );
  }

  Widget _rankRow({
    required IconData icon,
    required String label,
    required int rank,
    required int total,
    required int percentile,
  }) {
    return Row(
      children: [
        Icon(icon, color: RMColors.primary, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      color: RMColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
              Text('#$rank of $total',
                  style: TextStyle(
                      color: RMColors.textSecondary, fontSize: 12)),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: RMColors.primaryDim,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text('Top $percentile%',
              style: TextStyle(
                  color: RMColors.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12)),
        ),
      ],
    );
  }
}

/// Generic "here's what changed" preview for the simple local
/// on/off-style codes (verified, gold frame, OG badge) — just a
/// one-line confirmation, since the actual badge already shows up on
/// the real profile screen on its own.
class _GenericPassPreview extends StatelessWidget {
  const _GenericPassPreview();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: RMColors.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_rounded, color: RMColors.success, size: 16),
          const SizedBox(width: 6),
          Text(
            'Check your profile to see it',
            style: TextStyle(
                color: RMColors.textPrimary, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// The blue-tick badge, reused wherever a verified profile needs to
/// show it (profile header, Dev Hub status chip, etc.).
class VerifiedBadge extends StatelessWidget {
  final double size;
  const VerifiedBadge({super.key, this.size = 16});

  @override
  Widget build(BuildContext context) {
    return Icon(Icons.verified_rounded, color: Colors.blue, size: size);
  }
}

/// Small "early adopter" chip for "/og-badge".
class OgBadge extends StatelessWidget {
  const OgBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.amber.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.amber.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_rounded, color: Colors.amber, size: 12),
          const SizedBox(width: 3),
          Text('OG',
              style: TextStyle(
                  color: Colors.amber,
                  fontWeight: FontWeight.w700,
                  fontSize: 10)),
        ],
      ),
    );
  }
}

/// Gold ring wrapper for "/gold-frame" — wrap around an avatar widget:
/// `GoldFrame(child: CircleAvatar(...))`.
class GoldFrame extends StatelessWidget {
  final Widget child;
  final double padding;
  const GoldFrame({super.key, required this.child, this.padding = 3});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(padding),
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [Color(0xFFFFD700), Color(0xFFB8860B)],
        ),
      ),
      child: child,
    );
  }
}
