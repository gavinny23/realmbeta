import 'dart:async';
import 'package:flutter/material.dart';
import '../services/app_storage_service.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/presence_avatar.dart';
import '../screens/chat_conversation_screen.dart';
import '../screens/chats_screen.dart';
import 'status_list_tab.dart';

/// Left-side drawer with two tabs: Status (a vertical, WhatsApp-Status-
/// tab-style list of who currently has an active status, replacing the
/// old horizontal strip at the top of the feed) and Messages (the
/// latest profiles the current user has exchanged messages with, max
/// [_limit]). While the drawer is open, a new incoming message pops up
/// a small bubble right on top of that profile's row in the Messages
/// tab for 15 seconds, then fades away on its own.
class MessagesDrawer extends StatefulWidget {
  const MessagesDrawer({super.key});

  @override
  State<MessagesDrawer> createState() => _MessagesDrawerState();
}

class _MessagesDrawerState extends State<MessagesDrawer>
    with SingleTickerProviderStateMixin {
  static const _limit = 6;
  static const _popupDuration = Duration(seconds: 15);

  // Own key (not ChatsScreen's 'conversations') because this only
  // ever fetches DMs, not the DM+SMS merged list ChatsScreen shows —
  // sharing a key would mean whichever of the two saved last quietly
  // clobbers the other's cache with a narrower list.
  static const _cacheKey = 'dm_conversations';

  List<Map<String, dynamic>> _conversations = [];
  bool _loading = true;
  String? _error;

  StreamSubscription<Map<String, dynamic>>? _incomingSub;

  // otherUserId -> latest message text to show as a popup bubble.
  final Map<String, String> _popups = {};
  final Map<String, Timer> _popupTimers = {};

  late final TabController _tabController;
  final _statusListKey = GlobalKey<StatusListTabState>();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      // Re-check whichever tab just became active, same "reselect to
      // refresh" contract the old status strip had via feed_screen's
      // GlobalKey.
      if (_tabController.index == 0) {
        _statusListKey.currentState?.refresh();
      } else {
        _load();
      }
    });
    _loadCached();
    _load();
    // Both directions: an incoming message needs the popup bubble too,
    // but an outgoing one (sent from a chat opened some other way,
    // e.g. from "All chats") still needs to move that conversation to
    // the top and refresh its preview text here — otherwise this list
    // sits stale until the drawer's Messages tab happens to get
    // reselected.
    _incomingSub =
        SupabaseService.instance.watchConversationActivity().listen(_onActivity);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _incomingSub?.cancel();
    for (final t in _popupTimers.values) {
      t.cancel();
    }
    super.dispose();
  }

  /// Shows whatever conversation list was cached last time immediately
  /// — no spinner, works with zero connection.
  Future<void> _loadCached() async {
    final cached = await AppStorageService.instance.loadList(_cacheKey);
    if (cached != null && cached.isNotEmpty && mounted && _conversations.isEmpty) {
      setState(() {
        _conversations = cached.take(_limit).toList();
        _loading = false;
      });
    }
  }

  Future<void> _load() async {
    try {
      final all = await SupabaseService.instance.fetchConversations();
      if (!mounted) return;
      setState(() {
        _conversations = all.take(_limit).toList();
        _loading = false;
        _error = null;
      });
      await AppStorageService.instance.saveList(_cacheKey, all);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // Already showing cached conversations — don't replace them
        // with an error screen just because the refresh failed
        // offline.
        _error = _conversations.isEmpty ? e.toString() : null;
      });
    }
  }

  void _onActivity(Map<String, dynamic> message) async {
    final me = SupabaseService.instance.currentUser?.id;
    final senderId = message['sender_id'] as String?;
    final recipientId = message['recipient_id'] as String?;
    final content = message['content'] as String? ?? '';
    if (senderId == null) return;

    // Refresh the list first so a message from/to someone not yet in
    // the top 6 still gets a row (and therefore a place to anchor the
    // popup) before the bubble is shown. This also covers the user's
    // own outgoing messages, so the preview stays current the moment
    // they hit send, not just when someone replies.
    await _load();
    if (!mounted) return;

    // Only genuinely incoming messages get the "new message" popup —
    // for an outgoing one the list refresh above is all that's needed.
    if (recipientId != me) return;

    setState(() => _popups[senderId] = content);

    _popupTimers[senderId]?.cancel();
    _popupTimers[senderId] = Timer(_popupDuration, () {
      if (!mounted) return;
      setState(() => _popups.remove(senderId));
    });
  }

  Future<void> _openConversation(Map<String, dynamic> convo) async {
    final otherUserId = convo['other_user_id'] as String;
    setState(() => _popups.remove(otherUserId));
    _popupTimers.remove(otherUserId)?.cancel();

    Navigator.of(context).pop(); // close the drawer first
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatConversationScreen(
          otherUserId: otherUserId,
          otherUsername: convo['other_username'] as String? ?? 'unknown',
        ),
      ),
    );
    _load();
  }

  void _openAllChats() {
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: RMColors.surface,
      width: 300,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Text(
                'Realm',
                style: TextStyle(
                  color: RMColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            TabBar(
              controller: _tabController,
              labelColor: RMColors.primary,
              unselectedLabelColor: RMColors.textSecondary,
              indicatorColor: RMColors.primary,
              labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
              unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
              tabs: const [
                Tab(text: 'Status'),
                Tab(text: 'Messages'),
              ],
            ),
            Divider(height: 1, color: RMColors.border),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  StatusListTab(key: _statusListKey),
                  _buildMessagesBody(),
                ],
              ),
            ),
            AnimatedBuilder(
              animation: _tabController.animation ?? _tabController,
              builder: (context, _) {
                // Only relevant to the Messages tab — hidden while
                // Status is showing (and while mid-swipe between them).
                if ((_tabController.animation?.value ?? _tabController.index.toDouble()) < 0.5) {
                  return const SizedBox.shrink();
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Divider(height: 1, color: RMColors.border),
                    ListTile(
                      leading: Icon(Icons.chat_bubble_outline_rounded,
                          color: RMColors.primary),
                      title: Text('All chats',
                          style: TextStyle(
                              color: RMColors.textPrimary,
                              fontWeight: FontWeight.w600)),
                      onTap: _openAllChats,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessagesBody() {
    if (_loading && _conversations.isEmpty) {
      return Center(
          child: CircularProgressIndicator(color: RMColors.primary));
    }
    if (_error != null && _conversations.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            "Couldn't load messages.",
            textAlign: TextAlign.center,
            style: TextStyle(color: RMColors.textSecondary),
          ),
        ),
      );
    }
    if (_conversations.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No conversations yet.',
            textAlign: TextAlign.center,
            style: TextStyle(color: RMColors.textSecondary),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _conversations.length,
      itemBuilder: (context, i) => _ProfileRow(
        convo: _conversations[i],
        popupText: _popups[_conversations[i]['other_user_id']],
        onTap: () => _openConversation(_conversations[i]),
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  final Map<String, dynamic> convo;
  final String? popupText;
  final VoidCallback onTap;

  const _ProfileRow({
    required this.convo,
    required this.popupText,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final username = convo['other_username'] as String? ?? 'unknown';
    final avatarUrl = convo['other_avatar_url'] as String?;
    final lastActiveAt =
        DateTime.tryParse(convo['other_last_active_at'] as String? ?? '');
    final lastMessage = convo['last_message'] as String? ?? '';
    final unread = (convo['unread_count'] as num?)?.toInt() ?? 0;
    final hasPopup = popupText != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    PresenceAvatar(
                      radius: 22,
                      backgroundColor: RMColors.primaryDim,
                      avatarUrl: avatarUrl,
                      lastActiveAt: lastActiveAt,
                      placeholder: Icon(Icons.person_rounded, color: RMColors.primary),
                    ),
                    if (unread > 0 && !hasPopup)
                      Positioned(
                        right: -2,
                        top: -2,
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: RMColors.primary,
                            border:
                                Border.all(color: RMColors.surface, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        username,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: RMColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: hasPopup
                            ? _PopupBubble(
                                key: ValueKey('popup-${convo['other_user_id']}'),
                                text: popupText!,
                              )
                            : Text(
                                lastMessage,
                                key: const ValueKey('last-message'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: RMColors.textSecondary,
                                  fontSize: 12.5,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "new message" bubble anchored right under a profile's name in
/// the drawer — appears in place of the last-message preview for as
/// long as the message is fresh (managed by the parent's 15s timer).
class _PopupBubble extends StatelessWidget {
  final String text;

  const _PopupBubble({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: RMColors.primary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.mark_chat_unread_rounded, color: Colors.white, size: 12),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
