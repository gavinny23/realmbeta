import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/drop.dart';
import '../models/profile_stats.dart';
import '../models/profile_rank.dart';
import '../models/public_profile.dart';
import '../models/flick.dart';
import '../models/status_post.dart';
import '../models/redrop_feed_item.dart';
import '../models/dev_hub_build.dart';
import 'app_storage_service.dart';
import 'local_cache_service.dart';

/// Thin wrapper around the Supabase client. Keeping all Supabase calls
/// in one place makes it easy to swap the backend later if v2 ever
/// needs a custom service for something Supabase can't do.
class SupabaseService {
  SupabaseService._();
  static final SupabaseService instance = SupabaseService._();

  SupabaseClient get _client => Supabase.instance.client;

  /// Applied to the handful of reads that back a "cache-first" screen
  /// (profile stats, privacy settings, the chat list, the feed, …).
  /// Those screens already show cached data immediately and only use
  /// this call to refresh it in the background — but without any
  /// timeout, an unreachable network (rather than a request that's
  /// cleanly rejected) can leave the underlying `Future` hanging far
  /// longer than a phone's radio actually needs to give up, which
  /// left a couple of screens' loading spinners stuck indefinitely
  /// while offline instead of falling back to the cached data
  /// already on screen. Failing fast here means the `catch` block in
  /// each of those screens runs quickly, so it can do so.
  static const _quickReadTimeout = Duration(seconds: 8);

  /// Same reasoning as [_quickReadTimeout], for writes — a bit more
  /// generous since a write is a heavier round trip, but still bounded
  /// so a stalled connection fails fast enough for the caller's
  /// offline-queue fallback (see PrivacySettingsSyncService,
  /// ProfileFieldsSyncService) to actually kick in instead of leaving
  /// a save button stuck spinning.
  static const _writeTimeout = Duration(seconds: 12);

  // ---------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------

  User? get currentUser => _client.auth.currentUser;

  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  /// Heartbeat for the online/last-seen badge (see PresenceAvatar,
  /// PresenceService) — marks this account as active right now.
  Future<void> touchPresence() {
    return _client.rpc('touch_presence').timeout(_quickReadTimeout);
  }

  Future<void> signUp({
    required String email,
    required String password,
    required String username,
    required String displayName,
    required String homeCity,
  }) async {
    final res = await _client.auth.signUp(email: email, password: password);
    final user = res.user;
    if (user == null) {
      throw Exception('Sign up failed — no user returned.');
    }
    await _client.from('profiles').insert({
      'id': user.id,
      'username': username,
      'display_name': displayName,
      'home_city': homeCity,
    });
  }

  /// True if [email] already belongs to an account. Backed by
  /// `email_is_registered` (v29-migration.sql) since auth.users isn't
  /// otherwise queryable from the client. Used by SignUpScreen's
  /// email step so someone finds out immediately rather than after
  /// filling in a username and password too.
  Future<bool> emailIsRegistered(String email) async {
    final result = await _client
        .rpc('email_is_registered', params: {'check_email': email});
    return result as bool;
  }

  /// True if [username] is already taken. public.profiles is
  /// select-able by everyone (see schema.sql), so this is a plain
  /// query rather than needing its own RPC.
  Future<bool> usernameIsTaken(String username) async {
    final row = await _client
        .from('profiles')
        .select('id')
        .eq('username', username)
        .maybeSingle();
    return row != null;
  }

  /// True once the signed-in user has an actual profiles row. A
  /// Supabase Auth session can exist without one — most notably right
  /// after a first-time Google sign-in, since Google gives no
  /// concept of "username" for [signUp] to use — see AuthGate, which
  /// routes a signed-in-but-profile-less user to
  /// CompleteProfileScreen instead of straight into HomeShell.
  Future<bool> hasProfile(String userId) async {
    final row = await _client
        .from('profiles')
        .select('id')
        .eq('id', userId)
        .maybeSingle();
    return row != null;
  }

  /// Fills in the profiles row for a user who already has a Supabase
  /// Auth session but no profile yet (see [hasProfile]) — the second
  /// half of what [signUp] does, without the auth.signUp call since
  /// there's already a signed-in user by this point.
  Future<void> completeProfile({
    required String username,
    required String displayName,
    String? homeCity,
  }) async {
    final user = currentUser;
    if (user == null) throw Exception('Must be signed in to complete a profile.');
    await _client.from('profiles').insert({
      'id': user.id,
      'username': username,
      'display_name': displayName,
      'home_city': homeCity,
    });
  }

  static const _oauthRedirectUrl = 'realm://login-callback';

  /// Signs in (or, for a first-time user, signs up) with Google.
  /// Reuses the same `realm://login-callback` scheme and
  /// AndroidManifest intent-filter GithubService's identity-linking
  /// already depends on — see that file for the one-time Supabase
  /// dashboard + native config this itself still needs (Google
  /// specifically needs its own OAuth Client ID/secret pasted into
  /// Authentication → Providers → Google, separately from GitHub's).
  ///
  /// Like signInWithOAuth generally, this only resolves once the
  /// external browser has been launched, not once sign-in actually
  /// completes — the real signed-in transition arrives later through
  /// [authStateChanges], which is what AuthGate already listens to.
  Future<void> signInWithGoogle() async {
    await _client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: _oauthRedirectUrl,
    );
  }

  Future<void> signIn({
    required String identifier, // email or username
    required String password,
  }) async {
    String email = identifier;

    // Allow login by username by resolving it to an email first.
    if (!identifier.contains('@')) {
      final profile = await _client
          .from('profiles')
          .select('id')
          .eq('username', identifier)
          .maybeSingle();
      if (profile == null) {
        throw Exception('No account found for that username.');
      }
      // Supabase auth requires email for password sign-in; in a real
      // build, store email lookup via a secure RPC instead of relying
      // on client-side profile reads for this. This is a v1 shortcut.
      throw Exception(
        'Username login requires a server-side email lookup RPC — '
        'sign in with email for v1, or add a `resolve_login_email` '
        'RPC before shipping username login.',
      );
    }

    await _client.auth.signInWithPassword(email: email, password: password);
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
    await LocalCacheService.instance.clearAll();
    await AppStorageService.instance.clearAll();
  }

  /// The current session, if any — used by `AccountManagerService` to
  /// snapshot a full set of tokens for the account switcher.
  Session? get currentSession => _client.auth.currentSession;

  /// A JSON-serialized copy of [currentSession], suitable for handing
  /// to [restoreSession] later (including after an app restart, from
  /// a different account's session having since taken its place).
  String? get currentSessionJson {
    final session = currentSession;
    if (session == null) return null;
    return jsonEncode(session.toJson());
  }

  /// Loads a previously-snapshotted session (from [currentSessionJson])
  /// straight into the client. If its access token hasn't expired yet
  /// this is a pure local operation — no network round trip — which is
  /// exactly what makes switching between saved accounts fast and
  /// available offline. An already-expired token still needs one
  /// round trip to silently refresh, the same as any token-based
  /// session would.
  Future<void> restoreSession(String sessionJson) async {
    await _client.auth.recoverSession(sessionJson);
  }

  /// Just enough of a profile (username/display name/avatar/home
  /// city) to render an entry in the account switcher.
  Future<Map<String, dynamic>?> fetchAccountSummary(String userId) async {
    return await _client
        .from('profiles')
        .select('username, display_name, avatar_url, home_city')
        .eq('id', userId)
        .maybeSingle()
        .timeout(_quickReadTimeout);
  }

  // ---------------------------------------------------------------
  // Drops
  // ---------------------------------------------------------------

  Future<List<Drop>> fetchNearbyDrops({
    required double lat,
    required double lng,
    int radiusM = 2000,
  }) async {
    final rows = await _client.rpc('nearby_drops', params: {
      'user_lat': lat,
      'user_lng': lng,
      'radius_m': radiusM,
    }).timeout(_quickReadTimeout);
    return (rows as List)
        .map((row) => Drop.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// All drops made by one specific user — locked ones included, with
  /// distance from [lat]/[lng] so they can still be navigated to. This
  /// is how a locked drop is meant to be found now that the Explore
  /// feed only shows already-unlocked drops: search for the person who
  /// left it, then browse their profile.
  Future<List<Drop>> fetchUserDrops({
    required String userId,
    required double lat,
    required double lng,
  }) async {
    final rows = await _client.rpc('user_drops', params: {
      'target_user_id': userId,
      'user_lat': lat,
      'user_lng': lng,
    });
    return (rows as List)
        .map((row) => Drop.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Attempts to unlock a drop. The server independently verifies
  /// proximity — the client's claimed location is never trusted for
  /// the actual unlock decision.
  Future<bool> attemptUnlock({
    required String dropId,
    required double lat,
    required double lng,
  }) async {
    final result = await _client.rpc('attempt_unlock', params: {
      'target_drop_id': dropId,
      'user_lat': lat,
      'user_lng': lng,
    });
    return result as bool;
  }

  Future<void> createDrop({
    required double lat,
    required double lng,
    required String caption,
    String? mediaUrl,
    String? mediaType,
    int? mediaSizeBytes,
    bool allowDownload = true,
    List<Map<String, dynamic>> mediaItems = const [],
    String? musicUrl,
    String? musicTitle,
    String? musicArtist,
    int? musicDurationMs,
    int unlockRadiusM = 50,
    String visibility = 'public',
  }) async {
    final user = currentUser;
    if (user == null) throw Exception('Must be signed in to create a drop.');

    await _client.from('drops').insert({
      'creator_id': user.id,
      'location': 'SRID=4326;POINT($lng $lat)',
      'caption': caption,
      'media_url': mediaUrl,
      'media_type': mediaType,
      'media_size_bytes': mediaSizeBytes,
      'allow_download': allowDownload,
      'media_items': mediaItems,
      'music_url': musicUrl,
      'music_title': musicTitle,
      'music_artist': musicArtist,
      'music_duration_ms': musicDurationMs,
      'unlock_radius_m': unlockRadiusM,
      'visibility': visibility,
    });
  }

  /// Uploads a single file's bytes to the `drop-media` bucket and returns
  /// its public URL. [onProgress] is called with a 0.0–1.0 fraction.
  ///
  /// The Supabase storage client doesn't expose true byte-level upload
  /// progress for `uploadBinary`, so progress here is simulated: it
  /// climbs smoothly toward ~90% for as long as the upload future is
  /// still pending (scaled roughly to the file size so bigger files
  /// "feel" slower), then snaps to 100% the moment the upload actually
  /// completes. This keeps the progress toast honest about "still
  /// working" vs "done" without pretending to know exact byte counts.
  Future<String> uploadDropMedia({
    required Uint8List bytes,
    required String mediaType, // 'photo', 'video', 'document'
    String extension = 'jpg',
    void Function(double progress)? onProgress,
  }) async {
    final user = currentUser;
    if (user == null) throw Exception('Must be signed in to upload media.');

    final fileName =
        '${user.id}/${DateTime.now().millisecondsSinceEpoch}_'
        '${bytes.length}.$extension';

    Timer? ticker;
    if (onProgress != null) {
      // Roughly 1 simulated "tick" per 150ms; total ramp time scales
      // with file size (capped) so a 50MB video doesn't rocket to 90%
      // in half a second while a 20KB photo doesn't crawl either.
      final estimatedMs = (bytes.length / 1024 / 40).clamp(600, 12000);
      final steps = (estimatedMs / 150).clamp(4, 80).round();
      var step = 0;
      onProgress(0.02);
      ticker = Timer.periodic(Duration(milliseconds: 150), (t) {
        step++;
        final fraction = (step / steps) * 0.9;
        onProgress(fraction.clamp(0.0, 0.9));
        if (step >= steps) t.cancel();
      });
    }

    try {
      await _client.storage.from('drop-media').uploadBinary(
            fileName,
            bytes,
            fileOptions: FileOptions(upsert: false),
          );
    } finally {
      ticker?.cancel();
    }

    onProgress?.call(1.0);
    return _client.storage.from('drop-media').getPublicUrl(fileName);
  }

  /// Deletes a drop. Row-level security (see schema.sql, "Users can
  /// delete their own drops") means this silently affects zero rows if
  /// the caller isn't the creator, so callers should still gate the
  /// delete button on ownership client-side for a sane UX.
  Future<void> deleteDrop(String dropId) async {
    await _client.from('drops').delete().eq('id', dropId);
  }

  /// Grant a specific user access to a private drop by username.
  /// Returns false if the username doesn't exist.
  Future<bool> grantDropAccess({
    required String dropId,
    required String username,
  }) async {
    final result = await _client.rpc('grant_drop_access', params: {
      'target_drop_id': dropId,
      'target_username': username,
    });
    return result as bool;
  }

  /// Search profiles by username prefix — used for the access allowlist
  /// picker when creating a private drop, starting a chat, and the
  /// Explore feed's user search. Excludes anyone who's turned off
  /// "Allow discovery" in their privacy settings.
  Future<List<Map<String, dynamic>>> searchUsers(String query) async {
    if (query.length < 2) return [];
    final rows = await _client
        .from('profiles')
        .select('id, username, display_name, avatar_url, last_active_at')
        .ilike('username', '$query%')
        .eq('allow_discovery', true)
        .limit(10);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// Users matching [query] who can be @mentioned right now — i.e. they
  /// haven't turned off "Allow tagging" (or "Allow discovery") in their
  /// privacy settings. Backs the @mention autocomplete dropdown in
  /// [MentionComposerField]; unlike [searchUsers] this list is also
  /// the source of truth for which typed @names are allowed to
  /// highlight blue as valid mentions.
  Future<List<Map<String, dynamic>>> searchMentionableUsers(String query) async {
    if (query.isEmpty) return [];
    final rows = await _client.rpc('search_mentionable_users', params: {
      'search_query': query,
    });
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// Everyone who follows the current user — for the "Followers" list
  /// on the current user's own profile. Unlike [fetchMutualFollows],
  /// this doesn't require the current user to follow back.
  Future<List<Map<String, dynamic>>> fetchFollowers() async {
    final rows = await _client.rpc('get_followers');
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// The current user's own drops, newest first, for the "Dropped"
  /// gallery on their profile. Always reports each drop as unlocked —
  /// you never need to walk back to your own drop to see it.
  Future<List<Drop>> fetchMyDrops() async {
    final rows = await _client.rpc('get_my_drops');
    return (rows as List)
        .map((row) => Drop.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Everyone the current user follows who also follows them back —
  /// used to show a "Friends" list when starting a new chat, so people
  /// don't have to type a username for someone they already talk to.
  Future<List<Map<String, dynamic>>> fetchMutualFollows() async {
    final rows = await _client.rpc('get_mutual_follows');
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// Where the current user stands vs every other profile, by
  /// followers and by engagement — powers the local "/my-rank" Dev Hub
  /// cheat code. See supabase/v21-migration.sql.
  Future<ProfileRank> fetchProfileRank() async {
    final rows = await _client.rpc('get_profile_rank');
    final row = (rows as List).first as Map<String, dynamic>;
    return ProfileRank.fromMap(row);
  }

  /// Returns the most recently created drop id by a user.
  /// Used after createDrop to grant allowlist access.
  Future<String?> fetchLatestDropId(String userId) async {
    final row = await _client
        .from('drops')
        .select('id')
        .eq('creator_id', userId)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    return row?['id'] as String?;
  }

  // ---------------------------------------------------------------
  // Interactions (likes + comments)
  // ---------------------------------------------------------------

  Future<List<Map<String, dynamic>>> fetchInteractions({
    required String dropId,
  }) async {
    final rows = await _client
        .from('drop_interactions')
        .select('*, profiles(username, avatar_url, last_active_at)')
        .eq('drop_id', dropId)
        .order('created_at', ascending: true);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<void> addLike({required String dropId}) async {
    await _client.from('drop_interactions').insert({
      'user_id': currentUser!.id,
      'drop_id': dropId,
      'type': 'like',
      'content': null,
    });
  }

  Future<void> removeLike({required String dropId}) async {
    await _client
        .from('drop_interactions')
        .delete()
        .eq('drop_id', dropId)
        .eq('user_id', currentUser!.id)
        .eq('type', 'like');
  }

  Future<void> addComment({
    required String dropId,
    required String content,
  }) async {
    // Comments bypass the unique(user_id, drop_id, type) constraint
    // by using a raw insert with upsert disabled — multiple comments
    // per user on same drop are fine.
    await _client.from('drop_interactions').insert({
      'user_id': currentUser!.id,
      'drop_id': dropId,
      'type': 'comment',
      'content': content,
    });
  }

  // ---------------------------------------------------------------
  // Drop redrops (Explore feed) — repost someone else's drop to your
  // own audience, optionally with a short requote. Same shape and
  // upsert-not-stack behavior as News redrops below, see
  // v22-migration.sql's drop_redrops table.
  // ---------------------------------------------------------------

  /// Count only — used on the card itself so a full row list doesn't
  /// need to come down just to show a number.
  Future<int> fetchDropRedropCount(String dropId) async {
    final result =
        await _client.rpc('drop_redrop_count', params: {'target_drop_id': dropId});
    return (result as num).toInt();
  }

  /// Whether the current user has already redropped this drop, and
  /// their requote text if so — drives whether the redrop button
  /// reads as "Redrop" or "Redropped".
  Future<Map<String, dynamic>?> fetchMyDropRedrop(String dropId) async {
    final user = currentUser;
    if (user == null) return null;
    return await _client
        .from('drop_redrops')
        .select()
        .eq('drop_id', dropId)
        .eq('user_id', user.id)
        .maybeSingle();
  }

  /// Redrops a drop, or updates the requote text if this user already
  /// redropped it — upsert on the (user_id, drop_id) unique
  /// constraint, same toggle-not-stack idea as a retweet button.
  Future<void> addOrUpdateDropRedrop({
    required String dropId,
    String? quote,
  }) async {
    final user = currentUser;
    if (user == null) throw Exception('Must be signed in to redrop.');
    await _client.from('drop_redrops').upsert(
      {
        'user_id': user.id,
        'drop_id': dropId,
        'quote': quote,
      },
      onConflict: 'user_id,drop_id',
    );
  }

  Future<void> removeDropRedrop(String dropId) async {
    final user = currentUser;
    if (user == null) return;
    await _client
        .from('drop_redrops')
        .delete()
        .eq('drop_id', dropId)
        .eq('user_id', user.id);
  }

  // ---------------------------------------------------------------
  // News comments (Updates tab)
  // ---------------------------------------------------------------

  /// Comments on a syndicated news story, newest first. [articleLink]
  /// is the publisher's own URL — the article isn't stored here, so
  /// its link doubles as the id comments hang off of.
  Future<List<Map<String, dynamic>>> fetchNewsComments(
      String articleLink) async {
    final rows = await _client
        .from('news_comments')
        .select('*, profiles(username, avatar_url, last_active_at)')
        .eq('article_link', articleLink)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<void> addNewsComment({
    required String articleLink,
    required String articleTitle,
    required String content,
  }) async {
    await _client.from('news_comments').insert({
      'user_id': currentUser!.id,
      'article_link': articleLink,
      'article_title': articleTitle,
      'content': content,
    });
  }

  Future<void> deleteNewsComment(String commentId) async {
    await _client.from('news_comments').delete().eq('id', commentId);
  }

  /// Count only — used on the card itself so opening every story's
  /// full comment thread isn't required just to show a number.
  Future<int> fetchNewsCommentCount(String articleLink) async {
    final result = await _client.rpc('news_comment_count',
        params: {'target_article_link': articleLink});
    return (result as num).toInt();
  }

  // ---------------------------------------------------------------
  // News redrops (Updates tab) — repost a story, optionally with a
  // requote, distinct from sharing it to your status (see createStatus
  // below, which renders the card into an actual image).
  // ---------------------------------------------------------------

  /// Redrops of a story, newest first, each carrying who redropped it
  /// and their requote text if they added one.
  Future<List<Map<String, dynamic>>> fetchNewsRedrops(
      String articleLink) async {
    final rows = await _client
        .from('news_redrops')
        .select('*, profiles(username, avatar_url, last_active_at)')
        .eq('article_link', articleLink)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// Count only — used on the card itself, same "don't pull every row
  /// just to show a number" contract as [fetchNewsCommentCount].
  Future<int> fetchNewsRedropCount(String articleLink) async {
    final result = await _client.rpc('news_redrop_count',
        params: {'target_article_link': articleLink});
    return (result as num).toInt();
  }

  /// Whether the current user has already redropped this story, and
  /// their requote text if so — drives whether the redrop button
  /// reads as "Redrop" or "Redropped" on the card/detail screen.
  Future<Map<String, dynamic>?> fetchMyNewsRedrop(String articleLink) async {
    final user = currentUser;
    if (user == null) return null;
    return await _client
        .from('news_redrops')
        .select()
        .eq('article_link', articleLink)
        .eq('user_id', user.id)
        .maybeSingle();
  }

  /// Redrops a story, or updates the requote text if this user already
  /// redropped it — upsert on the (user_id, article_link) unique
  /// constraint from v16-migration.sql, same toggle-not-stack idea as
  /// a retweet button.
  Future<void> addOrUpdateNewsRedrop({
    required String articleLink,
    required String articleTitle,
    String? articleImageUrl,
    String? articleSourceName,
    String? quote,
  }) async {
    final user = currentUser;
    if (user == null) throw Exception('Must be signed in to redrop.');
    await _client.from('news_redrops').upsert(
      {
        'user_id': user.id,
        'article_link': articleLink,
        'article_title': articleTitle,
        'article_image_url': articleImageUrl,
        'article_source_name': articleSourceName,
        'quote': quote,
      },
      onConflict: 'user_id,article_link',
    );
  }

  Future<void> removeNewsRedrop(String articleLink) async {
    final user = currentUser;
    if (user == null) return;
    await _client
        .from('news_redrops')
        .delete()
        .eq('article_link', articleLink)
        .eq('user_id', user.id);
  }

  // ---------------------------------------------------------------
  // News likes — liking the original story, distinct from redropping
  // it (like vs. retweet). See v18-migration.sql.
  // ---------------------------------------------------------------

  Future<int> fetchNewsLikeCount(String articleLink) async {
    final result = await _client
        .rpc('news_like_count', params: {'target_article_link': articleLink});
    return (result as num).toInt();
  }

  Future<bool> fetchDidILikeNews(String articleLink) async {
    final user = currentUser;
    if (user == null) return false;
    final row = await _client
        .from('news_likes')
        .select()
        .eq('article_link', articleLink)
        .eq('user_id', user.id)
        .maybeSingle();
    return row != null;
  }

  /// Toggles the current user's like on a story. Returns the new
  /// liked state (true = now liked).
  Future<bool> toggleNewsLike({
    required String articleLink,
    required String articleTitle,
  }) async {
    final result = await _client.rpc('toggle_news_like', params: {
      'target_article_link': articleLink,
      'target_article_title': articleTitle,
    });
    return result as bool;
  }

  // ---------------------------------------------------------------
  // Redrop feed (Drops tab) — every redrop across Realm, newest
  // first, each carrying its article snapshot and action counts in
  // one round trip. See v18-migration.sql's fetch_redrop_feed.
  // ---------------------------------------------------------------

  Future<List<RedropFeedItem>> fetchRedropFeed({
    int limit = 30,
    DateTime? before,
  }) async {
    final rows = await _client.rpc('fetch_redrop_feed', params: {
      'limit_count': limit,
      if (before != null) 'before_created_at': before.toIso8601String(),
    });
    return (rows as List)
        .map((row) => RedropFeedItem.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  // ---------------------------------------------------------------
  // Push notifications — device token registration. See
  // PushNotificationService (client), AccountManagerService (for the
  // multi-account bits), and send-chat-notification / check-new-news
  // (Edge Functions, v32/v19-migration.sql) for the rest of this
  // feature.
  // ---------------------------------------------------------------

  /// Upserts this device's current FCM token against the signed-in
  /// user, marking it active. Safe to call repeatedly — a token
  /// rotating or the same token re-registering on every launch both
  /// just overwrite the row.
  ///
  /// Deliberately does NOT remove this token from any *other* account
  /// signed in on this device (see AccountManagerService): the unique
  /// constraint is on (user_id, fcm_token), not fcm_token alone, so
  /// switching the active account and calling this again adds a
  /// second row for the same physical device rather than stealing the
  /// token away from whichever account had it first. That's what lets
  /// every signed-in account on this phone keep getting pushed to,
  /// not just whichever one is currently on screen.
  Future<void> registerDeviceToken(String fcmToken) async {
    final user = currentUser;
    if (user == null) return;
    await _client.from('device_tokens').upsert(
      {
        'user_id': user.id,
        'fcm_token': fcmToken,
        'platform': 'android',
        'active': true,
        'updated_at': DateTime.now().toIso8601String(),
      },
      onConflict: 'user_id,fcm_token',
    );
  }

  /// Marks this device's token inactive for [userId] only — used on
  /// an explicit sign-out (never on a mere account switch, which
  /// should leave every account's notifications running). Any other
  /// account still signed in on this device that shares the same
  /// token is untouched, so it keeps receiving pushes normally.
  Future<void> deactivateDeviceToken(String userId, String fcmToken) async {
    try {
      await _client
          .from('device_tokens')
          .update({
            'active': false,
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('user_id', userId)
          .eq('fcm_token', fcmToken);
    } catch (_) {
      // Best-effort — worst case a signed-out account keeps getting
      // pushed to until the next successful call, which is
      // preferable to blocking sign-out on this.
    }
  }

  Future<ProfileStats?> fetchProfileStats(String userId) async {
    final row = await _client
        .from('profile_stats')
        .select()
        .eq('user_id', userId)
        .maybeSingle()
        .timeout(_quickReadTimeout);
    if (row == null) return null;
    return ProfileStats.fromMap(row);
  }

  /// The privacy-filtered view of a profile shown to visitors: any
  /// field the owner has marked private is already null by the time it
  /// gets here (enforced server-side in `get_public_profile`), plus
  /// follow counts and whether the current user follows them.
  Future<PublicProfile?> fetchPublicProfile(String userId) async {
    final rows = await _client.rpc('get_public_profile', params: {
      'target_user_id': userId,
    });
    final list = rows as List;
    if (list.isEmpty) return null;
    return PublicProfile.fromMap(list.first as Map<String, dynamic>);
  }

  /// Follows/unfollows [userId] as the current user. Returns the new
  /// state — true if now following, false if now unfollowed.
  Future<bool> toggleFollow(String userId) async {
    final result = await _client.rpc('toggle_follow', params: {
      'target_user_id': userId,
    });
    return result as bool;
  }

  /// The viewer's side of the relationship with [userId] — whether the
  /// current user has blocked them and whether the current user is
  /// currently hiding their own online status from them. Backs the
  /// chat profile sheet's toggle states.
  Future<Map<String, bool>> fetchChatRelationship(String userId) async {
    final rows = await _client.rpc('get_chat_relationship', params: {
      'target_user_id': userId,
    });
    final list = rows as List;
    if (list.isEmpty) return {'is_blocked_by_me': false, 'hiding_status_from_them': false};
    final row = list.first as Map<String, dynamic>;
    return {
      'is_blocked_by_me': row['is_blocked_by_me'] as bool? ?? false,
      'hiding_status_from_them': row['hiding_status_from_them'] as bool? ?? false,
    };
  }

  /// Blocks/unblocks [userId]. Returns the new state — true if now
  /// blocked. Blocking also silently drops any existing follow in
  /// either direction and stops either side from sending new messages.
  Future<bool> toggleBlockUser(String userId) async {
    final result = await _client.rpc('toggle_block_user', params: {
      'target_user_id': userId,
    });
    return result as bool;
  }

  /// Hides/unhides the current user's own online status from [userId].
  /// Returns the new state — true if now hidden.
  Future<bool> toggleHideStatusFrom(String userId) async {
    final result = await _client.rpc('toggle_hide_status_from', params: {
      'target_user_id': userId,
    });
    return result as bool;
  }

  /// Files a report against [userId]. [reason] is a short category
  /// (e.g. "Spam", "Harassment"); [details] is optional free text.
  Future<void> reportUser({
    required String userId,
    required String reason,
    String? details,
  }) async {
    await _client.rpc('report_user', params: {
      'target_user_id': userId,
      'reason': reason,
      'details': details,
    }).timeout(_writeTimeout);
  }

  /// The current user's own privacy flags, for the Privacy settings sheet.
  Future<Map<String, dynamic>?> fetchPrivacySettings(String userId) async {
    final row = await _client
        .from('profiles')
        .select('show_home_city, show_display_name, show_stats, allow_discovery, show_on_map, allow_tagging')
        .eq('id', userId)
        .maybeSingle()
        .timeout(_quickReadTimeout);
    return row;
  }

  /// Persists one or more privacy flags for the current user. Each
  /// controls a specific detail on their public-facing profile — see
  /// `get_public_profile`.
  Future<void> updatePrivacySettings({
    required String userId,
    bool? showHomeCity,
    bool? showDisplayName,
    bool? showStats,
    bool? allowDiscovery,
    bool? showOnMap,
    bool? allowTagging,
  }) async {
    final updates = <String, dynamic>{};
    if (showHomeCity != null) updates['show_home_city'] = showHomeCity;
    if (showDisplayName != null) updates['show_display_name'] = showDisplayName;
    if (showStats != null) updates['show_stats'] = showStats;
    if (allowDiscovery != null) updates['allow_discovery'] = allowDiscovery;
    if (showOnMap != null) updates['show_on_map'] = showOnMap;
    if (allowTagging != null) updates['allow_tagging'] = allowTagging;
    if (updates.isEmpty) return;
    await _client
        .from('profiles')
        .update(updates)
        .eq('id', userId)
        .timeout(_writeTimeout);
  }

  /// Everything the "Edit profile" sheet's User details section needs
  /// in one call — username/display name/home city come from
  /// `profiles`, email comes from the Auth user since it isn't
  /// mirrored into that table.
  Future<Map<String, String?>> fetchAccountDetails() async {
    final user = currentUser;
    if (user == null) throw Exception('Not signed in.');
    final row = await _client
        .from('profiles')
        .select('username, display_name, home_city')
        .eq('id', user.id)
        .single()
        .timeout(_quickReadTimeout);
    return {
      'username': row['username'] as String?,
      'display_name': row['display_name'] as String?,
      'home_city': row['home_city'] as String?,
      'email': user.email,
    };
  }

  Future<void> updateProfile({
    required String userId,
    String? username,
    String? displayName,
    String? homeCity,
    String? avatarUrl,
  }) async {
    final updates = <String, dynamic>{};
    if (username != null) updates['username'] = username;
    if (displayName != null) updates['display_name'] = displayName;
    if (homeCity != null) updates['home_city'] = homeCity;
    if (avatarUrl != null) updates['avatar_url'] = avatarUrl;
    if (updates.isEmpty) return;
    try {
      await _client
          .from('profiles')
          .update(updates)
          .eq('id', userId)
          .timeout(_writeTimeout);
    } on PostgrestException catch (e) {
      // 23505 = unique_violation — the only column here with a UNIQUE
      // constraint is username, so a conflict always means "taken."
      if (e.code == '23505') {
        throw Exception('That username is already taken.');
      }
      rethrow;
    }
  }

  /// Changes the account's login email. Supabase sends a confirmation
  /// link to the new address by default — the change only actually
  /// takes effect once that's clicked, so the caller should tell the
  /// user to go check their inbox rather than assume it's done.
  Future<void> updateEmail(String newEmail) async {
    await _client.auth
        .updateUser(UserAttributes(email: newEmail))
        .timeout(_writeTimeout);
  }

  /// Uploads a profile picture to the `avatars` bucket under the current
  /// user's own folder (required by the storage RLS policies — see
  /// v5-migration.sql), writes the resulting public URL onto the
  /// profile row, and returns that URL so the caller can update local
  /// state immediately without a round trip.
  ///
  /// Each upload gets a fresh, cache-busting filename rather than
  /// overwriting a fixed `avatar.jpg` — CDNs and image widgets both
  /// tend to cache aggressively by URL, and a stable filename would
  /// mean a freshly-changed picture doesn't show up right away.
  Future<String> uploadAvatar({
    required Uint8List bytes,
    String extension = 'jpg',
  }) async {
    final user = currentUser;
    if (user == null) throw Exception('Must be signed in to change your avatar.');

    final fileName = '${user.id}/${DateTime.now().millisecondsSinceEpoch}.$extension';

    await _client.storage.from('avatars').uploadBinary(
          fileName,
          bytes,
          fileOptions: FileOptions(upsert: false, contentType: 'image/$extension'),
        );

    final url = _client.storage.from('avatars').getPublicUrl(fileName);
    await updateProfile(userId: user.id, avatarUrl: url);
    checkAvatarForAiGeneration(url); // fire-and-forget, see method doc
    return url;
  }

  /// Best-effort, non-blocking: asks the check-ai-image Edge Function
  /// to score the just-uploaded avatar and, if it looks AI-generated,
  /// flag it on the profile for a human to look at later. Never
  /// throws and never awaited by [uploadAvatar] — the avatar is
  /// already live by the time this runs, and a Sightengine outage or
  /// slow response should never be the reason someone's avatar change
  /// hangs or fails. See v28-migration.sql for the policy this backs.
  void checkAvatarForAiGeneration(String imageUrl) {
    _client.functions
        .invoke('check-ai-image', body: {'image_url': imageUrl})
        .catchError((e) {
      debugPrint('[checkAvatarForAiGeneration] best-effort check failed: $e');
      return null;
    });
  }

  Future<void> deleteAccount() async {
    final user = currentUser;
    if (user == null) return;
    await _client.from('profiles').delete().eq('id', user.id);
    await signOut();
  }

  // ---------------------------------------------------------------
  // Chats (direct messages)
  // ---------------------------------------------------------------

  /// One row per person the current user has exchanged messages with,
  /// newest conversation first. Backed by the `list_conversations` RPC
  /// (see v4-migration.sql).
  Future<List<Map<String, dynamic>>> fetchConversations() async {
    final rows =
        await _client.rpc('list_conversations').timeout(_quickReadTimeout);
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// Full message history between the current user and [otherUserId],
  /// oldest first (ready to feed straight into a chat list).
  Future<List<Map<String, dynamic>>> fetchMessages(
      {required String otherUserId}) async {
    final me = currentUser?.id;
    if (me == null) throw Exception('Must be signed in to view messages.');
    final rows = await _client
        .from('messages')
        .select()
        .or('and(sender_id.eq.$me,recipient_id.eq.$otherUserId),'
            'and(sender_id.eq.$otherUserId,recipient_id.eq.$me)')
        .order('created_at', ascending: true)
        .timeout(_quickReadTimeout);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// A realtime stream of every row in `messages` between the current
  /// user and [otherUserId] — used to live-update an open chat thread.
  Stream<List<Map<String, dynamic>>> watchMessages(
      {required String otherUserId}) {
    final me = currentUser?.id;
    if (me == null) return const Stream.empty();
    return _client
        .from('messages')
        .stream(primaryKey: ['id'])
        .order('created_at')
        .map((rows) => rows.where((r) {
              final sender = r['sender_id'] as String?;
              final recipient = r['recipient_id'] as String?;
              return (sender == me && recipient == otherUserId) ||
                  (sender == otherUserId && recipient == me);
            }).toList());
  }

  /// A realtime stream of every incoming message addressed to the
  /// current user, across *all* conversations — unlike [watchMessages]
  /// this isn't scoped to a single thread. Used to drive things like
  /// the drawer's "new message" popup, which needs to know a message
  /// arrived regardless of which conversation it belongs to.
  Stream<Map<String, dynamic>> watchIncomingMessages() {
    final me = currentUser?.id;
    if (me == null) return const Stream.empty();
    final seen = <Object>{};
    return _client
        .from('messages')
        .stream(primaryKey: ['id'])
        .order('created_at')
        .expand((rows) => rows.where((r) => r['recipient_id'] == me))
        .where((r) {
          final id = r['id'];
          if (id == null || seen.contains(id)) return false;
          seen.add(id);
          return true;
        });
  }

  /// A realtime stream of every message the current user sends *or*
  /// receives, across all conversations — a superset of
  /// [watchIncomingMessages] that also includes the user's own
  /// outgoing messages. [watchIncomingMessages] only fires for
  /// messages addressed to the user, which is right for something
  /// like a "new message" popup, but wrong for anything driving a
  /// conversation-list preview: sending a message is exactly the kind
  /// of activity that should move that conversation to the top and
  /// update its last-message text, and it was being missed entirely.
  Stream<Map<String, dynamic>> watchConversationActivity() {
    final me = currentUser?.id;
    if (me == null) return const Stream.empty();
    final seen = <Object>{};
    return _client
        .from('messages')
        .stream(primaryKey: ['id'])
        .order('created_at')
        .expand((rows) => rows
            .where((r) => r['sender_id'] == me || r['recipient_id'] == me))
        .where((r) {
          final id = r['id'];
          if (id == null || seen.contains(id)) return false;
          seen.add(id);
          return true;
        });
  }

  Future<void> sendMessage({
    required String recipientId,
    required String content,
  }) async {
    final me = currentUser;
    if (me == null) throw Exception('Must be signed in to send messages.');
    await _client.from('messages').insert({
      'sender_id': me.id,
      'recipient_id': recipientId,
      'content': content,
    });
  }

  Future<void> markConversationRead(String otherUserId) async {
    await _client.rpc('mark_conversation_read',
        params: {'other_user_id': otherUserId});
  }

  // ---------------------------------------------------------------
  // @mention invitations & group chats
  // ---------------------------------------------------------------

  /// Called right after a message is sent in a 1:1 chat for every
  /// resolved @mention in it (see [MentionTextEditingController]) that
  /// isn't the other participant already in the conversation. Sends
  /// the mentioned person a notification inviting them into a
  /// 3-person group chat, seeded with this message if they accept.
  /// Returns the invite id, or null if the mention couldn't resolve
  /// server-side (e.g. tagging was turned off between typing and
  /// sending).
  Future<String?> inviteMentionedUser({
    required String otherParticipantId,
    required String invitedUsername,
    required String messageContent,
  }) async {
    final result = await _client.rpc('invite_mentioned_user', params: {
      'other_participant_id': otherParticipantId,
      'invited_username': invitedUsername,
      'message_content': messageContent,
    });
    return result as String?;
  }

  /// Accepts or declines a mention invite. On acceptance, returns the
  /// id of the newly created group chat; on decline, returns null.
  /// Throws if the invite already aged past its 10-minute window —
  /// see respond_to_mention_invite in v27-migration.sql.
  Future<String?> respondToMentionInvite({
    required String inviteId,
    required bool accept,
  }) async {
    final result = await _client.rpc('respond_to_mention_invite', params: {
      'invite_id': inviteId,
      'accept': accept,
    });
    return result as String?;
  }

  /// The single most recent still-pending, unexpired mention invite
  /// addressed to the current user, if any — backs the popup dialog
  /// that greets someone with an unanswered invite on app open,
  /// independent of whether they've looked at the notifications
  /// screen. Null when there's nothing pending (never invited, or the
  /// invite already got answered/expired). Each invite has a 10
  /// minute window from when it was sent — see `expires_at`.
  Future<Map<String, dynamic>?> fetchActiveMentionInvite() async {
    final rows = await _client.rpc('get_active_mention_invite');
    final list = List<Map<String, dynamic>>.from(rows as List);
    return list.isEmpty ? null : list.first;
  }

  /// A realtime stream that fires whenever a new `mention_invite`
  /// notification lands for the current user — used to pop the
  /// invite dialog immediately if one arrives while the app's
  /// already open, rather than only checking once at launch. Emits
  /// the raw notification row; callers still go through
  /// [fetchActiveMentionInvite] to get the full, live invite details
  /// (including `expires_at`) rather than trusting this payload.
  Stream<Map<String, dynamic>> watchMentionInvites() {
    final me = currentUser?.id;
    if (me == null) return const Stream.empty();
    final seen = <Object>{};
    return _client
        .from('notifications')
        .stream(primaryKey: ['id'])
        .order('created_at')
        .expand((rows) =>
            rows.where((r) => r['user_id'] == me && r['type'] == 'mention_invite'))
        .where((r) {
          final id = r['id'];
          if (id == null || seen.contains(id)) return false;
          seen.add(id);
          return true;
        });
  }

  /// Recent notifications for the current user, newest first — backs
  /// the notification bell/screen. `mention_invite` rows carry a live
  /// `invite_status` so an already-answered invite never shows stale
  /// Accept/Decline buttons.
  Future<List<Map<String, dynamic>>> fetchNotifications() async {
    final rows = await _client.rpc('list_notifications');
    return List<Map<String, dynamic>>.from(rows as List);
  }

  Future<int> fetchUnreadNotificationCount() async {
    final result = await _client.rpc('unread_notification_count');
    return (result as num?)?.toInt() ?? 0;
  }

  Future<void> markNotificationRead(String notificationId) async {
    await _client.rpc('mark_notification_read',
        params: {'notification_id': notificationId});
  }

  Future<void> markAllNotificationsRead() async {
    await _client.rpc('mark_all_notifications_read');
  }

  /// One row per group chat the current user is active in, newest
  /// activity first. There's no name field on a group chat —
  /// `participant_names` is always a live, comma-separated list of
  /// everyone still in it besides the caller.
  Future<List<Map<String, dynamic>>> fetchGroupChats() async {
    final rows = await _client.rpc('list_group_chats').timeout(_quickReadTimeout);
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// Every participant a group chat has ever had, including anyone
  /// who's since left (with `left_at` set) — used to render the full
  /// roster inside the chat itself, not just the header name.
  Future<List<Map<String, dynamic>>> fetchGroupParticipants(String chatId) async {
    final rows = await _client
        .rpc('get_group_participants', params: {'chat_id': chatId});
    return List<Map<String, dynamic>>.from(rows as List);
  }

  Future<List<Map<String, dynamic>>> fetchGroupMessages(String chatId) async {
    final rows = await _client
        .from('group_messages')
        .select()
        .eq('chat_id', chatId)
        .order('created_at', ascending: true)
        .timeout(_quickReadTimeout);
    return List<Map<String, dynamic>>.from(rows);
  }

  /// A realtime stream of every message in [chatId] — mirrors
  /// [watchMessages] for 1:1 chats.
  Stream<List<Map<String, dynamic>>> watchGroupMessages(String chatId) {
    return _client
        .from('group_messages')
        .stream(primaryKey: ['id'])
        .eq('chat_id', chatId)
        .order('created_at');
  }

  Future<void> sendGroupMessage({
    required String chatId,
    required String content,
  }) async {
    final me = currentUser;
    if (me == null) throw Exception('Must be signed in to send messages.');
    await _client.from('group_messages').insert({
      'chat_id': chatId,
      'sender_id': me.id,
      'content': content,
    });
  }

  /// Leaves a group chat. If [deleteMessages] is true, every message
  /// the current user sent in it is deleted for everyone first —
  /// "delete for everyone" — otherwise their messages stay put for
  /// the remaining participants, and only their own membership ends.
  Future<void> leaveGroupChat({
    required String chatId,
    required bool deleteMessages,
  }) async {
    await _client.rpc('leave_group_chat', params: {
      'chat_id': chatId,
      'delete_messages': deleteMessages,
    });
  }

  // ---------------------------------------------------------------
  // Flicks (short vertical videos, not location-gated)
  // ---------------------------------------------------------------

  /// The 30-second cap enforced client-side before upload — the
  /// `duration_seconds` column also has a matching DB check constraint
  /// as a second line of defense.
  static const flickMaxDurationSeconds = 30;

  Future<List<Flick>> fetchFlicks({
    int limit = 20,
    DateTime? beforeCreatedAt,
  }) async {
    final rows = await _client.rpc('fetch_flicks', params: {
      'limit_count': limit,
      if (beforeCreatedAt != null)
        'before_created_at': beforeCreatedAt.toIso8601String(),
    }).timeout(_quickReadTimeout);
    return (rows as List)
        .map((row) => Flick.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Uploads a flick video (and optional thumbnail) to the same
  /// `drop-media` bucket used for drop attachments (via the same
  /// per-user folder as [uploadDropMedia]), then creates the `flicks`
  /// row.
  Future<Flick> createFlick({
    required Uint8List videoBytes,
    required String extension,
    required int durationSeconds,
    String? caption,
    Uint8List? thumbBytes,
    void Function(double progress)? onProgress,
  }) async {
    final user = currentUser;
    if (user == null) throw Exception('Must be signed in to post a flick.');
    if (durationSeconds > flickMaxDurationSeconds) {
      throw Exception('Flicks can be at most $flickMaxDurationSeconds seconds.');
    }

    final videoUrl = await uploadDropMedia(
      bytes: videoBytes,
      mediaType: 'video',
      extension: extension,
      onProgress: onProgress,
    );

    String? thumbUrl;
    if (thumbBytes != null) {
      thumbUrl = await uploadDropMedia(
        bytes: thumbBytes,
        mediaType: 'photo',
        extension: 'jpg',
      );
    }

    final row = await _client
        .from('flicks')
        .insert({
          'creator_id': user.id,
          'caption': caption,
          'video_url': videoUrl,
          'thumb_url': thumbUrl,
          'duration_seconds': durationSeconds,
        })
        .select('id, created_at')
        .single();

    final profile = await _client
        .from('profiles')
        .select('username, avatar_url')
        .eq('id', user.id)
        .single();

    return Flick(
      id: row['id'] as String,
      creatorId: user.id,
      creatorUsername: profile['username'] as String? ?? 'unknown',
      creatorAvatarUrl: profile['avatar_url'] as String?,
      caption: caption,
      videoUrl: videoUrl,
      thumbUrl: thumbUrl,
      durationSeconds: durationSeconds,
      likeCount: 0,
      commentCount: 0,
      isLiked: false,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  Future<void> deleteFlick(String flickId) async {
    await _client.from('flicks').delete().eq('id', flickId);
  }

  /// Toggles the current user's like on a flick. Returns the new
  /// liked state (true = now liked).
  Future<bool> toggleFlickLike(String flickId) async {
    final result =
        await _client.rpc('toggle_flick_like', params: {'target_flick_id': flickId});
    return result as bool;
  }

  /// Top-level comments on a flick, newest first.
  Future<List<FlickComment>> fetchFlickComments(String flickId) async {
    final rows = await _client
        .rpc('fetch_flick_comments', params: {'target_flick_id': flickId});
    return (rows as List)
        .map((row) => FlickComment.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Replies to a single top-level comment, oldest first.
  Future<List<FlickComment>> fetchCommentReplies(String commentId) async {
    final rows = await _client
        .rpc('fetch_comment_replies', params: {'target_comment_id': commentId});
    return (rows as List)
        .map((row) => FlickComment.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Posts a comment (or, with [parentCommentId] set, a reply) and
  /// returns the new comment's id.
  Future<String> addFlickComment({
    required String flickId,
    required String content,
    String? parentCommentId,
  }) async {
    final id = await _client.rpc('add_flick_comment', params: {
      'target_flick_id': flickId,
      'comment_content': content,
      if (parentCommentId != null) 'parent_comment_id': parentCommentId,
    });
    return id as String;
  }

  /// Toggles the current user's like on a comment or reply. Returns
  /// the new liked state.
  Future<bool> toggleCommentLike(String commentId) async {
    final result = await _client
        .rpc('toggle_comment_like', params: {'target_comment_id': commentId});
    return result as bool;
  }

  // ---------------------------------------------------------------
  // Status (disappearing photo/video posts — WhatsApp/IG-style,
  // 12h lifespan)
  // ---------------------------------------------------------------

  /// The 12h window is really enforced by Postgres — see the
  /// generated `expires_at` column and its RLS select policy in
  /// v11-migration.sql — this constant just mirrors it so client-side
  /// validation (e.g. rejecting an obviously-too-long video) has a
  /// single source to reference. See also [StatusPost.lifespan] for
  /// the same window used to render the countdown label.
  static const statusMaxVideoDurationSeconds = 30;

  /// One row per creator who currently has an active status, ordered
  /// by the server as "you first, then unseen, then most recent" —
  /// see fetch_status_feed in v11-migration.sql.
  Future<List<StatusFeedEntry>> fetchStatusFeed() async {
    final rows =
        await _client.rpc('fetch_status_feed').timeout(_quickReadTimeout);
    return (rows as List)
        .map((row) => StatusFeedEntry.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// A single creator's active statuses, oldest first — the order a
  /// story viewer pages through them in.
  Future<List<StatusPost>> fetchUserStatuses(String creatorId) async {
    final rows = await _client
        .rpc('get_user_statuses', params: {'target_user_id': creatorId});
    return (rows as List)
        .map((row) => StatusPost.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Uploads the status's media to the same `drop-media` bucket used
  /// by drops and flicks (same per-user folder convention — see
  /// [uploadDropMedia]), then creates the `statuses` row. The 12h
  /// clock (see [StatusPost.lifespan]) starts ticking from whatever
  /// `created_at` the database assigns, not from whenever this future
  /// happens to resolve on the client.
  Future<StatusPost> createStatus({
    required Uint8List mediaBytes,
    required String mediaType, // 'photo' or 'video'
    required String extension,
    String? caption,
    void Function(double progress)? onProgress,
  }) async {
    final user = currentUser;
    if (user == null) throw Exception('Must be signed in to post a status.');

    final mediaUrl = await uploadDropMedia(
      bytes: mediaBytes,
      mediaType: mediaType,
      extension: extension,
      onProgress: onProgress,
    );

    final row = await _client
        .from('statuses')
        .insert({
          'creator_id': user.id,
          'media_url': mediaUrl,
          'media_type': mediaType,
          'caption': caption,
        })
        .select('id, created_at')
        .single();

    final profile = await _client
        .from('profiles')
        .select('username, avatar_url')
        .eq('id', user.id)
        .single();

    return StatusPost(
      id: row['id'] as String,
      creatorId: user.id,
      creatorUsername: profile['username'] as String? ?? 'unknown',
      creatorAvatarUrl: profile['avatar_url'] as String?,
      mediaUrl: mediaUrl,
      mediaType: mediaType,
      caption: caption,
      viewCount: 0,
      isViewedByMe: true,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  /// Deletes a status early, before its 12h window is up. RLS means
  /// this silently affects zero rows if the caller isn't the creator
  /// (same caveat as [deleteDrop]).
  Future<void> deleteStatus(String statusId) async {
    await _client.from('statuses').delete().eq('id', statusId);
  }

  /// Records that the current user has seen a status. Best-effort —
  /// a missed "seen" marker just means the status shows as unviewed a
  /// little longer, which isn't worth surfacing an error for.
  Future<void> markStatusViewed(String statusId) async {
    try {
      await _client
          .rpc('mark_status_viewed', params: {'target_status_id': statusId});
    } catch (_) {
      // Non-fatal, see doc comment above.
    }
  }

  /// Who has viewed one of the current user's own statuses, most
  /// recent view first. The RPC itself enforces that only the
  /// creator can call this for their own status.
  Future<List<Map<String, dynamic>>> fetchStatusViewers(
      String statusId) async {
    final rows = await _client
        .rpc('get_status_viewers', params: {'target_status_id': statusId});
    return List<Map<String, dynamic>>.from(rows as List);
  }

  // ---------------------------------------------------------------
  // Dev Hub (GitHub repo browsing/commits + the "what everyone's
  // building" feed — see v20-migration.sql)
  // ---------------------------------------------------------------

  /// Newest-first, keyset-paginated same as [fetchFlicks] — pass the
  /// oldest `createdAt` already on screen as [beforeCreatedAt] to page
  /// further back.
  Future<List<DevHubBuild>> fetchDevHubFeed({
    int limitCount = 30,
    DateTime? beforeCreatedAt,
  }) async {
    final rows = await _client.rpc('fetch_dev_hub_feed', params: {
      'limit_count': limitCount,
      if (beforeCreatedAt != null)
        'before_created_at': beforeCreatedAt.toIso8601String(),
    }).timeout(_quickReadTimeout);
    return (rows as List)
        .map((row) => DevHubBuild.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Records a commit already made through the Dev Hub editor so it
  /// shows up in other users' "what everyone's building" feed. The
  /// commit itself already happened on GitHub by the time this is
  /// called — this just posts about it.
  Future<void> shareDevHubBuild({
    required String repoFullName,
    required String repoHtmlUrl,
    required String filePath,
    required String commitMessage,
    required String commitUrl,
  }) async {
    final user = currentUser;
    if (user == null) throw Exception('Must be signed in to share a build.');
    await _client.from('dev_hub_builds').insert({
      'creator_id': user.id,
      'repo_full_name': repoFullName,
      'repo_html_url': repoHtmlUrl,
      'file_path': filePath,
      'commit_message': commitMessage,
      'commit_url': commitUrl,
    }).timeout(_writeTimeout);
  }
}
