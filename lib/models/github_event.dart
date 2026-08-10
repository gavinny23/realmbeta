/// A single entry from a connected account's GitHub public events feed
/// (`GET /users/{username}/events/public`), reduced down to just what
/// the activity list in [DevHubScreen] needs to render a line like
/// "Pushed 3 commits to main" with a link back to the repo.
class GithubEvent {
  final String type;
  final String repoName;
  final String repoUrl;
  final DateTime createdAt;
  final String summary;

  /// Number of commits carried by a PushEvent's payload — null for
  /// every other event type. Kept separate from [summary] (rather than
  /// re-parsed out of it) so aggregate stats screens can total commits
  /// pushed without re-reading display text.
  final int? commitCount;

  const GithubEvent({
    required this.type,
    required this.repoName,
    required this.repoUrl,
    required this.createdAt,
    required this.summary,
    this.commitCount,
  });

  factory GithubEvent.fromJson(Map<String, dynamic> json) {
    final repo = json['repo'] as Map<String, dynamic>? ?? const {};
    final repoName = repo['name'] as String? ?? 'unknown/repo';
    final type = json['type'] as String? ?? 'Event';
    final payload = json['payload'] as Map<String, dynamic>? ?? const {};
    final createdAt =
        DateTime.tryParse(json['created_at'] as String? ?? '')?.toLocal() ??
            DateTime.now();

    return GithubEvent(
      type: type,
      repoName: repoName,
      repoUrl: 'https://github.com/$repoName',
      createdAt: createdAt,
      summary: _summarize(type, payload),
      commitCount: type == 'PushEvent'
          ? (payload['commits'] as List?)?.length ?? 0
          : null,
    );
  }

  static String _summarize(String type, Map<String, dynamic> payload) {
    switch (type) {
      case 'PushEvent':
        final commits = (payload['commits'] as List?)?.length ?? 0;
        final ref = ((payload['ref'] as String?) ?? '').split('/').last;
        final branch = ref.isEmpty ? 'a branch' : ref;
        return 'Pushed $commits commit${commits == 1 ? '' : 's'} to $branch';
      case 'PullRequestEvent':
        final action = (payload['action'] as String?) ?? 'updated';
        final merged =
            (payload['pull_request'] as Map?)?['merged'] == true;
        if (action == 'closed' && merged) return 'Merged a pull request';
        return '${_titleCase(action)} a pull request';
      case 'IssuesEvent':
        final action = (payload['action'] as String?) ?? 'updated';
        return '${_titleCase(action)} an issue';
      case 'IssueCommentEvent':
        return 'Commented on an issue';
      case 'PullRequestReviewCommentEvent':
        return 'Commented on a pull request';
      case 'WatchEvent':
        return 'Starred the repo';
      case 'ForkEvent':
        return 'Forked the repo';
      case 'CreateEvent':
        final refType = (payload['ref_type'] as String?) ?? 'repo';
        return 'Created a $refType';
      case 'DeleteEvent':
        final refType = (payload['ref_type'] as String?) ?? 'branch';
        return 'Deleted a $refType';
      case 'ReleaseEvent':
        return 'Published a release';
      case 'PublicEvent':
        return 'Made the repo public';
      default:
        final bare = type.endsWith('Event')
            ? type.substring(0, type.length - 'Event'.length)
            : type;
        return _titleCase(bare);
    }
  }

  static String _titleCase(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }
}
