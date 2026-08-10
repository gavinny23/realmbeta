import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/github_content.dart';
import '../models/github_event.dart';
import '../models/github_repo.dart';

/// Connects a Realm account to GitHub and reads back the connected
/// account's public profile, recent activity, repo list, and file
/// contents for the Dev Hub — including committing edits made in the
/// in-app editor straight back to GitHub via the Contents API.
///
/// This rides on Supabase's own identity-linking flow
/// (`auth.linkIdentity`) rather than a bespoke OAuth dance — Supabase
/// already does the code↔token exchange server-side (so no client
/// secret ever needs to live in this app), and it hands back the raw
/// GitHub access token via `session.providerToken` right after
/// linking completes, requested with `repo` scope up front so a
/// future commit/editor feature doesn't need a second consent screen.
///
/// One-time setup this depends on, done in the Supabase dashboard and
/// native project config rather than in this file:
///  - A GitHub OAuth App, with its Client ID/secret pasted into
///    Supabase → Authentication → Providers → GitHub.
///  - "Enable Manual Linking" turned on under Authentication settings
///    (required for linkIdentity/unlinkIdentity to work at all).
///  - [_redirectUrl] added to Authentication → URL Configuration →
///    Redirect URLs.
///  - A matching intent-filter for that scheme in AndroidManifest.xml
///    (already added) so the OAuth browser redirect lands back in the
///    app instead of a dead end.
class GithubService extends ChangeNotifier {
  GithubService._() {
    _authSub =
        Supabase.instance.client.auth.onAuthStateChange.listen(_onAuthState);
    _refreshRepoAccessFlag();
  }
  static final GithubService instance = GithubService._();

  static const _redirectUrl = 'realm://login-callback';
  static const _tokenStorageKey = 'rm_github_provider_token';
  // `repo` is requested now, even though nothing reads it yet, so
  // connecting once today covers the commit/editor step later instead
  // of asking people to reconnect and re-consent for a wider scope.
  static const _requestedScopes = 'read:user user:email repo';

  final _secureStorage = const FlutterSecureStorage();
  StreamSubscription<AuthState>? _authSub;

  bool _connecting = false;
  bool get connecting => _connecting;

  // Whether a usable repo-scoped token is actually sitting in secure
  // storage right now — distinct from [isConnected], which only
  // reflects that the GitHub identity is linked on the Supabase user.
  // The identity link is server-side and survives reinstalls/new
  // devices; this token is local-only and only ever gets (re)written
  // by the OAuth redirect in [_onAuthState]. A linked identity with no
  // local token is exactly the "looks connected, everything under
  // Browse & edit 401s" state — so callers that gate repo access
  // should check this, not [isConnected].
  bool _hasRepoAccess = false;
  bool get hasRepoAccess => _hasRepoAccess;

  /// Re-reads secure storage and updates [hasRepoAccess]. Called on
  /// construction and after every auth-state change so UI relying on
  /// [hasRepoAccess] doesn't have to know secure storage is async.
  Future<void> refreshRepoAccess() => _refreshRepoAccessFlag();

  Future<void> _refreshRepoAccessFlag() async {
    final token = await storedProviderToken();
    final has = token != null;
    if (has != _hasRepoAccess) {
      _hasRepoAccess = has;
      notifyListeners();
    }
  }

  void _onAuthState(AuthState state) {
    final token = state.session?.providerToken;
    if (token != null) {
      // Save it whenever it's present, full stop. This used to also
      // require _githubIdentity to already be non-null, on the theory
      // that the token only matters once the identity shows up — but
      // that identities list updates asynchronously and can lag one
      // more auth-state tick behind the event carrying the token from
      // linkIdentity's redirect. That race meant the token was
      // silently dropped while the profile still ended up showing as
      // connected a moment later, so every repo-access call afterward
      // failed with "GitHub isn't connected with repo access" even
      // though reconnecting looked unnecessary. Since only GitHub uses
      // linkIdentity in this app, there's no other provider's token
      // this could clobber by mistake.
      _secureStorage.write(key: _tokenStorageKey, value: token);
      _hasRepoAccess = true;
    }
    notifyListeners();
    // Also covers session-restore ticks that carry no providerToken
    // at all (the common case above): re-check what's actually in
    // storage rather than assuming it's still there.
    _refreshRepoAccessFlag();
  }

  UserIdentity? get _githubIdentity {
    final identities = Supabase.instance.client.auth.currentUser?.identities;
    if (identities == null) return null;
    for (final identity in identities) {
      if (identity.provider == 'github') return identity;
    }
    return null;
  }

  bool get isConnected => _githubIdentity != null;

  /// The GitHub login, read from the linked identity's own metadata
  /// rather than a separate API round-trip.
  String? get username {
    final data = _githubIdentity?.identityData;
    return data?['user_name'] as String? ??
        data?['preferred_username'] as String?;
  }

  Future<void> connect() async {
    _connecting = true;
    notifyListeners();
    try {
      // Reconnect case: the GitHub identity is often already linked
      // server-side (e.g. it survived a reinstall) even though the
      // local repo-access token is gone. Supabase's linkIdentity()
      // silently fails whenever the candidate identity is already
      // linked to this user — it doesn't throw in-app, it just
      // redirects back with an error baked into the deep link that
      // nothing here was listening for, so Reconnect looked like it
      // did nothing. Unlinking first guarantees linkIdentity() only
      // ever runs from a clean, not-yet-linked state.
      final existing = _githubIdentity;
      if (existing != null) {
        await Supabase.instance.client.auth.unlinkIdentity(existing);
      }
      await Supabase.instance.client.auth.linkIdentity(
        OAuthProvider.github,
        redirectTo: _redirectUrl,
        scopes: _requestedScopes,
      );
    } finally {
      // linkIdentity() only resolves once the external browser has
      // been launched, not once linking actually completes — the real
      // "connected" transition arrives later through onAuthStateChange
      // above, once the redirect lands back in the app.
      _connecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    final identity = _githubIdentity;
    if (identity == null) return;
    await Supabase.instance.client.auth.unlinkIdentity(identity);
    await _secureStorage.delete(key: _tokenStorageKey);
    _hasRepoAccess = false;
    notifyListeners();
  }

  /// The `repo`-scoped token used for every authenticated GitHub API
  /// call below (repos, contents, commits).
  Future<String?> storedProviderToken() =>
      _secureStorage.read(key: _tokenStorageKey);

  Future<Map<String, dynamic>> fetchProfile() async {
    final user = username;
    if (user == null) throw StateError("GitHub isn't connected.");
    final response =
        await http.get(Uri.parse('https://api.github.com/users/$user'));
    if (response.statusCode != 200) {
      throw Exception(
          "Couldn't load your GitHub profile (${response.statusCode}).");
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<GithubEvent>> fetchActivity({int perPage = 30}) async {
    final user = username;
    if (user == null) throw StateError("GitHub isn't connected.");
    final response = await http.get(Uri.parse(
        'https://api.github.com/users/$user/events/public?per_page=$perPage'));
    if (response.statusCode != 200) {
      throw Exception(
          "Couldn't load your GitHub activity (${response.statusCode}).");
    }
    final list = jsonDecode(response.body) as List;
    return list
        .map((e) => GithubEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Map<String, String> _authHeaders(String token) => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  Future<String> _requireToken() async {
    final token = await storedProviderToken();
    if (token == null) {
      throw StateError(
          "GitHub isn't connected with repo access — reconnect from Dev Hub.");
    }
    return token;
  }

  /// The connected account's own repos, most recently pushed first —
  /// what the repo picker lists.
  Future<List<GithubRepo>> fetchRepos({int perPage = 50}) async {
    final token = await _requireToken();
    final response = await http.get(
      Uri.parse(
          'https://api.github.com/user/repos?sort=pushed&per_page=$perPage'),
      headers: _authHeaders(token),
    );
    if (response.statusCode != 200) {
      throw Exception("Couldn't load your repos (${response.statusCode}).");
    }
    final list = jsonDecode(response.body) as List;
    return list
        .map((e) => GithubRepo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Lists the files/folders at [path] (repo root if empty) in
  /// [repoFullName] ("owner/repo"), folders first then alphabetical.
  Future<List<GithubContent>> fetchContents(
    String repoFullName, {
    String path = '',
  }) async {
    final token = await _requireToken();
    final response = await http.get(
      Uri.parse('https://api.github.com/repos/$repoFullName/contents/$path'),
      headers: _authHeaders(token),
    );
    if (response.statusCode != 200) {
      throw Exception("Couldn't load that folder (${response.statusCode}).");
    }
    final decoded = jsonDecode(response.body);
    // A path pointing at a single file returns an object instead of a
    // list — normalize so callers only ever handle one shape.
    final list = decoded is List ? decoded : [decoded];
    final entries = list
        .map((e) => GithubContent.fromJson(e as Map<String, dynamic>))
        .toList();
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// A single file's decoded text content plus the `sha` GitHub needs
  /// back to confirm which version [commitFile] is replacing.
  Future<GithubFileContent> fetchFileContent(
    String repoFullName,
    String path,
  ) async {
    final token = await _requireToken();
    final response = await http.get(
      Uri.parse('https://api.github.com/repos/$repoFullName/contents/$path'),
      headers: _authHeaders(token),
    );
    if (response.statusCode != 200) {
      throw Exception("Couldn't open that file (${response.statusCode}).");
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final rawContent = (json['content'] as String? ?? '').replaceAll('\n', '');
    String decoded;
    try {
      decoded = utf8.decode(base64Decode(rawContent));
    } catch (_) {
      throw Exception(
          'This file looks binary — the in-app editor only handles text files.');
    }
    return GithubFileContent(
      path: json['path'] as String? ?? path,
      sha: json['sha'] as String,
      content: decoded,
    );
  }

  /// Creates [path] (when [sha] is null) or updates it (when [sha] is
  /// the file's current sha) straight on [branch] via the Contents
  /// API — a full commit, not a PR, so it lands the moment this call
  /// succeeds. This is the one method both [commitFile] (always an
  /// update, from the in-app editor) and the new-file / terminal
  /// flows (which may or may not already have a sha) funnel through.
  Future<GithubCommitResult> writeFile({
    required String repoFullName,
    required String path,
    required String content,
    String? sha,
    required String message,
    required String branch,
  }) async {
    final token = await _requireToken();
    final response = await http.put(
      Uri.parse('https://api.github.com/repos/$repoFullName/contents/$path'),
      headers: _authHeaders(token),
      body: jsonEncode({
        'message': message,
        'content': base64Encode(utf8.encode(content)),
        if (sha != null) 'sha': sha,
        'branch': branch,
      }),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      final body = jsonDecode(response.body) as Map<String, dynamic>?;
      final apiMessage = body?['message'] as String?;
      throw Exception(
          apiMessage ?? "Couldn't save that file (${response.statusCode}).");
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final commit = json['commit'] as Map<String, dynamic>?;
    final newContent = json['content'] as Map<String, dynamic>?;
    final commitSha = commit?['sha'] as String?;
    return GithubCommitResult(
      commitUrl: commit?['html_url'] as String? ??
          'https://github.com/$repoFullName/commit/$commitSha',
      newSha: newContent?['sha'] as String? ?? sha ?? '',
    );
  }

  /// Commits new text content for an *existing* file — kept as its
  /// own method (rather than inlining [writeFile] everywhere) so the
  /// in-app editor's call site keeps requiring a real [sha], the same
  /// way it always has: a null sha there would silently turn an
  /// intended update into a brand-new-file create if the fetch that
  /// was supposed to supply it ever got skipped.
  Future<GithubCommitResult> commitFile({
    required String repoFullName,
    required String path,
    required String content,
    required String sha,
    required String message,
    required String branch,
  }) {
    return writeFile(
      repoFullName: repoFullName,
      path: path,
      content: content,
      sha: sha,
      message: message,
      branch: branch,
    );
  }

  /// Deletes [path] from [branch] via the Contents API. [sha] must be
  /// the file's current sha (from [fetchFileContent]), same
  /// conflict-guard contract as [writeFile].
  Future<void> deleteFile({
    required String repoFullName,
    required String path,
    required String sha,
    required String message,
    required String branch,
  }) async {
    final token = await _requireToken();
    final response = await http.delete(
      Uri.parse('https://api.github.com/repos/$repoFullName/contents/$path'),
      headers: _authHeaders(token),
      body: jsonEncode({
        'message': message,
        'sha': sha,
        'branch': branch,
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>?;
      final apiMessage = body?['message'] as String?;
      throw Exception(
          apiMessage ?? "Couldn't delete that file (${response.statusCode}).");
    }
  }

  /// Creates a brand-new repo on the connected account via
  /// `POST /user/repos`. `auto_init: true` is deliberate — without it
  /// GitHub creates a repo with no default branch and no commits at
  /// all, which then 404s on every single Contents API call this
  /// service makes (file browser, editor, terminal), leaving a repo
  /// that looks broken everywhere else in the Dev Hub the moment
  /// after it's created.
  Future<GithubRepo> createRepo({
    required String name,
    String? description,
    bool private = false,
  }) async {
    final token = await _requireToken();
    final response = await http.post(
      Uri.parse('https://api.github.com/user/repos'),
      headers: _authHeaders(token),
      body: jsonEncode({
        'name': name,
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
        'private': private,
        'auto_init': true,
      }),
    );
    if (response.statusCode != 201) {
      final body = jsonDecode(response.body) as Map<String, dynamic>?;
      final apiMessage = body?['message'] as String?;
      throw Exception(
          apiMessage ?? "Couldn't create that repo (${response.statusCode}).");
    }
    return GithubRepo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}
