import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/presence_avatar.dart';
import 'group_chat_screen.dart';

/// The notification inbox, opened from the bell icon on the Chats tab.
/// Every row is read-only except `mention_invite` ones with a still-
/// pending `invite_status` — those get inline Accept/Decline buttons
/// that create (or skip) the 3-person group chat right from here.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<Map<String, dynamic>> _notifications = [];
  bool _loading = true;
  String? _error;
  final Set<String> _responding = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_notifications.isEmpty) setState(() => _loading = true);
    try {
      final rows = await SupabaseService.instance.fetchNotifications();
      if (mounted) setState(() { _notifications = rows; _error = null; });
      // Opening the inbox is itself the "seen" signal for the bell
      // badge — individual invite cards still track their own
      // read/answered state separately via invite_status.
      await SupabaseService.instance.markAllNotificationsRead();
    } catch (e) {
      if (mounted && _notifications.isEmpty) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _respond(Map<String, dynamic> n, bool accept) async {
    final inviteId = (n['data'] as Map?)?['invite_id'] as String?;
    if (inviteId == null || _responding.contains(inviteId)) return;
    setState(() => _responding.add(inviteId));
    try {
      final groupChatId = await SupabaseService.instance
          .respondToMentionInvite(inviteId: inviteId, accept: accept);
      if (!mounted) return;
      await _load();
      if (accept && groupChatId != null && mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => GroupChatScreen(chatId: groupChatId),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not respond: $e')));
      }
    } finally {
      if (mounted) setState(() => _responding.remove(inviteId));
    }
  }

  String _relativeTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${t.month}/${t.day}/${t.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        title: Text('Notifications'),
        backgroundColor: RMColors.background,
      ),
      body: RefreshIndicator(
        color: RMColors.primary,
        backgroundColor: RMColors.surface,
        onRefresh: _load,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: RMColors.primary));
    }
    if (_error != null && _notifications.isEmpty) {
      return LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: Center(
              child: Text(_error!, style: TextStyle(color: RMColors.textSecondary)),
            ),
          ),
        ),
      );
    }
    if (_notifications.isEmpty) {
      return LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.notifications_none_rounded,
                      color: RMColors.textHint, size: 48),
                  SizedBox(height: 12),
                  Text('No notifications yet.',
                      style: TextStyle(
                          color: RMColors.textPrimary, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return ListView.separated(
      physics: AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _notifications.length,
      separatorBuilder: (_, __) => SizedBox(height: 8),
      itemBuilder: (context, i) => _buildTile(_notifications[i]),
    );
  }

  Widget _buildTile(Map<String, dynamic> n) {
    final type = n['type'] as String? ?? '';
    final createdAt =
        DateTime.tryParse(n['created_at'] as String? ?? '') ?? DateTime.now();
    final isPendingInvite = type == 'mention_invite' && n['invite_status'] == 'pending';
    final inviteId = (n['data'] as Map?)?['invite_id'] as String?;
    final busy = inviteId != null && _responding.contains(inviteId);

    IconData icon;
    switch (type) {
      case 'mention_invite':
        icon = Icons.alternate_email_rounded;
        break;
      case 'mention_invite_accepted':
        icon = Icons.groups_rounded;
        break;
      default:
        icon = Icons.notifications_rounded;
    }

    return Container(
      decoration: BoxDecoration(
        color: RMColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RMColors.border),
      ),
      padding: EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          n['actor_id'] != null
              ? PresenceAvatar(
                  radius: 20,
                  backgroundColor: RMColors.primaryDim,
                  avatarUrl: n['actor_avatar_url'] as String?,
                  placeholder: Icon(Icons.person_rounded, color: RMColors.primary),
                )
              : CircleAvatar(
                  radius: 20,
                  backgroundColor: RMColors.primaryDim,
                  child: Icon(icon, color: RMColors.primary, size: 18),
                ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(n['title'] as String? ?? '',
                    style: TextStyle(
                        color: RMColors.textPrimary, fontWeight: FontWeight.w700)),
                if (isPendingInvite && (n['body'] as String?)?.isNotEmpty == true) ...[
                  // The tagged message itself, styled like a chat bubble
                  // rather than a plain notification snippet — this is
                  // the actual content someone's deciding whether to
                  // join a group over, so it gets full text, not a
                  // 2-line ellipsis.
                  SizedBox(height: 8),
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
                    child: Text(n['body'] as String,
                        style: TextStyle(color: RMColors.textPrimary, fontSize: 14, height: 1.3)),
                  ),
                ] else if ((n['body'] as String?)?.isNotEmpty == true) ...[
                  SizedBox(height: 2),
                  Text(n['body'] as String,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: RMColors.textSecondary, fontSize: 13)),
                ],
                SizedBox(height: 4),
                Text(_relativeTime(createdAt),
                    style: TextStyle(color: RMColors.textHint, fontSize: 11)),
                if (isPendingInvite) ...[
                  SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: busy ? null : () => _respond(n, false),
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
                          onPressed: busy ? null : () => _respond(n, true),
                          style: FilledButton.styleFrom(
                              backgroundColor: RMColors.success,
                              foregroundColor: Colors.white,
                              padding: EdgeInsets.symmetric(vertical: 10)),
                          icon: busy
                              ? SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : Icon(Icons.check_rounded, size: 18),
                          label: Text(busy ? '' : 'Accept'),
                        ),
                      ),
                    ],
                  ),
                ] else if (type == 'mention_invite' && n['invite_status'] != null) ...[
                  SizedBox(height: 4),
                  Text(
                    switch (n['invite_status']) {
                      'accepted' => 'Accepted',
                      'declined' => 'Declined',
                      'expired' => 'Invite expired',
                      _ => '',
                    },
                    style: TextStyle(
                        color: n['invite_status'] == 'accepted'
                            ? RMColors.success
                            : RMColors.textHint,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
