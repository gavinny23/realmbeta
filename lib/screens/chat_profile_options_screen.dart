import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/presence_avatar.dart';
import 'user_profile_screen.dart';

/// Opened by tapping the avatar/name in a DM's app bar. Shows who
/// you're talking to up top, plus the actions that apply specifically
/// to *this* conversation — as opposed to [UserProfileScreen], which
/// is the read-only "their profile" view reachable from here via
/// "View profile".
///
/// Pops with a result the caller can act on:
///   - `{'action': 'search'}` — caller should open in-chat search.
///   - `{'action': 'blocked', 'value': bool}` — block state changed;
///     caller should refresh (e.g. disable the composer).
/// Any other pop (back button, tapping outside) carries no result.
class ChatProfileOptionsScreen extends StatefulWidget {
  final String otherUserId;
  final String otherUsername;
  final String? otherAvatarUrl;
  final DateTime? otherLastActiveAt;

  const ChatProfileOptionsScreen({
    super.key,
    required this.otherUserId,
    required this.otherUsername,
    this.otherAvatarUrl,
    this.otherLastActiveAt,
  });

  @override
  State<ChatProfileOptionsScreen> createState() =>
      _ChatProfileOptionsScreenState();
}

class _ChatProfileOptionsScreenState extends State<ChatProfileOptionsScreen> {
  bool _loadingRelationship = true;
  bool _isBlocked = false;
  bool _hidingStatus = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadRelationship();
  }

  Future<void> _loadRelationship() async {
    try {
      final rel = await SupabaseService.instance
          .fetchChatRelationship(widget.otherUserId);
      if (!mounted) return;
      setState(() {
        _isBlocked = rel['is_blocked_by_me'] ?? false;
        _hidingStatus = rel['hiding_status_from_them'] ?? false;
      });
    } catch (_) {
      // Best-effort — the toggles just start from their default
      // (off) state if this fails; tapping them still works.
    } finally {
      if (mounted) setState(() => _loadingRelationship = false);
    }
  }

  void _viewProfile() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(
          userId: widget.otherUserId,
          username: widget.otherUsername,
        ),
      ),
    );
  }

  void _openSearch() {
    Navigator.of(context).pop({'action': 'search'});
  }

  Future<void> _toggleHideStatus() async {
    if (_busy) return;
    setState(() => _busy = true);
    final previous = _hidingStatus;
    setState(() => _hidingStatus = !previous);
    try {
      final nowHiding =
          await SupabaseService.instance.toggleHideStatusFrom(widget.otherUserId);
      if (!mounted) return;
      setState(() => _hidingStatus = nowHiding);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(nowHiding
              ? 'Your online status is now hidden from ${widget.otherUsername}.'
              : '${widget.otherUsername} can see your online status again.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _hidingStatus = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Couldn\'t update that: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmBlock() async {
    if (_busy) return;
    final blocking = !_isBlocked;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: RMColors.surface,
        title: Text(blocking ? 'Block @${widget.otherUsername}?' : 'Unblock @${widget.otherUsername}?'),
        content: Text(blocking
            ? 'They won\'t be able to message you, and this conversation will disappear from your list. They won\'t be notified.'
            : 'They\'ll be able to message you again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              blocking ? 'Block' : 'Unblock',
              style: TextStyle(color: RMColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      final nowBlocked =
          await SupabaseService.instance.toggleBlockUser(widget.otherUserId);
      if (!mounted) return;
      setState(() {
        _isBlocked = nowBlocked;
        _busy = false;
      });
      if (nowBlocked) {
        // Nothing left to do in this conversation once blocked — hand
        // control back to the chat screen so it can bail out to the list.
        Navigator.of(context).pop({'action': 'blocked', 'value': true});
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${widget.otherUsername} is unblocked.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Couldn\'t update that: $e')),
      );
    }
  }

  Future<void> _openReportDialog() async {
    if (_busy) return;
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _ReportDialog(username: widget.otherUsername),
    );
    if (result == null) return;

    setState(() => _busy = true);
    try {
      await SupabaseService.instance.reportUser(
        userId: widget.otherUserId,
        reason: result['reason']!,
        details: result['details']?.isNotEmpty == true ? result['details'] : null,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Report submitted. Thanks for letting us know.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Couldn\'t submit that report: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusLine = PresenceAvatar.statusLine(widget.otherLastActiveAt);

    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        backgroundColor: RMColors.background,
        title: Text('Chat details'),
      ),
      body: ListView(
        padding: EdgeInsets.only(bottom: 24),
        children: [
          SizedBox(height: 12),
          Center(
            child: Column(
              children: [
                PresenceAvatar(
                  radius: 45,
                  backgroundColor: RMColors.primaryDim,
                  avatarUrl: widget.otherAvatarUrl,
                  lastActiveAt: widget.otherLastActiveAt,
                  badgeBorderColor: RMColors.background,
                  placeholder: Icon(Icons.person_rounded,
                      color: RMColors.primary, size: 40),
                ),
                SizedBox(height: 12),
                Text(
                  '@${widget.otherUsername}',
                  style: TextStyle(
                    color: RMColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                  ),
                ),
                if (statusLine != null && !_hidingStatus) ...[
                  SizedBox(height: 4),
                  Text(
                    statusLine,
                    style: TextStyle(
                      color: statusLine == 'Online'
                          ? RMColors.success
                          : RMColors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(height: 20),
          Divider(color: RMColors.border, height: 1),
          _MenuTile(
            icon: Icons.person_outline_rounded,
            label: 'View profile',
            onTap: _viewProfile,
          ),
          _MenuTile(
            icon: Icons.search_rounded,
            label: 'Search in conversation',
            onTap: _openSearch,
          ),
          _MenuSwitchTile(
            icon: Icons.visibility_off_outlined,
            label: 'Hide your online status',
            subtitle: 'They won\'t see when you\'re active in this chat.',
            value: _hidingStatus,
            enabled: !_busy && !_loadingRelationship,
            onChanged: (_) => _toggleHideStatus(),
          ),
          Divider(color: RMColors.border, height: 1),
          _MenuTile(
            icon: Icons.block_rounded,
            label: _isBlocked ? 'Unblock user' : 'Block user',
            danger: true,
            enabled: !_busy && !_loadingRelationship,
            onTap: _confirmBlock,
          ),
          _MenuTile(
            icon: Icons.flag_outlined,
            label: 'Report user',
            danger: true,
            enabled: !_busy,
            onTap: _openReportDialog,
          ),
        ],
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  final bool enabled;

  const _MenuTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? RMColors.danger : RMColors.textPrimary;
    return ListTile(
      enabled: enabled,
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      onTap: onTap,
    );
  }
}

class _MenuSwitchTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _MenuSwitchTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: enabled ? onChanged : null,
      activeColor: RMColors.primary,
      secondary: Icon(icon, color: RMColors.textPrimary),
      title: Text(label,
          style: TextStyle(color: RMColors.textPrimary, fontWeight: FontWeight.w600)),
      subtitle: subtitle != null
          ? Text(subtitle!, style: TextStyle(color: RMColors.textSecondary, fontSize: 12))
          : null,
    );
  }
}

class _ReportDialog extends StatefulWidget {
  final String username;
  const _ReportDialog({required this.username});

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  static const _reasons = [
    'Spam',
    'Harassment or bullying',
    'Pretending to be someone else',
    'Inappropriate content',
    'Something else',
  ];

  String _selected = _reasons.first;
  final _detailsCtrl = TextEditingController();

  @override
  void dispose() {
    _detailsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: RMColors.surface,
      title: Text('Report @${widget.username}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ..._reasons.map((r) => RadioListTile<String>(
                  value: r,
                  groupValue: _selected,
                  activeColor: RMColors.primary,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(r, style: TextStyle(color: RMColors.textPrimary, fontSize: 14)),
                  onChanged: (v) => setState(() => _selected = v!),
                )),
            SizedBox(height: 8),
            TextField(
              controller: _detailsCtrl,
              maxLines: 3,
              style: TextStyle(color: RMColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'Add details (optional)',
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop({
            'reason': _selected,
            'details': _detailsCtrl.text.trim(),
          }),
          child: Text('Submit', style: TextStyle(color: RMColors.danger)),
        ),
      ],
    );
  }
}
