import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/supabase_service.dart';
import '../services/app_storage_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/cheat_code_trigger.dart';
import '../widgets/chat_background.dart';
import '../widgets/mention_composer_field.dart';

/// A group chat, always exactly the people who are (or were) in it —
/// there's no name field at all. The header and chat-list row both
/// just render a live, comma-separated list of usernames, computed
/// from `group_chat_participants` (see v26-migration.sql).
class GroupChatScreen extends StatefulWidget {
  final String chatId;

  const GroupChatScreen({super.key, required this.chatId});

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _msgCtrl = MentionTextEditingController();
  final _scrollCtrl = ScrollController();
  StreamSubscription<List<Map<String, dynamic>>>? _sub;

  List<Map<String, dynamic>> _serverMessages = [];
  List<Map<String, dynamic>> _outbox = [];
  List<Map<String, dynamic>> _participants = [];

  bool _loading = true;
  bool _sending = false;
  bool _flushingOutbox = false;
  bool _iHaveLeft = false;
  String? _error;

  String get _cacheKey => 'group_messages_${widget.chatId}';
  String get _outboxKey => 'group_outbox_${widget.chatId}';
  String? get _me => SupabaseService.instance.currentUser?.id;

  /// Comma-separated usernames of everyone still active, excluding
  /// yourself — this *is* the chat's name, computed live rather than
  /// stored anywhere.
  String get _title {
    final others = _participants.where((p) =>
        p['user_id'] != _me && p['left_at'] == null);
    if (others.isEmpty) return 'Group chat';
    return others.map((p) => p['username'] as String? ?? '?').join(', ');
  }

  List<Map<String, dynamic>> get _messages {
    final merged = <Map<String, dynamic>>[..._serverMessages];
    for (final pending in _outbox) {
      final landed = _serverMessages.any((m) =>
          m['sender_id'] == pending['sender_id'] &&
          m['content'] == pending['content'] &&
          m['created_at'] == pending['created_at']);
      if (!landed) merged.add(pending);
    }
    merged.sort((a, b) {
      final at = DateTime.tryParse(a['created_at'] as String? ?? '') ?? DateTime.now();
      final bt = DateTime.tryParse(b['created_at'] as String? ?? '') ?? DateTime.now();
      return at.compareTo(bt);
    });
    return merged;
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final cachedMessages = await AppStorageService.instance.loadList(_cacheKey);
    final cachedOutbox = await AppStorageService.instance.loadList(_outboxKey);
    if (mounted) {
      setState(() {
        if (cachedMessages != null) _serverMessages = cachedMessages;
        if (cachedOutbox != null) _outbox = cachedOutbox;
        if (cachedMessages != null) _loading = false;
      });
      if (cachedMessages != null) _scrollToEnd();
    }

    try {
      final participants =
          await SupabaseService.instance.fetchGroupParticipants(widget.chatId);
      final history = await SupabaseService.instance.fetchGroupMessages(widget.chatId);
      if (mounted) {
        setState(() {
          _participants = participants;
          _serverMessages = history;
          _iHaveLeft = participants.any((p) => p['user_id'] == _me && p['left_at'] != null);
          _loading = false;
          _error = null;
        });
        _scrollToEnd();
      }
      await AppStorageService.instance.saveList(_cacheKey, history);
    } catch (e) {
      if (mounted && _serverMessages.isEmpty) {
        setState(() { _error = e.toString(); _loading = false; });
      }
    }

    _sub = SupabaseService.instance.watchGroupMessages(widget.chatId).listen((rows) {
      if (!mounted) return;
      setState(() => _serverMessages = rows);
      AppStorageService.instance.saveList(_cacheKey, rows);
      _scrollToEnd();
      _flushOutbox();
    });

    _flushOutbox();
  }

  Future<void> _flushOutbox() async {
    if (_flushingOutbox || _outbox.isEmpty) return;
    _flushingOutbox = true;
    try {
      final queue = List<Map<String, dynamic>>.from(_outbox);
      for (final pending in queue) {
        try {
          await SupabaseService.instance.sendGroupMessage(
            chatId: widget.chatId,
            content: pending['content'] as String,
          );
          if (mounted) {
            setState(() => _outbox.removeWhere((m) => m['_localId'] == pending['_localId']));
          } else {
            _outbox.removeWhere((m) => m['_localId'] == pending['_localId']);
          }
          await AppStorageService.instance.saveList(_outboxKey, _outbox);
        } catch (_) {
          break;
        }
      }
    } finally {
      _flushingOutbox = false;
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _iHaveLeft) return;
    final me = _me;
    if (me == null) return;

    _msgCtrl.clear();

    final pending = {
      '_localId': '${DateTime.now().microsecondsSinceEpoch}',
      '_pending': true,
      'chat_id': widget.chatId,
      'sender_id': me,
      'content': text,
      'created_at': DateTime.now().toIso8601String(),
    };
    setState(() { _outbox.add(pending); _sending = true; });
    await AppStorageService.instance.saveList(_outboxKey, _outbox);
    _scrollToEnd();

    try {
      await SupabaseService.instance
          .sendGroupMessage(chatId: widget.chatId, content: text);
      if (mounted) {
        setState(() => _outbox.removeWhere((m) => m['_localId'] == pending['_localId']));
      } else {
        _outbox.removeWhere((m) => m['_localId'] == pending['_localId']);
      }
      await AppStorageService.instance.saveList(_outboxKey, _outbox);
    } catch (_) {
      // Left queued — retried by _flushOutbox() later.
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _showLeaveOptions() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: RMColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 8),
            Text('Leave this chat',
                style: TextStyle(
                    color: RMColors.textPrimary, fontWeight: FontWeight.w700, fontSize: 16)),
            SizedBox(height: 4),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Your messages can stay for the others, or be removed for everyone.',
                textAlign: TextAlign.center,
                style: TextStyle(color: RMColors.textSecondary, fontSize: 13),
              ),
            ),
            SizedBox(height: 12),
            ListTile(
              leading: Icon(Icons.logout_rounded, color: RMColors.primary),
              title: Text('Leave chat'),
              subtitle: Text('Your messages stay for everyone else',
                  style: TextStyle(fontSize: 12)),
              onTap: () => Navigator.pop(context, 'leave'),
            ),
            ListTile(
              leading: Icon(Icons.delete_forever_rounded, color: RMColors.danger),
              title: Text('Delete my messages & leave'),
              subtitle: Text('Removes everything you sent for everyone',
                  style: TextStyle(fontSize: 12)),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
            SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: RMColors.surface,
        title: Text(choice == 'delete' ? 'Delete & leave?' : 'Leave chat?'),
        content: Text(choice == 'delete'
            ? "This removes every message you've sent here for everyone, then removes you from the chat. This can't be undone."
            : "You'll be removed from the chat, but your messages stay for the others."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(choice == 'delete' ? 'Delete & leave' : 'Leave',
                style: TextStyle(color: RMColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await SupabaseService.instance.leaveGroupChat(
        chatId: widget.chatId,
        deleteMessages: choice == 'delete',
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not leave: $e')));
      }
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        backgroundColor: RMColors.background,
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: RMColors.primaryDim,
              child: Icon(Icons.groups_rounded, color: RMColors.primary, size: 16),
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(_title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15)),
            ),
          ],
        ),
        actions: [
          if (!_iHaveLeft)
            IconButton(
              icon: Icon(Icons.exit_to_app_rounded),
              tooltip: 'Leave chat',
              onPressed: _showLeaveOptions,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: ChatBackground(child: _buildMessages())),
          if (_iHaveLeft)
            Padding(
              padding: EdgeInsets.all(16),
              child: Text("You've left this chat.",
                  style: TextStyle(color: RMColors.textHint)),
            )
          else
            SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: MentionComposerField(
                        controller: _msgCtrl,
                        minLines: 1,
                        maxLines: 4,
                        textCapitalization: TextCapitalization.sentences,
                        onChanged: (v) => CheatCodeTrigger.watch(context, _msgCtrl, v),
                        decoration: InputDecoration(
                          hintText: 'Message... (@ to tag someone)',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _sending ? null : _send,
                      icon: _sending
                          ? SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Icon(Icons.send_rounded, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMessages() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: RMColors.primary));
    }
    if (_error != null && _messages.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(_error!,
              textAlign: TextAlign.center, style: TextStyle(color: RMColors.textSecondary)),
        ),
      );
    }
    if (_messages.isEmpty) {
      return Center(
        child: Text('No messages yet.', style: TextStyle(color: RMColors.textSecondary)),
      );
    }
    final byId = {for (final p in _participants) p['user_id'] as String: p};
    return ListView.builder(
      controller: _scrollCtrl,
      padding: EdgeInsets.all(16),
      itemCount: _messages.length,
      itemBuilder: (context, i) {
        final m = _messages[i];
        final mine = m['sender_id'] == _me;
        final senderUsername = byId[m['sender_id']]?['username'] as String? ?? 'unknown';
        final createdAt =
            DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now();
        return Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (!mine)
                Padding(
                  padding: EdgeInsets.only(left: 4, bottom: 2),
                  child: Text('@$senderUsername',
                      style: TextStyle(
                          color: RMColors.mention, fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              Row(
                mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: mine ? RMColors.primary : RMColors.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: mine ? null : Border.all(color: RMColors.border),
                      ),
                      child: Text(m['content'] as String? ?? '',
                          style: TextStyle(color: mine ? Colors.white : RMColors.textPrimary)),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: EdgeInsets.only(top: 2, left: 4, right: 4),
                child: Text(DateFormat('h:mm a').format(createdAt),
                    style: TextStyle(color: RMColors.textHint, fontSize: 10)),
              ),
            ],
          ),
        );
      },
    );
  }
}
