import 'dart:async';
import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../screens/group_chat_screen.dart';

/// The popup version of the mention-invite prompt — same decision as
/// the notifications-screen card (accept -> join the 3-person group,
/// decline -> close it out), just surfaced immediately as a dialog
/// instead of waiting for someone to open the notification list.
///
/// Shown from [maybeShow], which is what HomeShell calls both once at
/// launch (so logging back out and back in still finds a still-live
/// invite waiting) and again on every realtime mention-invite event
/// while the app stays open.
class MentionInviteDialog extends StatefulWidget {
  const MentionInviteDialog({super.key, required this.invite});

  final Map<String, dynamic> invite;

  /// Guards against two triggers (the initial launch check and a
  /// realtime event landing moments later) both trying to push a
  /// dialog at once.
  static bool _showing = false;

  /// Fetches the current active invite (if any) and shows the dialog
  /// for it. Safe to call speculatively — a null result or a context
  /// that's gone by the time the fetch resolves is just a no-op.
  static Future<void> maybeShow(BuildContext context) async {
    if (_showing) return;
    Map<String, dynamic>? invite;
    try {
      invite = await SupabaseService.instance.fetchActiveMentionInvite();
    } catch (_) {
      // Best-effort — a failed check here just means the person falls
      // back on finding the invite in their notifications screen
      // (or the next successful check) before it expires.
      return;
    }
    if (invite == null || !context.mounted || _showing) return;
    _showing = true;
    try {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => MentionInviteDialog(invite: invite!),
      );
    } finally {
      _showing = false;
    }
  }

  @override
  State<MentionInviteDialog> createState() => _MentionInviteDialogState();
}

class _MentionInviteDialogState extends State<MentionInviteDialog> {
  Timer? _ticker;
  Duration _remaining = Duration.zero;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _updateRemaining();
    // Ticking locally is just so the countdown looks alive — the
    // actual cutoff is enforced server-side in respond_to_mention_invite,
    // so a clock that's a little off from Supabase's never lets
    // someone sneak an accept through after the real deadline.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateRemaining();
      if (_remaining <= Duration.zero) {
        _ticker?.cancel();
      }
    });
  }

  void _updateRemaining() {
    final expiresAt = DateTime.tryParse(widget.invite['expires_at'] as String? ?? '');
    if (expiresAt == null) return;
    final remaining = expiresAt.difference(DateTime.now());
    if (mounted) {
      setState(() => _remaining = remaining.isNegative ? Duration.zero : remaining);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String get _countdownLabel {
    final m = _remaining.inMinutes;
    final s = _remaining.inSeconds % 60;
    return '${m}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _respond(bool accept) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    final inviteId = widget.invite['invite_id'] as String;
    try {
      final groupChatId = await SupabaseService.instance
          .respondToMentionInvite(inviteId: inviteId, accept: accept);
      if (!mounted) return;
      Navigator.of(context).pop();
      if (accept && groupChatId != null) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => GroupChatScreen(chatId: groupChatId)),
        );
      }
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = 'This invite may have expired.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final inviter = widget.invite['inviter_username'] as String? ?? 'Someone';
    final other = widget.invite['other_username'] as String?;
    final message = widget.invite['message_content'] as String? ?? '';
    final expired = _remaining <= Duration.zero;

    return Dialog(
      backgroundColor: RMColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    other != null
                        ? '@$inviter wants you in a chat with @$other'
                        : '@$inviter mentioned you',
                    style: TextStyle(
                        color: RMColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 16),
                  ),
                ),
                Icon(Icons.timer_outlined, size: 16, color: RMColors.textHint),
                SizedBox(width: 4),
                Text(
                  expired ? 'Expired' : _countdownLabel,
                  style: TextStyle(
                      color: expired ? RMColors.danger : RMColors.textHint,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
            SizedBox(height: 12),
            // The tagged message itself, styled like a real chat
            // bubble — same treatment as the notifications-screen
            // card, so this reads as "here's the message you were
            // tagged in" rather than a generic system prompt.
            Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: RMColors.surfaceAlt,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(12),
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
                border: Border.all(color: RMColors.border),
              ),
              child: Text(message,
                  style: TextStyle(color: RMColors.textPrimary, fontSize: 14, height: 1.3)),
            ),
            if (_error != null) ...[
              SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: RMColors.danger, fontSize: 13)),
            ],
            SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _respond(false),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: RMColors.danger,
                        side: BorderSide(color: RMColors.danger),
                        padding: EdgeInsets.symmetric(vertical: 10)),
                    icon: Icon(Icons.close_rounded, size: 18),
                    label: Text('Decline'),
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy || expired ? null : () => _respond(true),
                    style: FilledButton.styleFrom(
                        backgroundColor: RMColors.success,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(vertical: 10)),
                    icon: _busy
                        ? SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Icon(Icons.check_rounded, size: 18),
                    label: Text(_busy ? '' : 'Accept'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
