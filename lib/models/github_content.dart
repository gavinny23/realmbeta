/// One entry (file or folder) from a repo directory listing
/// (`GET /repos/{repo}/contents/{path}`).
class GithubContent {
  final String name;
  final String path;
  final String type; // 'file' or 'dir'
  final String? sha;
  final int size;

  const GithubContent({
    required this.name,
    required this.path,
    required this.type,
    this.sha,
    this.size = 0,
  });

  bool get isDirectory => type == 'dir';

  factory GithubContent.fromJson(Map<String, dynamic> json) {
    return GithubContent(
      name: json['name'] as String,
      path: json['path'] as String,
      type: json['type'] as String? ?? 'file',
      sha: json['sha'] as String?,
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A single file's decoded text content plus the `sha` GitHub needs
/// back to confirm which version is being replaced on commit — fetched
/// for [GithubFileEditorScreen] via `GithubService.fetchFileContent`.
class GithubFileContent {
  final String path;
  final String sha;
  final String content;

  const GithubFileContent({
    required this.path,
    required this.sha,
    required this.content,
  });
}

/// What a successful commit hands back — the hosted URL to link to
/// from the "what everyone's building" feed, and the file's new `sha`
/// so the editor can keep committing further edits without a refetch.
class GithubCommitResult {
  final String commitUrl;
  final String newSha;

  const GithubCommitResult({required this.commitUrl, required this.newSha});
}
