/// One "what everyone's building" feed entry — a commit made through
/// the Dev Hub's in-app editor, shared with other Realm users. See
/// `fetch_dev_hub_feed` in v20-migration.sql.
class DevHubBuild {
  final String id;
  final String creatorId;
  final String creatorUsername;
  final String? creatorAvatarUrl;
  final String repoFullName;
  final String repoHtmlUrl;
  final String filePath;
  final String commitMessage;
  final String commitUrl;
  final DateTime createdAt;

  const DevHubBuild({
    required this.id,
    required this.creatorId,
    required this.creatorUsername,
    this.creatorAvatarUrl,
    required this.repoFullName,
    required this.repoHtmlUrl,
    required this.filePath,
    required this.commitMessage,
    required this.commitUrl,
    required this.createdAt,
  });

  factory DevHubBuild.fromMap(Map<String, dynamic> map) {
    return DevHubBuild(
      id: map['id'] as String,
      creatorId: map['creator_id'] as String,
      creatorUsername: map['creator_username'] as String? ?? 'unknown',
      creatorAvatarUrl: map['creator_avatar_url'] as String?,
      repoFullName: map['repo_full_name'] as String,
      repoHtmlUrl: map['repo_html_url'] as String,
      filePath: map['file_path'] as String,
      commitMessage: map['commit_message'] as String,
      commitUrl: map['commit_url'] as String,
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
    );
  }
}
