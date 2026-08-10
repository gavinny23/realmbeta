import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import '../services/presence_service.dart';
import '../services/navigation_restoration_service.dart';
import '../services/supabase_service.dart';
import '../services/account_manager_service.dart';
import '../services/push_notification_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/mention_invite_dialog.dart';
import '../widgets/account_switcher_sheet.dart';
import 'feed_screen.dart';
import 'chats_screen.dart';
import 'flicks_screen.dart';
import 'chat_conversation_screen.dart';
import 'status_viewer_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  static const _lastTabPrefsKey = 'rm_home_shell_last_tab';

  int _currentIndex = 0;
  DateTime? _lastBackPressAt;

  // Keys give us a handle onto each tab's State so we can force a fresh
  // fetch every time that tab is (re)selected — see _onDestinationSelected.
  // An IndexedStack keeps every tab's widget alive in the background, but
  // "alive" isn't the same as "up to date": a tab whose first load raced
  // location/auth and lost, or whose data is just stale from sitting
  // untouched, would otherwise stay that way for the rest of the session
  // even after switching away and back.
  final _feedKey = GlobalKey<FeedScreenState>();
  final _flicksKey = GlobalKey<FlicksScreenState>();
  StreamSubscription<Map<String, dynamic>>? _mentionInviteSub;
  StreamSubscription<PendingChatAction>? _pendingChatActionSub;
  StreamSubscription<PendingStatusAction>? _pendingStatusActionSub;

  @override
  void initState() {
    super.initState();
    _restoreLastTab();
    _restoreLastScreen();
    // HomeShell only mounts once someone's actually signed in and past
    // auth, and stays alive for the whole session (see the IndexedStack
    // comment above) — the natural place to start/stop the presence
    // heartbeat in step with the app's foreground/background state.
    WidgetsBinding.instance.addObserver(this);
    PresenceService.instance.start();
    _checkForActiveMentionInvite();

    // A tap on a chat-message push notification — see
    // PushNotificationService. Subscribed here (rather than in
    // ChatsScreen) because HomeShell is the one place that outlives
    // every tab, and because a tap might be for an account that
    // isn't even the one currently active (see _handlePendingChatAction).
    _pendingChatActionSub = PushNotificationService.instance.pendingChatActions
        .listen(_handlePendingChatAction);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final initial =
          PushNotificationService.instance.consumeInitialChatAction();
      if (initial != null) _handlePendingChatAction(initial);
    });

    // A tap on a "someone you follow posted a status" push — same
    // multi-account wrinkle as chat (see _handlePendingStatusAction),
    // so this lives here rather than on FeedScreen/StatusStrip.
    _pendingStatusActionSub = PushNotificationService
        .instance.pendingStatusActions
        .listen(_handlePendingStatusAction);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final initial =
          PushNotificationService.instance.consumeInitialStatusAction();
      if (initial != null) _handlePendingStatusAction(initial);
    });
  }

  /// A tap on a chat-message push notification (cold start, resumed,
  /// or foreground — see PushNotificationService). Because every
  /// account signed in on this device shares the same FCM token (see
  /// AccountManagerService), this push may well be for an account
  /// that isn't the one currently open — [action.recipientId] is
  /// who it's actually *for*; [action.chatId] is who to open a
  /// conversation with.
  Future<void> _handlePendingChatAction(PendingChatAction action) async {
    final activeId = SupabaseService.instance.currentUser?.id;

    if (activeId == action.recipientId) {
      // Already on the right account — just open the thread. Uses
      // action.senderName as the display name since that's who this
      // conversation is with from the recipient's side.
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatConversationScreen(
            otherUserId: action.chatId,
            otherUsername: action.senderName,
          ),
        ),
      );
      return;
    }

    // Wrong account is active. Offer to switch rather than silently
    // showing nothing (or, worse, the wrong account's chat) — never
    // auto-switch without asking, since that would yank someone out
    // of whatever they were doing on the account they chose to have
    // open.
    if (!mounted) return;
    final saved = await AccountManagerService.instance.loadSavedAccounts();
    final target = saved.where((a) => a.id == action.recipientId);
    final targetLabel = target.isNotEmpty
        ? (target.first.displayName.isNotEmpty
            ? target.first.displayName
            : '@${target.first.username}')
        : 'another account';

    if (!mounted) return;
    final shouldSwitch = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: RMColors.surface,
            title: const Text('Switch account?'),
            content: Text(
              '${action.senderName} sent a message to $targetLabel, '
              'signed in on this device. Switch to that account to view it?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Not now'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Switch'),
              ),
            ],
          ),
        ) ??
        false;
    if (!shouldSwitch || !mounted) return;

    final switched =
        await AccountManagerService.instance.switchToAccount(action.recipientId);
    if (!switched) {
      // Nothing saved for that account on this device (e.g. it was
      // forgotten/signed out here since the push was sent) — nothing
      // sensible to switch to, so just let them know rather than
      // failing silently.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sign in to that account to view this message.'),
        ),
      );
      return;
    }

    // relaunchToFreshHome tears down and rebuilds HomeShell (and every
    // tab under it) from scratch, so this stashes the action in the
    // same slot a genuine cold-start tap would use — the new
    // HomeShell's initState picks it up post-frame and opens the
    // conversation, now that the right account is actually active.
    PushNotificationService.instance.stashChatActionForNextLaunch(action);
    if (!mounted) return;
    relaunchToFreshHome(context);
  }

  /// A tap on a "someone you follow posted a status" push notification.
  /// Same multi-account wrinkle as [_handlePendingChatAction] — every
  /// account signed in on this device shares one FCM token, so this
  /// push may be for a follower account other than whichever one is
  /// currently active. Unlike a chat message, viewing someone's
  /// status also marks it as seen (see markStatusViewed, which acts
  /// as `auth.uid()` — i.e. whichever account is *actually* signed
  /// in), so this can't just open the viewer against the wrong
  /// account either; the same "offer to switch" flow applies.
  Future<void> _handlePendingStatusAction(PendingStatusAction action) async {
    final activeId = SupabaseService.instance.currentUser?.id;

    if (activeId == action.recipientId) {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => StatusViewerScreen(creatorId: action.creatorId),
        ),
      );
      return;
    }

    if (!mounted) return;
    final saved = await AccountManagerService.instance.loadSavedAccounts();
    final target = saved.where((a) => a.id == action.recipientId);
    final targetLabel = target.isNotEmpty
        ? (target.first.displayName.isNotEmpty
            ? target.first.displayName
            : '@${target.first.username}')
        : 'another account';

    if (!mounted) return;
    final shouldSwitch = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: RMColors.surface,
            title: const Text('Switch account?'),
            content: Text(
              '@${action.creatorUsername} posted a status, visible to '
              '$targetLabel, signed in on this device. Switch to that '
              'account to view it?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Not now'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Switch'),
              ),
            ],
          ),
        ) ??
        false;
    if (!shouldSwitch || !mounted) return;

    final switched =
        await AccountManagerService.instance.switchToAccount(action.recipientId);
    if (!switched) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sign in to that account to view this status.'),
        ),
      );
      return;
    }

    PushNotificationService.instance.stashStatusActionForNextLaunch(action);
    if (!mounted) return;
    relaunchToFreshHome(context);
  }

  /// Checks for (and, if found, pops a dialog for) a still-pending,
  /// unexpired mention invite. Called once here on every HomeShell
  /// mount — which happens on every fresh sign-in, so logging out and
  /// back in reliably finds an invite that's still within its
  /// 10-minute window — and again below whenever a new one arrives
  /// via realtime while the app's already open.
  Future<void> _checkForActiveMentionInvite() async {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) MentionInviteDialog.maybeShow(context);
    });
    _mentionInviteSub =
        SupabaseService.instance.watchMentionInvites().listen((_) {
      if (mounted) MentionInviteDialog.maybeShow(context);
    });
  }

  /// Which bottom-nav tab was open last time this app ran — restored
  /// here so a genuine cold start (the process actually got killed,
  /// whether by the OS reclaiming memory or by the back-button fix
  /// below no longer accidentally causing that) drops someone back
  /// where they left off instead of always reopening on Realm.
  Future<void> _restoreLastTab() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt(_lastTabPrefsKey);
      if (saved != null && saved >= 0 && saved <= 2 && mounted) {
        setState(() => _currentIndex = saved);
      }
    } catch (_) {
      // Local-storage-only, best-effort — worst case this session
      // just opens on Realm same as before this existed.
    }
  }

  Future<void> _persistLastTab(int index) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_lastTabPrefsKey, index);
    } catch (_) {
      // Best-effort — losing this just means the next cold start
      // opens on Realm instead of wherever they actually were.
    }
  }

  /// The one screen deeper than a tab that a process-killed cold
  /// start can currently restore into — see
  /// [NavigationRestorationService]. Only chat conversations are
  /// wired up to save a record right now (see ChatsScreen), so this
  /// only ever has a 'chat' record to act on; anything else in
  /// storage (or nothing) is a no-op here.
  ///
  /// Waits a frame before pushing so this always runs against a fully
  /// mounted HomeShell/Scaffold — pushing during the very first
  /// build, before there's a Navigator in the tree yet, would throw.
  Future<void> _restoreLastScreen() async {
    final screen = await NavigationRestorationService.instance.load();
    if (screen == null || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      switch (screen.type) {
        case 'chat':
          final otherUserId = screen.params['otherUserId'];
          final otherUsername = screen.params['otherUsername'];
          if (otherUserId == null || otherUsername == null) return;
          // Re-save/clear around this restored push too, same as the
          // original push in ChatsScreen — otherwise backing out of
          // the restored conversation would leave the now-stale
          // record sitting there to wrongly restore again next time.
          await NavigationRestorationService.instance
              .save('chat', {'otherUserId': otherUserId, 'otherUsername': otherUsername});
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ChatConversationScreen(
                otherUserId: otherUserId,
                otherUsername: otherUsername,
              ),
            ),
          );
          await NavigationRestorationService.instance.clear();
          break;
      }
    });
  }

  void _onDestinationSelected(int index) {
    setState(() => _currentIndex = index);
    _persistLastTab(index);
    switch (index) {
      case 0:
        _feedKey.currentState?.refresh();
        break;
      case 1:
        _flicksKey.currentState?.refresh();
        break;
    }
  }

  /// System back button, intercepted here rather than left to fall
  /// through to the OS: with nothing else on the navigator stack at
  /// this level, an unhandled back press exits the app outright — a
  /// full process kill, not a pause — which is what made every
  /// "navigate away and come back" feel like a cold boot from
  /// scratch. First back press off the Realm tab returns to Realm
  /// (standard bottom-nav convention); a second press within the
  /// window below actually exits, same as most Android apps with a
  /// bottom nav.
  void _handleBackPress() {
    if (_currentIndex != 0) {
      _onDestinationSelected(0);
      return;
    }
    final now = DateTime.now();
    if (_lastBackPressAt == null ||
        now.difference(_lastBackPressAt!) > const Duration(seconds: 2)) {
      _lastBackPressAt = now;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Press back again to exit'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    SystemNavigator.pop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PresenceService.instance.stop();
    _mentionInviteSub?.cancel();
    _pendingChatActionSub?.cancel();
    _pendingStatusActionSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Same foreground/background signal DataSaverService and friends
    // key off of elsewhere in the app — resumed means "send a
    // heartbeat and resume the periodic timer", anything else
    // (paused, inactive, detached) means "stop", since a suspended
    // app can't reliably deliver a heartbeat anyway and there's no
    // point burning battery trying.
    if (state == AppLifecycleState.resumed) {
      PresenceService.instance.start();
    } else {
      PresenceService.instance.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBackPress();
      },
      child: Scaffold(
        backgroundColor: RMColors.background,
        body: IndexedStack(
          index: _currentIndex,
          // IndexedStack builds and keeps ALL of these alive simultaneously,
          // not just the visible one — that's what makes the tab-preserving
          // navigation work, but it also means a naive child has no idea
          // whether it's the one currently on screen. FlicksScreen needs
          // that signal explicitly (see isActive) so it knows when it's
          // allowed to actually play video, rather than just going by its
          // own internal notion of "active page" within its feed.
          children: [
            FeedScreen(key: _feedKey),
            FlicksScreen(key: _flicksKey, isActive: _currentIndex == 1),
            ChatsScreen(),
          ],
        ),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: RMColors.border, width: 1)),
          ),
          child: NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: _onDestinationSelected,
            backgroundColor: RMColors.surface,
            indicatorColor: RMColors.primaryDim,
            height: 64,
            destinations: [
              NavigationDestination(
                icon: Icon(Icons.explore_outlined, color: RMColors.textSecondary),
                selectedIcon: Icon(Icons.explore_rounded, color: RMColors.primary),
                label: 'Realm',
              ),
              NavigationDestination(
                icon: Icon(Icons.movie_creation_outlined,
                    color: RMColors.textSecondary),
                selectedIcon:
                    Icon(Icons.movie_creation_rounded, color: RMColors.primary),
                label: 'Flicks',
              ),
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline_rounded,
                    color: RMColors.textSecondary),
                selectedIcon:
                    Icon(Icons.chat_bubble_rounded, color: RMColors.primary),
                label: 'Chats',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
