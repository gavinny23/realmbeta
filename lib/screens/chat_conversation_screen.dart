import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/supabase_service.dart';
import '../services/app_storage_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/cheat_code_trigger.dart';
import '../widgets/emoji_input.dart';
import '../widgets/emoji_picker_panel.dart';
import '../widgets/chat_background.dart';
import '../widgets/mention_composer_field.dart';
import '../widgets/presence_avatar.dart';
import 'chat_profile_options_screen.dart';

class ChatConversationScreen extends StatefulWidget {
  final String otherUserId;
  final String otherUsername;

  /// Instant placeholders for the app bar's avatar/status — passed
  /// down by callers that already have them on hand (the chat list),
  /// so the header doesn't pop in empty. Always refreshed against
  /// `get_public_profile` in [_init] regardless, since callers that
  /// only know the id/username (e.g. a push notification tap) won't
  /// have these.
  final String? otherAvatarUrl;
  final DateTime? otherLastActiveAt;

  ChatConversationScreen({
    super.key,
    required this.otherUserId,
    required this.otherUsername,
    this.otherAvatarUrl,
    this.otherLastActiveAt,
  });

  @override
  State<ChatConversationScreen> createState() =>
      _ChatConversationScreenState();
}

class _ChatConversationScreenState extends State<ChatConversationScreen> {
  final _msgCtrl = MentionTextEditingController();
  final _msgFocus = FocusNode();
  final _scrollCtrl = ScrollController();
  StreamSubscription<List<Map<String, dynamic>>>? _sub;

  // Whether the emoji panel is showing in place of the system keyboard.
  // Mirrors the WhatsApp/Telegram pattern: tapping the emoji icon
  // dismisses the keyboard and swaps in the panel; tapping the text
  // field (or the icon again) swaps back.
  bool _showEmojiPanel = false;

  // Messages Supabase has actually persisted for this thread.
  List<Map<String, dynamic>> _serverMessages = [];

  // Messages typed locally that haven't been confirmed by the server
  // yet — either still in flight, or queued because the send failed
  // (offline). Kept in AppStorageService (durable — not tied to any
  // disposable-content cache) so a queued message survives an app
  // restart instead of silently vanishing.
  List<Map<String, dynamic>> _outbox = [];

  bool _loading = true;
  bool _sending = false;
  bool _flushingOutbox = false;
  String? _error;

  // Header (avatar/online status) + relationship state — refreshed
  // from get_public_profile independently of the message list, and
  // re-checked whenever the person returns from the chat details
  // screen (block state can change there).
  String? _otherAvatarUrl;
  DateTime? _otherLastActiveAt;
  bool _isBlockedByMe = false;

  // In-chat message search, opened from the chat details screen.
  bool _showSearch = false;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  String get _cacheKey => 'chat_messages_${widget.otherUserId}';
  String get _outboxKey => 'chat_outbox_${widget.otherUserId}';

  /// Server-confirmed history plus anything still queued locally,
  /// oldest first. This is what actually renders — it's how a message
  /// you just sent (or typed while offline) never appears to "lose"
  /// it, even before it round-trips through Supabase.
  List<Map<String, dynamic>> get _messages {
    final merged = <Map<String, dynamic>>[..._serverMessages];
    for (final pending in _outbox) {
      final alreadyLanded = _serverMessages.any((m) =>
          m['sender_id'] == pending['sender_id'] &&
          m['content'] == pending['content'] &&
          m['created_at'] == pending['created_at']);
      if (!alreadyLanded) merged.add(pending);
    }
    merged.sort((a, b) {
      final at =
          DateTime.tryParse(a['created_at'] as String? ?? '') ?? DateTime.now();
      final bt =
          DateTime.tryParse(b['created_at'] as String? ?? '') ?? DateTime.now();
      return at.compareTo(bt);
    });
    return merged;
  }

  @override
  void initState() {
    super.initState();
    _otherAvatarUrl = widget.otherAvatarUrl;
    _otherLastActiveAt = widget.otherLastActiveAt;
    _init();
    _loadProfileHeader();
  }

  /// Refreshes the avatar/online-status/block state shown in the app
  /// bar and chat details screen. Best-effort — a failure just means
  /// the header keeps showing whatever [widget] was constructed with.
  Future<void> _loadProfileHeader() async {
    try {
      final profile =
          await SupabaseService.instance.fetchPublicProfile(widget.otherUserId);
      final relationship =
          await SupabaseService.instance.fetchChatRelationship(widget.otherUserId);
      if (!mounted) return;
      setState(() {
        if (profile != null) {
          _otherAvatarUrl = profile.avatarUrl;
          _otherLastActiveAt = profile.lastActiveAt;
        }
        _isBlockedByMe = relationship['is_blocked_by_me'] ?? false;
      });
    } catch (_) {
      // Best-effort — see doc comment.
    }
  }

  Future<void> _openChatDetails() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => ChatProfileOptionsScreen(
          otherUserId: widget.otherUserId,
          otherUsername: widget.otherUsername,
          otherAvatarUrl: _otherAvatarUrl,
          otherLastActiveAt: _otherLastActiveAt,
        ),
      ),
    );
    if (!mounted || result == null) return;
    switch (result['action']) {
      case 'search':
        setState(() => _showSearch = true);
        break;
      case 'blocked':
        setState(() => _isBlockedByMe = result['value'] == true);
        if (result['value'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${widget.otherUsername} is blocked.')),
          );
        }
        break;
    }
  }

  void _toggleSearch() {
    setState(() {
      _showSearch = !_showSearch;
      if (!_showSearch) {
        _searchCtrl.clear();
        _searchQuery = '';
      }
    });
  }

  Future<void> _init() async {
    // 1. Cache-first: show whatever was on screen last time immediately,
    // no spinner, works with zero connection.
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

    // 2. Kick off a fresh fetch in the background. Replace on success;
    // on failure (offline) just keep showing the cached thread.
    try {
      final history = await SupabaseService.instance
          .fetchMessages(otherUserId: widget.otherUserId);
      if (mounted) {
        setState(() {
          _serverMessages = history;
          _loading = false;
          _error = null;
        });
        _scrollToEnd();
      }
      await AppStorageService.instance.saveList(_cacheKey, history);
    } catch (e) {
      if (mounted && _serverMessages.isEmpty) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }

    // Live updates for this thread — new messages just append, no
    // manual refresh needed while the conversation is open. Each
    // successful emission also means we have connectivity, so it's a
    // good moment to retry anything still stuck in the outbox.
    _sub = SupabaseService.instance
        .watchMessages(otherUserId: widget.otherUserId)
        .listen((rows) {
      if (!mounted) return;
      setState(() => _serverMessages = rows);
      AppStorageService.instance.saveList(_cacheKey, rows);
      _scrollToEnd();
      _flushOutbox();
    });

    SupabaseService.instance.markConversationRead(widget.otherUserId);
    _flushOutbox();
  }

  /// Retries every queued outbound message in order. Stops at the
  /// first failure — if we're still offline there's no point hammering
  /// the rest of the queue, and preserving order matters for a chat.
  Future<void> _flushOutbox() async {
    if (_flushingOutbox || _outbox.isEmpty) return;
    _flushingOutbox = true;
    try {
      final queue = List<Map<String, dynamic>>.from(_outbox);
      for (final pending in queue) {
        try {
          await SupabaseService.instance.sendMessage(
            recipientId: widget.otherUserId,
            content: pending['content'] as String,
          );
          if (mounted) {
            setState(() =>
                _outbox.removeWhere((m) => m['_localId'] == pending['_localId']));
          } else {
            _outbox.removeWhere((m) => m['_localId'] == pending['_localId']);
          }
          await AppStorageService.instance.saveList(_outboxKey, _outbox);
        } catch (_) {
          // Still offline (or the request genuinely failed) — leave it
          // queued and stop; we'll try again on the next stream tick.
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
    if (text.isEmpty || _isBlockedByMe) return;
    final me = SupabaseService.instance.currentUser?.id;
    if (me == null) return;

    // Anyone @mentioned in this message (other than the person you're
    // already talking to) gets invited into a new 3-person group once
    // the message itself is safely sent — see invite_mentioned_user in
    // v26-migration.sql. Must be read before clear() below wipes the
    // controller's text.
    //
    // Deliberately allMentionsInText(), not mentionsInText(): local
    // resolution depends on a 250ms-debounced search, so sending fast
    // right after typing a valid @username can beat it. The server
    // RPC is the real validity check (existence + tagging/discovery
    // settings), so every @word gets a shot at it instead of silently
    // dropping ones the UI hadn't highlighted blue yet.
    final mentioned = _msgCtrl.allMentionsInText();

    _msgCtrl.clear();

    // Optimistic add: shows instantly with a single "sending" tick,
    // regardless of whether the network call below succeeds straight
    // away, queues, or fails outright.
    final pending = {
      '_localId': '${DateTime.now().microsecondsSinceEpoch}',
      '_pending': true,
      'sender_id': me,
      'recipient_id': widget.otherUserId,
      'content': text,
      'created_at': DateTime.now().toIso8601String(),
      'read_at': null,
    };
    setState(() {
      _outbox.add(pending);
      _sending = true;
    });
    await AppStorageService.instance.saveList(_outboxKey, _outbox);
    _scrollToEnd();

    try {
      await SupabaseService.instance.sendMessage(
        recipientId: widget.otherUserId,
        content: text,
      );
      if (mounted) {
        setState(() =>
            _outbox.removeWhere((m) => m['_localId'] == pending['_localId']));
      } else {
        _outbox.removeWhere((m) => m['_localId'] == pending['_localId']);
      }
      await AppStorageService.instance.saveList(_outboxKey, _outbox);
      _sendMentionInvites(mentioned, text);
    } catch (_) {
      // Offline (or a transient failure) — leave it queued in the
      // outbox. It's already persisted to cache above, shows with a
      // "sending" tick, and _flushOutbox() will retry it later.
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Invites everyone @mentioned in a just-sent message into a new
  /// 3-person group with the two of you, skipping the person you're
  /// already chatting with (mentioning them again is a no-op). Runs
  /// fire-and-forget — a failed invite (e.g. they turned off tagging
  /// between typing and sending) shouldn't interrupt the chat.
  Future<void> _sendMentionInvites(Set<String> mentioned, String text) async {
    // TEMPORARY diagnostics via on-screen SnackBar instead of
    // debugPrint — no attached console in a Termux/proot build, so
    // this is the only way to actually see what's happening here.
    // Revert to the silent catch(_) once confirmed working.
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('mentions found: $mentioned'), duration: Duration(seconds: 4)),
      );
    }
    for (final username in mentioned) {
      if (username.toLowerCase() == widget.otherUsername.toLowerCase()) continue;
      try {
        final result = await SupabaseService.instance.inviteMentionedUser(
          otherParticipantId: widget.otherUserId,
          invitedUsername: username,
          messageContent: text,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('invite($username) -> ${result ?? "NULL"}'),
                duration: Duration(seconds: 6)),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('invite($username) ERROR: $e'),
                backgroundColor: RMColors.danger,
                duration: Duration(seconds: 8)),
          );
        }
      }
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _msgCtrl.dispose();
    _msgFocus.dispose();
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Inserts at the cursor and steps backspace by full grapheme
  /// cluster — see `widgets/emoji_input.dart` for the shared logic
  /// used by every other emoji-enabled field in the app too.
  void _insertEmoji(String emoji) => insertEmojiIntoController(_msgCtrl, emoji);

  void _backspaceEmoji() => backspaceEmojiFromController(_msgCtrl);

  void _toggleEmojiPanel() {
    if (_showEmojiPanel) {
      setState(() => _showEmojiPanel = false);
      _msgFocus.requestFocus();
    } else {
      _msgFocus.unfocus();
      setState(() => _showEmojiPanel = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = SupabaseService.instance.currentUser?.id;
    var messages = _messages;
    if (_showSearch && _searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      messages = messages
          .where((m) =>
              (m['content'] as String? ?? '').toLowerCase().contains(q))
          .toList();
    }

    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        titleSpacing: 0,
        backgroundColor: RMColors.background,
        title: _showSearch
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: TextStyle(color: RMColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Search this conversation',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _searchQuery = v),
              )
            : InkWell(
                onTap: _openChatDetails,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      PresenceAvatar(
                        radius: 18,
                        backgroundColor: RMColors.primaryDim,
                        avatarUrl: _otherAvatarUrl,
                        lastActiveAt: _otherLastActiveAt,
                        badgeBorderColor: RMColors.background,
                        placeholder: Icon(Icons.person_rounded,
                            color: RMColors.primary, size: 18),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.otherUsername,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: RMColors.textPrimary, fontSize: 16),
                            ),
                            if (PresenceAvatar.statusLine(_otherLastActiveAt) !=
                                null)
                              Text(
                                PresenceAvatar.statusLine(_otherLastActiveAt)!,
                                style: TextStyle(
                                  color: PresenceAvatar.isOnline(
                                          _otherLastActiveAt)
                                      ? RMColors.success
                                      : RMColors.textHint,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        actions: [
          IconButton(
            icon: Icon(_showSearch ? Icons.close_rounded : Icons.search_rounded,
                color: RMColors.textSecondary),
            tooltip: _showSearch ? 'Close search' : 'Search',
            onPressed: _toggleSearch,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ChatBackground(
              child: _loading
                  ? Center(
                      child:
                          CircularProgressIndicator(color: RMColors.primary))
                  : _error != null
                      ? Center(
                          child: Padding(
                            padding: EdgeInsets.all(28),
                            child: Text(_error!,
                                textAlign: TextAlign.center,
                                style:
                                    TextStyle(color: RMColors.textSecondary)),
                          ),
                        )
                      : messages.isEmpty
                          ? Center(
                              child: Text(
                                _showSearch && _searchQuery.isNotEmpty
                                    ? 'No messages match "$_searchQuery".'
                                    : 'Say hi to ${widget.otherUsername} 👋',
                                textAlign: TextAlign.center,
                                style:
                                    TextStyle(color: RMColors.textSecondary),
                              ),
                            )
                          : ListView.builder(
                              controller: _scrollCtrl,
                              padding: EdgeInsets.all(16),
                              itemCount: messages.length,
                              itemBuilder: (context, i) {
                                final m = messages[i];
                                final mine = m['sender_id'] == me;
                                final createdAt = DateTime.tryParse(
                                        m['created_at'] as String? ?? '') ??
                                    DateTime.now();
                                return _MessageBubble(
                                  text: m['content'] as String? ?? '',
                                  time: createdAt,
                                  mine: mine,
                                  pending: m['_pending'] == true,
                                  read: m['read_at'] != null,
                                );
                              },
                            ),
            ),
          ),
          if (_isBlockedByMe)
            SafeArea(
              top: false,
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                color: RMColors.surfaceAlt,
                child: Text(
                  'You blocked @${widget.otherUsername}. Unblock them from Chat details to send messages again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: RMColors.textSecondary, fontSize: 12),
                ),
              ),
            )
          else
            SafeArea(
              top: false,
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: Row(
                      children: [
                        IconButton(
                          icon: Icon(
                            _showEmojiPanel
                                ? Icons.keyboard_rounded
                                : Icons.emoji_emotions_outlined,
                            color: RMColors.textSecondary,
                          ),
                          tooltip: 'Emoji',
                          onPressed: _toggleEmojiPanel,
                        ),
                        Expanded(
                          child: MentionComposerField(
                            controller: _msgCtrl,
                            focusNode: _msgFocus,
                            minLines: 1,
                            maxLines: 4,
                            textCapitalization: TextCapitalization.sentences,
                            onChanged: (v) =>
                                CheatCodeTrigger.watch(context, _msgCtrl, v),
                            onTap: () {
                              // Tapping back into the field always hands
                              // control back to the system keyboard, even
                              // if the emoji panel was open.
                              if (_showEmojiPanel) {
                                setState(() => _showEmojiPanel = false);
                              }
                            },
                            decoration: InputDecoration(
                              hintText: 'Message... (@ to tag someone)',
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
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
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : Icon(Icons.send_rounded),
                        ),
                      ],
                    ),
                  ),
                  if (_showEmojiPanel)
                    EmojiPickerPanel(
                      onEmojiSelected: _insertEmoji,
                      onBackspace: _backspaceEmoji,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final String text;
  final DateTime time;
  final bool mine;
  final bool pending;
  final bool read;

  const _MessageBubble({
    required this.text,
    required this.time,
    required this.mine,
    this.pending = false,
    this.read = false,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(bottom: 10),
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.72),
        decoration: BoxDecoration(
          color: mine ? RMColors.primary : RMColors.surface,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
          border: mine ? null : Border.all(color: RMColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              style: TextStyle(
                color: mine ? Colors.white : RMColors.textPrimary,
                fontSize: 14,
                height: 1.35,
              ),
            ),
            SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DateFormat('h:mm a').format(time),
                  style: TextStyle(
                    color: mine ? Colors.white70 : RMColors.textHint,
                    fontSize: 10,
                  ),
                ),
                if (mine) ...[
                  SizedBox(width: 4),
                  MessageTicks(pending: pending, read: read),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// WhatsApp-style status ticks for a message the current user sent:
///  - a single outline clock while it's still queued/in flight
///    (typed offline, or the request hasn't confirmed yet)
///  - a double grey check once Supabase has persisted it
///  - a double blue check once the recipient has read it
class MessageTicks extends StatelessWidget {
  final bool pending;
  final bool read;

  const MessageTicks({super.key, required this.pending, required this.read});

  @override
  Widget build(BuildContext context) {
    if (pending) {
      return Icon(Icons.schedule_rounded, size: 13, color: Colors.white70);
    }
    return Icon(
      Icons.done_all_rounded,
      size: 15,
      color: read ? Color(0xFF4FC3F7) : Colors.white70,
    );
  }
}
