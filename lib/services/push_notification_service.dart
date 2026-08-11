import 'dart:async';
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:reply_bridge/reply_bridge.dart';
import '../models/news_article.dart';
import 'account_manager_service.dart';
import 'supabase_service.dart';

/// Top-level dispatcher for a notification response that arrives while
/// nothing is running at all — the app is fully terminated and, unlike
/// a plain tap, this one doesn't launch it back up either. Android
/// spins up a dedicated, short-lived background isolate for this
/// (mirrors `_firebaseMessagingBackgroundHandler` in main.dart), so —
/// same as that handler — this must be a top-level function, not a
/// method, and this isolate has none of the main isolate's state:
/// no Flutter binding, no `.env` loaded, no Supabase client, nothing.
/// Only ever fires for actions marked `showsUserInterface: false`
/// (currently just `reply`); every other action either opens the app
/// itself or is handled by [PushNotificationService.init]'s
/// foreground callback once the app catches up.
@pragma('vm:entry-point')
void chatReplyBackgroundDispatcher(NotificationResponse response) {
  // This isolate starts completely bare — every plugin call anywhere
  // downstream of here (secure storage, http, even this same plugin's
  // own `.show()` to update the notification) goes over a platform
  // channel, and none of those work until a binding exists to carry
  // them. Skip this and every one of those calls throws immediately;
  // since [handleChatReply] wraps its work in try/catches that
  // recover rather than crash, that used to fail *silently* — the
  // reply spinner would just hang, with no POST ever sent and no
  // error notification shown, because even the fallback path needs
  // this same binding to render anything at all. Must be the very
  // first line, before touching payload/response any further.
  WidgetsFlutterBinding.ensureInitialized();

  if (response.actionId != 'reply') return;
  final replyText = response.input?.trim();
  if (replyText == null || replyText.isEmpty) return;
  final payload = response.payload;
  if (payload == null) return;
  Map<String, dynamic> data;
  try {
    data = jsonDecode(payload) as Map<String, dynamic>;
  } catch (_) {
    return;
  }
  if (data['type'] != 'message') return;
  // Not awaited — the plugin's callback signature is synchronous, and
  // Android grants this isolate a short grace period to finish
  // pending work after the call returns rather than killing it
  // immediately. See PushNotificationService.handleChatReply for the
  // (tight, timeout-bounded) work this kicks off.
  unawaited(
    PushNotificationService.instance
        .handleChatReply(data: data, replyText: replyText),
  );
}

/// What to do once the app is actually up and running, after someone
/// taps a notification (or one of its Redrop/Comment action buttons).
/// [type] is 'redrop', 'comment', or 'open' (a plain tap, with no
/// action button pressed) — see PushNotificationService's doc comment
/// for why this never tries to act on the article without the app
/// open first.
class PendingNewsAction {
  final String type;
  final NewsArticle article;
  const PendingNewsAction({required this.type, required this.article});
}

/// A tap on a chat-message push notification. [recipientId] is which
/// signed-in account this message was actually for — may not be the
/// account currently active in the UI, since one device can have
/// several accounts signed in at once (see AccountManagerService) and
/// all of them share the same FCM token. [chatId] is who to open a
/// conversation with (the other participant), i.e. the sender.
class PendingChatAction {
  final String recipientId;
  final String chatId;
  final String senderName;
  final String message;
  const PendingChatAction({
    required this.recipientId,
    required this.chatId,
    required this.senderName,
    required this.message,
  });
}

/// A tap on a "new status" push notification — someone the recipient
/// follows posted a status. [recipientId] is which signed-in account
/// this push was actually for (see [PendingChatAction]'s doc comment
/// for why that can differ from whichever account is currently
/// active). [creatorId] is who to open [StatusViewerScreen] for.
class PendingStatusAction {
  final String recipientId;
  final String creatorId;
  final String creatorUsername;
  const PendingStatusAction({
    required this.recipientId,
    required this.creatorId,
    required this.creatorUsername,
  });
}

/// Registers this device for push notifications about new Updates-tab
/// stories, and turns a tap on one (or on its Redrop/Comment action
/// buttons) into a [PendingNewsAction] that whichever screen is
/// listening can act on.
///
/// Deliberately never performs the redrop/comment itself from a
/// background isolate — the whole point of "opens the app to that
/// action" (rather than a true headless one-tap action) is that
/// posting a comment or a requote needs a person to actually see and
/// possibly edit it first, and reliably running Supabase calls from a
/// backgrounded/killed app's isolate is exactly the kind of thing
/// that's very easy to get subtly wrong. This only ever displays a
/// notification and, later, opens the right in-app sheet once a real
/// UI is on screen.
///
/// The actual "new article" pushes are sent by a Supabase Edge
/// Function (see supabase/functions/check-new-news) — this service is
/// purely the receiving/display end.
class PushNotificationService {
  PushNotificationService._();
  static final PushNotificationService instance = PushNotificationService._();

  static const _channelId = 'new_stories';
  static const _channelName = 'New stories';
  static const _channelDescription =
      'New Updates-tab stories, with quick Redrop/Comment actions.';

  static const _chatChannelId = 'chat_messages';
  static const _chatChannelName = 'Chat messages';
  static const _chatChannelDescription =
      'New direct messages, for every account signed in on this device.';

  static const _statusChannelId = 'status_updates';
  static const _statusChannelName = 'Status updates';
  static const _statusChannelDescription =
      'When someone you follow posts a new status.';

  final _localNotifications = FlutterLocalNotificationsPlugin();
  final _pendingController = StreamController<PendingNewsAction>.broadcast();
  final _pendingChatController = StreamController<PendingChatAction>.broadcast();
  final _pendingStatusController =
      StreamController<PendingStatusAction>.broadcast();

  /// Fires for a tap that happens *while something is already
  /// listening* — i.e. the app was open (foreground) or resumed from
  /// the background. A tap that launches the app from fully
  /// terminated is handled separately by [consumeInitialAction],
  /// since nothing has subscribed to this stream yet at that point.
  Stream<PendingNewsAction> get pendingActions => _pendingController.stream;

  /// Same idea as [pendingActions], for a tap on a chat-message push
  /// instead of a new-story one. Kept as a separate stream (rather
  /// than one combined union type) so FeedScreen's existing news
  /// handling doesn't need to change shape at all.
  Stream<PendingChatAction> get pendingChatActions => _pendingChatController.stream;

  /// Same idea again, for a tap on a "new status" push.
  Stream<PendingStatusAction> get pendingStatusActions =>
      _pendingStatusController.stream;

  PendingNewsAction? _initialAction;
  PendingChatAction? _initialChatAction;
  PendingStatusAction? _initialStatusAction;
  bool _initialized = false;

  /// Called once from `main()`, after `Firebase.initializeApp()`.
  /// Safe to call more than once — later calls are a no-op.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    await _ensureLocalNotificationsReady();

    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await _saveToken(token);
    FirebaseMessaging.instance.onTokenRefresh.listen(_saveToken);

    // Foreground: FCM doesn't auto-display anything for a data-only
    // message, so this is the only place a foreground push ever
    // becomes visible at all.
    FirebaseMessaging.onMessage.listen(_showLocalNotification);

    // Backgrounded (not terminated) → tapped: by the time this fires,
    // the app is already running again, so it's safe to go straight
    // through the same stream as a foreground tap.
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      if (message.data['type'] == 'message') {
        final action = _chatActionFromData(message.data);
        if (action != null) _pendingChatController.add(action);
        return;
      }
      if (message.data['type'] == 'status') {
        final action = _statusActionFromData(message.data);
        if (action != null) _pendingStatusController.add(action);
        return;
      }
      final action = _actionFromData(message.data, actionId: null);
      if (action != null) _pendingController.add(action);
    });

    // Cold start via a local-notification tap (covers both a plain
    // tap and a Redrop/Comment action button tap that launched the
    // app from fully terminated) — stashed rather than pushed onto
    // the stream, since nothing has subscribed yet this early.
    final launchDetails =
        await _localNotifications.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp == true) {
      final response = launchDetails!.notificationResponse;
      final payload = response?.payload;
      Map<String, dynamic>? data;
      try {
        if (payload != null) data = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {}
      if (data?['type'] == 'message') {
        _initialChatAction = _chatActionFromData(data!);
      } else if (data?['type'] == 'status') {
        _initialStatusAction = _statusActionFromData(data!);
      } else {
        _initialAction =
            _actionFromPayload(payload, actionId: response?.actionId);
      }
    }
  }

  /// Consumes (and clears) whatever cold-start action was pending —
  /// call this once, after the first frame, from wherever in the
  /// widget tree is prepared to open a modal sheet (see FeedScreen).
  PendingNewsAction? consumeInitialAction() {
    final action = _initialAction;
    _initialAction = null;
    return action;
  }

  /// Same as [consumeInitialAction], for a cold start from a tapped
  /// chat-message notification instead.
  PendingChatAction? consumeInitialChatAction() {
    final action = _initialChatAction;
    _initialChatAction = null;
    return action;
  }

  /// Same again, for a cold start from a tapped status notification.
  PendingStatusAction? consumeInitialStatusAction() {
    final action = _initialStatusAction;
    _initialStatusAction = null;
    return action;
  }

  /// Parks [action] in the same slot a cold-start tap would use, so
  /// it's picked up by [consumeInitialChatAction] the next time
  /// something calls it — used when a chat notification arrives for
  /// an account that isn't the one currently active: HomeShell
  /// switches to that account and rebuilds fresh (see
  /// `relaunchToFreshHome`), which tears down and recreates every
  /// screen including whatever was listening on [pendingChatActions].
  /// Stashing here instead of pushing onto that now-dead stream means
  /// the freshly-rebuilt HomeShell still opens the right conversation
  /// once it mounts, exactly like a genuine cold start would.
  void stashChatActionForNextLaunch(PendingChatAction action) {
    _initialChatAction = action;
  }

  /// Same as [stashChatActionForNextLaunch], for a status notification
  /// tapped while the wrong account was active — see the equivalent
  /// account-switch flow in HomeShell.
  void stashStatusActionForNextLaunch(PendingStatusAction action) {
    _initialStatusAction = action;
  }

  /// Also usable directly from the top-level background message
  /// handler in main.dart — that isolate needs its own
  /// flutter_local_notifications setup before `.show()` will work,
  /// which this covers via the same guarded [_ensureLocalNotificationsReady].
  Future<void> showFromBackground(RemoteMessage message) async {
    await _ensureLocalNotificationsReady();
    await _showLocalNotification(message);
  }

  bool _localNotificationsReady = false;

  Future<void> _ensureLocalNotificationsReady() async {
    if (_localNotificationsReady) return;
    _localNotificationsReady = true;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        // A reply typed while the app was already alive (foreground
        // or merely backgrounded) — same send path as the fully-
        // terminated case, just reached without the isolate hop.
        if (response.actionId == 'reply') {
          final replyText = response.input?.trim();
          final payload = response.payload;
          if (replyText != null && replyText.isNotEmpty && payload != null) {
            try {
              final data = jsonDecode(payload) as Map<String, dynamic>;
              if (data['type'] == 'message') {
                unawaited(handleChatReply(data: data, replyText: replyText));
              }
            } catch (_) {}
          }
          return;
        }
        final payload = response.payload;
        Map<String, dynamic>? data;
        try {
          if (payload != null) {
            data = jsonDecode(payload) as Map<String, dynamic>;
          }
        } catch (_) {}
        if (data?['type'] == 'message') {
          final action = _chatActionFromData(data!);
          if (action != null) _pendingChatController.add(action);
          return;
        }
        if (data?['type'] == 'status') {
          final action = _statusActionFromData(data!);
          if (action != null) _pendingStatusController.add(action);
          return;
        }
        final action =
            _actionFromPayload(payload, actionId: response.actionId);
        if (action != null) _pendingController.add(action);
      },
      // Covers a reply typed from the terminated state — see
      // chatReplyBackgroundDispatcher's doc comment above.
      onDidReceiveBackgroundNotificationResponse: chatReplyBackgroundDispatcher,
    );

    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDescription,
      importance: Importance.high,
    );
    const chatChannel = AndroidNotificationChannel(
      _chatChannelId,
      _chatChannelName,
      description: _chatChannelDescription,
      importance: Importance.high,
    );
    const statusChannel = AndroidNotificationChannel(
      _statusChannelId,
      _statusChannelName,
      description: _statusChannelDescription,
      importance: Importance.high,
    );
    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(channel);
    await androidPlugin?.createNotificationChannel(chatChannel);
    await androidPlugin?.createNotificationChannel(statusChannel);
  }

  Future<void> _saveToken(String token) async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) return; // re-attempted on next launch once signed in
    try {
      await SupabaseService.instance.registerDeviceToken(token);
    } catch (_) {
      // Best-effort — worst case this device just doesn't get pushes
      // until the next successful registration attempt.
    }
  }

  /// Re-registers the current FCM token against whichever account is
  /// signed in right now. Called once from [FeedScreenState] on
  /// launch, in case the token was already fetched before sign-in
  /// completed (see the early-return in [_saveToken] above).
  Future<void> registerTokenForCurrentUser() async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await _saveToken(token);
  }

  /// Stops this device's token from being pushed to for [userId] —
  /// call only on an explicit, deliberate sign-out of that specific
  /// account (see AccountManagerService.forgetAccount). Never call
  /// this for a mere account *switch*: another account may still be
  /// signed in on this same device sharing the same token, and it
  /// must keep receiving notifications uninterrupted.
  Future<void> unregisterTokenForUser(String userId) async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null) return;
    await SupabaseService.instance.deactivateDeviceToken(userId, token);
  }

  // Same three tier colors NewsCard uses (RMColors.success / accent /
  // textSecondary from the dark palette — the system notification
  // shade/tray doesn't know about the app's light/dark toggle, so this
  // just picks the one fixed brand color per tier rather than trying
  // to follow the in-app theme).
  static const _kenyaColor = Color(0xFF00E5A0);
  static const _africaColor = Color(0xFFFFB830);
  static const _worldColor = Color(0xFF8888A8);

  Color _tierColor(String? tier) {
    switch (tier) {
      case 'africa':
        return _africaColor;
      case 'world':
        return _worldColor;
      case 'kenya':
      default:
        return _kenyaColor;
    }
  }

  String _tierLabel(String? tier) {
    switch (tier) {
      case 'africa':
        return 'AFRICA';
      case 'world':
        return 'WORLD';
      case 'kenya':
      default:
        return 'KENYA';
    }
  }

  Future<void> _showLocalNotification(RemoteMessage message) async {
    final data = message.data;
    if (data['type'] == 'message') {
      await _showChatNotification(data);
      return;
    }
    if (data['type'] == 'status') {
      await _showStatusNotification(data);
      return;
    }
    if (data['type'] != 'new_article') return;

    final title = data['title'] as String? ?? 'New story';
    final sourceName = data['source_name'] as String?;
    final summary = data['summary'] as String?;
    final imageUrl = data['image_url'] as String?;
    final tier = data['tier'] as String?;
    final tierColor = _tierColor(tier);
    final tierLabel = _tierLabel(tier);

    // Same "SOURCE ✓" verified-tick pairing NewsCard shows next to the
    // outlet name — every source on this tab is hand-curated, so the
    // tick just confirms that, same meaning as in-app.
    final headerLine = sourceName != null && sourceName.isNotEmpty
        ? '$tierLabel · $sourceName ✓'
        : tierLabel;

    // Mirrors the card's 16:9 hero image sitting above the headline —
    // fetched here since flutter_local_notifications needs actual
    // bytes, not a URL, for BigPictureStyle. Never blocks the
    // notification on a slow/failed fetch: falls back to a plain
    // expandable-text notification with the summary underneath the
    // headline instead, same content, just without the photo.
    ByteArrayAndroidBitmap? bigPicture;
    if (imageUrl != null && imageUrl.isNotEmpty) {
      try {
        final response = await http
            .get(Uri.parse(imageUrl))
            .timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          bigPicture = ByteArrayAndroidBitmap(response.bodyBytes);
        }
      } catch (_) {
        // No image — BigTextStyleInformation below covers it.
      }
    }

    final styleInformation = bigPicture != null
        ? BigPictureStyleInformation(
            bigPicture,
            contentTitle: title,
            summaryText: summary,
          )
        : BigTextStyleInformation(
            summary ?? '',
            contentTitle: title,
          );

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: styleInformation,
      color: tierColor,
      ticker: headerLine,
      actions: const [
        AndroidNotificationAction('redrop', 'Redrop'),
        AndroidNotificationAction('comment', 'Comment'),
      ],
    );

    await _localNotifications.show(
      data['link'].hashCode,
      headerLine,
      title,
      NotificationDetails(android: androidDetails),
      payload: jsonEncode(data),
    );
  }

  /// Shows a messaging-style notification (WhatsApp-style reply field
  /// included) for a new chat message. Grouped/tagged by
  /// [recipientId] (rather than by sender) so that if two different
  /// signed-in accounts on this device both get messages, Android
  /// buckets them as two separate conversations-per-account instead
  /// of one undifferentiated pile — this is the visible half of the
  /// "notifications for every account, not just the active one"
  /// behavior.
  Future<void> _showChatNotification(Map<String, dynamic> data) async {
    final recipientId = data['recipientId'] as String?;
    final chatId = data['chatId'] as String?;
    if (recipientId == null || chatId == null) return;

    final senderName = data['senderName'] as String? ?? 'Someone';
    final messageText = data['message'] as String? ?? '';

    await _localNotifications.show(
      _chatNotificationId(recipientId, chatId),
      senderName,
      messageText,
      NotificationDetails(
        android: _chatAndroidDetails(
          recipientId: recipientId,
          chatId: chatId,
          senderName: senderName,
          // Just this one incoming message — [handleChatReply] is
          // what turns this into a real back-and-forth thread once
          // there's actually a reply to show alongside it, rather
          // than fetching history for every single push that lands.
          messages: [
            _ChatMessageForDisplay(
              text: messageText,
              fromMe: false,
              at: DateTime.now(),
            ),
          ],
        ),
      ),
      payload: jsonEncode(data),
    );
  }

  int _chatNotificationId(String recipientId, String chatId) =>
      '$recipientId:$chatId'.hashCode;

  /// Shows a notification for a new status from someone the
  /// recipient follows. One notification id per (recipient, creator)
  /// pair — same grouping idea as chat — so a creator posting a
  /// second status before the first is tapped just updates it in
  /// place rather than stacking two near-identical notifications.
  Future<void> _showStatusNotification(Map<String, dynamic> data) async {
    final recipientId = data['recipientId'] as String?;
    final creatorId = data['creatorId'] as String?;
    if (recipientId == null || creatorId == null) return;

    final creatorUsername = data['creatorUsername'] as String? ?? 'Someone';
    final caption = data['caption'] as String?;
    final mediaUrl = data['mediaUrl'] as String?;
    final avatarUrl = data['creatorAvatarUrl'] as String?;
    final body = (caption != null && caption.isNotEmpty)
        ? caption
        : 'Just posted a new status';

    // Prefer the status's own photo/video thumbnail as the big
    // picture; fall back to the creator's avatar; fall back again to
    // a plain text notification if both are missing or fail to load
    // — same "never let an image fetch block the notification"
    // approach as the news pusher above.
    ByteArrayAndroidBitmap? bigPicture;
    final imageUrl = (mediaUrl != null && mediaUrl.isNotEmpty)
        ? mediaUrl
        : avatarUrl;
    if (imageUrl != null && imageUrl.isNotEmpty) {
      try {
        final response = await http
            .get(Uri.parse(imageUrl))
            .timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          bigPicture = ByteArrayAndroidBitmap(response.bodyBytes);
        }
      } catch (_) {
        // No image — plain text notification below covers it.
      }
    }

    final androidDetails = AndroidNotificationDetails(
      _statusChannelId,
      _statusChannelName,
      channelDescription: _statusChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: bigPicture != null
          ? BigPictureStyleInformation(
              bigPicture,
              contentTitle: creatorUsername,
              summaryText: body,
            )
          : null,
      groupKey: 'status_$recipientId',
      tag: 'status_${recipientId}_$creatorId',
    );

    await _localNotifications.show(
      _statusNotificationId(recipientId, creatorId),
      creatorUsername,
      body,
      NotificationDetails(android: androidDetails),
      payload: jsonEncode(data),
    );
  }

  int _statusNotificationId(String recipientId, String creatorId) =>
      'status:$recipientId:$creatorId'.hashCode;

  /// The WhatsApp-style inline reply field. `showsUserInterface:
  /// false` is what keeps this from yanking whatever the person is
  /// doing on screen into this app — a reply sends quietly in the
  /// background exactly like the incoming message arrived, and the
  /// notification just updates in place once it's actually sent (see
  /// [handleChatReply]).
  List<AndroidNotificationAction> get _chatActions => const [
        AndroidNotificationAction(
          'reply',
          'Reply',
          showsUserInterface: false,
          allowGeneratedReplies: false,
          inputs: [AndroidNotificationActionInput(label: 'Message')],
        ),
      ];

  /// Builds the actual Android notification content for a chat thread
  /// — shared by the initial incoming-message notification and by
  /// [handleChatReply]'s in-place update, so both ever render through
  /// exactly one code path. [messages] must already be oldest-first.
  AndroidNotificationDetails _chatAndroidDetails({
    required String recipientId,
    required String chatId,
    required String senderName,
    required List<_ChatMessageForDisplay> messages,
  }) {
    final person = Person(name: senderName);
    final me = const Person(name: 'You');
    return AndroidNotificationDetails(
      _chatChannelId,
      _chatChannelName,
      channelDescription: _chatChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      styleInformation: MessagingStyleInformation(
        me,
        conversationTitle: senderName,
        groupConversation: false,
        messages: [
          for (final m in messages)
            Message(m.text, m.at, m.fromMe ? me : person),
        ],
      ),
      actions: _chatActions,
      // Every notification for the same (account, other participant)
      // pair replaces the last rather than stacking, and groups
      // separately per recipient account.
      groupKey: 'chat_$recipientId',
      tag: 'chat_${recipientId}_$chatId',
    );
  }

  PendingChatAction? _chatActionFromData(Map<String, dynamic> data) {
    final recipientId = data['recipientId'] as String?;
    final chatId = data['chatId'] as String?;
    if (recipientId == null || chatId == null) return null;
    return PendingChatAction(
      recipientId: recipientId,
      chatId: chatId,
      senderName: data['senderName'] as String? ?? 'Someone',
      message: data['message'] as String? ?? '',
    );
  }

  PendingStatusAction? _statusActionFromData(Map<String, dynamic> data) {
    final recipientId = data['recipientId'] as String?;
    final creatorId = data['creatorId'] as String?;
    if (recipientId == null || creatorId == null) return null;
    return PendingStatusAction(
      recipientId: recipientId,
      creatorId: creatorId,
      creatorUsername: data['creatorUsername'] as String? ?? 'Someone',
    );
  }

  PendingNewsAction? _actionFromPayload(String? payload, {String? actionId}) {
    if (payload == null) return null;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      return _actionFromData(data, actionId: actionId);
    } catch (_) {
      return null;
    }
  }

  NewsTier _tierFromData(String? raw) {
    switch (raw) {
      case 'africa':
        return NewsTier.africa;
      case 'world':
        return NewsTier.world;
      default:
        return NewsTier.kenya;
    }
  }

  PendingNewsAction? _actionFromData(
    Map<String, dynamic> data, {
    String? actionId,
  }) {
    final link = data['link'] as String?;
    if (link == null || link.isEmpty) return null;
    final imageUrl = (data['image_url'] as String?)?.isEmpty ?? true
        ? null
        : data['image_url'] as String;
    final summary = (data['summary'] as String?)?.isEmpty ?? true
        ? null
        : data['summary'] as String;
    final article = NewsArticle(
      id: link,
      title: data['title'] as String? ?? '',
      summary: summary,
      link: link,
      imageUrl: imageUrl,
      sourceName: data['source_name'] as String? ?? 'Unknown source',
      tier: _tierFromData(data['tier'] as String?),
      publishedAt: DateTime.now(),
    );
    final type = (actionId == 'redrop' || actionId == 'comment')
        ? actionId!
        : 'open';
    return PendingNewsAction(type: type, article: article);
  }

  // ---------------------------------------------------------------
  // Reply-from-notification
  // ---------------------------------------------------------------
  //
  // Deliberately talks to Supabase's plain REST endpoints (PostgREST +
  // GoTrue) over `http`, rather than going through the `supabase_flutter`
  // client — this can run in the same disposable background isolate as
  // [chatReplyBackgroundDispatcher], with no `Supabase.initialize()`
  // and no relation to whatever the *main* isolate's client currently
  // has signed in. All it actually needs is:
  //   - the project's URL/anon key (from .env — not loaded by default
  //     in that isolate, so this loads it itself)
  //   - the replying account's saved session (from AccountManagerService,
  //     which backs it with secure storage; see its doc comment)
  // Every network call here is timeout-bounded — Android's grace
  // period for a background notification-action isolate is short, and
  // a hung request is worse than a fast, honest failure.

  /// Sends [replyText] as [data]'s `recipientId` account, to
  /// `chatId`, then updates the notification in place to show it —
  /// success or failure. Safe to call from any isolate, including a
  /// fresh one with nothing else set up yet.
  Future<void> handleChatReply({
    required Map<String, dynamic> data,
    required String replyText,
  }) async {
    final recipientId = data['recipientId'] as String?;
    final chatId = data['chatId'] as String?;
    final senderName = data['senderName'] as String? ?? 'Someone';
    final originalMessage = data['message'] as String? ?? '';
    if (recipientId == null || chatId == null) return;

    // Doze/App Standby is otherwise free to defer every network call
    // below until Android's next maintenance window — which, from a
    // background/terminated isolate, can mean the reply just sits
    // unsent with no error ever surfacing. This foreground-service
    // window is what makes the send actually go out promptly. Always
    // paired with stop() below, in a finally, so it never outlives
    // this one reply attempt (the native side also self-stops after
    // a timeout as a backstop — see ReplyBridgeService).
    await ReplyBridge.start();
    try {
      // Hard backstop: every individual network/storage call inside
      // _sendChatReply is meant to be its own timeout-bound, but a
      // stall in any call we haven't accounted for — or add later —
      // would otherwise leave Android's system "sending…" spinner
      // stuck forever, since nothing would ever reach either the
      // success path or _showChatFailure. This guarantees one or the
      // other always fires. Comfortably inside ReplyBridgeService's
      // own 20s safety-net stop, so the notification update below
      // still lands while the Doze exemption is active.
      await _sendChatReply(
        data: data,
        replyText: replyText,
        recipientId: recipientId,
        chatId: chatId,
        senderName: senderName,
        originalMessage: originalMessage,
      ).timeout(const Duration(seconds: 15), onTimeout: () async {
        await _showChatFailure(recipientId, chatId, senderName, [
          _ChatMessageForDisplay(
              text: originalMessage, fromMe: false, at: DateTime.now()),
        ]);
      });
    } finally {
      await ReplyBridge.stop();
    }
  }

  Future<void> _sendChatReply({
    required Map<String, dynamic> data,
    required String replyText,
    required String recipientId,
    required String chatId,
    required String senderName,
    required String originalMessage,
  }) async {
    try {
      await dotenv.load(fileName: '.env');
    } catch (e) {
      // Already loaded (main isolate handed this call off directly,
      // e.g. from the foreground onDidReceiveNotificationResponse
      // path) — anything else means .env is genuinely missing, which
      // _accessToken below will fail on anyway.
      if (!e.toString().toLowerCase().contains('already')) {
        // Fall through — _accessTokenFor will surface the real error
        // via its own try/catch and this'll end up in the failure path.
      }
    }

    final supabaseUrl = dotenv.env['SUPABASE_URL'];
    final anonKey = dotenv.env['SUPABASE_ANON_KEY'];
    final fallback = [
      _ChatMessageForDisplay(
          text: originalMessage, fromMe: false, at: DateTime.now()),
    ];

    if (supabaseUrl == null || anonKey == null) {
      await _showChatFailure(recipientId, chatId, senderName, fallback);
      return;
    }

    try {
      final accessToken = await _validAccessTokenFor(
        recipientId,
        supabaseUrl: supabaseUrl,
        anonKey: anonKey,
      );
      if (accessToken == null) {
        await _showChatFailure(recipientId, chatId, senderName, fallback);
        return;
      }

      await http
          .post(
            Uri.parse('$supabaseUrl/rest/v1/messages'),
            headers: {
              'apikey': anonKey,
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode({
              'sender_id': recipientId,
              'recipient_id': chatId,
              'content': replyText,
            }),
          )
          .timeout(const Duration(seconds: 10));

      // Best-effort thread refresh for the update — a failure here
      // just means the notification shows the two messages we
      // already know about (the original plus this reply) instead of
      // fuller recent history, never a reason to treat the send
      // itself as failed.
      final thread = await _fetchRecentThread(
        recipientId,
        chatId,
        supabaseUrl: supabaseUrl,
        anonKey: anonKey,
        accessToken: accessToken,
      ) ??
          [
            _ChatMessageForDisplay(
                text: originalMessage, fromMe: false, at: DateTime.now()),
            _ChatMessageForDisplay(
                text: replyText, fromMe: true, at: DateTime.now()),
          ];

      await _ensureLocalNotificationsReady();
      await _localNotifications.show(
        _chatNotificationId(recipientId, chatId),
        senderName,
        replyText,
        NotificationDetails(
          android: _chatAndroidDetails(
            recipientId: recipientId,
            chatId: chatId,
            senderName: senderName,
            messages: thread,
          ),
        ),
        payload: jsonEncode(data),
      );
    } catch (_) {
      await _showChatFailure(recipientId, chatId, senderName, fallback);
    }
  }

  /// Re-shows the notification with the original message plus a note
  /// that the reply didn't go through — always called instead of
  /// silently leaving the system's "Sending…" indicator stuck, which
  /// is what happens on Android if nothing ever calls `.show()` again
  /// for this id after a reply action fires.
  Future<void> _showChatFailure(
    String recipientId,
    String chatId,
    String senderName,
    List<_ChatMessageForDisplay> withOriginal,
  ) async {
    try {
      await _ensureLocalNotificationsReady();
      await _localNotifications.show(
        _chatNotificationId(recipientId, chatId),
        senderName,
        '⚠️ Couldn\'t send — tap to open and retry',
        NotificationDetails(
          android: _chatAndroidDetails(
            recipientId: recipientId,
            chatId: chatId,
            senderName: senderName,
            messages: [
              ...withOriginal,
              _ChatMessageForDisplay(
                text: '⚠️ Couldn\'t send — tap to open and retry',
                fromMe: true,
                at: DateTime.now(),
              ),
            ],
          ),
        ),
        payload: jsonEncode({
          'type': 'message',
          'recipientId': recipientId,
          'chatId': chatId,
          'senderName': senderName,
          'message': withOriginal.isNotEmpty ? withOriginal.first.text : '',
        }),
      );
    } catch (_) {
      // If even this fails there's nothing left to fall back to —
      // the notification stays as-is until the next real event.
    }
  }

  /// The saved access token for [userId], refreshed first if it's
  /// expired (or expiring within the next minute — no point handing
  /// back a token that'll die mid-request). Returns null if there's
  /// no saved session, or the refresh itself fails (expired refresh
  /// token, no connectivity, etc.) — callers treat that as "can't
  /// send", not "sender is signed out forever": the saved session is
  /// left untouched in that case for the next attempt to retry.
  Future<String?> _validAccessTokenFor(
    String userId, {
    required String supabaseUrl,
    required String anonKey,
  }) async {
    final sessionJson =
        await AccountManagerService.instance.readSavedSessionJson(userId);
    if (sessionJson == null) return null;

    Map<String, dynamic> session;
    try {
      session = jsonDecode(sessionJson) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    final expiresAt = session['expires_at'] as int?;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final stillValid = expiresAt != null && expiresAt - now > 60;
    if (stillValid) return session['access_token'] as String?;

    final refreshToken = session['refresh_token'] as String?;
    if (refreshToken == null) return null;

    try {
      final response = await http
          .post(
            Uri.parse('$supabaseUrl/auth/v1/token?grant_type=refresh_token'),
            headers: {
              'apikey': anonKey,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'refresh_token': refreshToken}),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;

      final refreshed = jsonDecode(response.body) as Map<String, dynamic>;
      final newAccessToken = refreshed['access_token'] as String?;
      final newRefreshToken = refreshed['refresh_token'] as String?;
      final expiresIn = refreshed['expires_in'] as int?;
      if (newAccessToken == null) return null;

      final merged = {
        ...session,
        'access_token': newAccessToken,
        'refresh_token': newRefreshToken ?? refreshToken,
        'expires_in': expiresIn,
        'expires_at': expiresIn != null ? now + expiresIn : session['expires_at'],
      };
      await AccountManagerService.instance
          .writeSavedSessionJson(userId, jsonEncode(merged));
      return newAccessToken;
    } catch (_) {
      return null;
    }
  }

  /// The last handful of messages between [recipientId] and [chatId],
  /// oldest-first, for rebuilding the notification's thread after a
  /// reply actually sends. Returns null (never an empty list) on any
  /// failure, so the caller's own two-message fallback kicks in
  /// instead of a blank thread.
  Future<List<_ChatMessageForDisplay>?> _fetchRecentThread(
    String recipientId,
    String chatId, {
    required String supabaseUrl,
    required String anonKey,
    required String accessToken,
  }) async {
    try {
      final filter = 'or=(and(sender_id.eq.$recipientId,recipient_id.eq.$chatId),'
          'and(sender_id.eq.$chatId,recipient_id.eq.$recipientId))';
      final uri = Uri.parse(
        '$supabaseUrl/rest/v1/messages'
        '?select=sender_id,content,created_at'
        '&$filter'
        '&order=created_at.desc&limit=6',
      );
      final response = await http.get(uri, headers: {
        'apikey': anonKey,
        'Authorization': 'Bearer $accessToken',
      }).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;

      final rows = jsonDecode(response.body) as List;
      if (rows.isEmpty) return null;
      final messages = rows
          .map((raw) {
            final row = raw as Map<String, dynamic>;
            final createdAt = DateTime.tryParse(row['created_at'] as String) ??
                DateTime.now();
            return _ChatMessageForDisplay(
              text: row['content'] as String? ?? '',
              fromMe: row['sender_id'] == recipientId,
              at: createdAt,
            );
          })
          .toList()
          .reversed
          .toList();
      return messages;
    } catch (_) {
      return null;
    }
  }
}

/// One bubble in a chat notification's thread — [fromMe] is relative
/// to whichever account the notification itself belongs to
/// (`recipientId`), not to whoever's actively using the app right now.
class _ChatMessageForDisplay {
  final String text;
  final bool fromMe;
  final DateTime at;
  const _ChatMessageForDisplay({
    required this.text,
    required this.fromMe,
    required this.at,
  });
}
