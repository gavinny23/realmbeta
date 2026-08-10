/// A repo from the connected GitHub account's own repo list
/// (`GET /user/repos`), reduced to what the Dev Hub repo picker needs.
class GithubRepo {
  final String fullName; // "owner/repo"
  final String name;
  final String? description;
  final String defaultBranch;
  final bool private;
  final String htmlUrl;
  final DateTime updatedAt;

  const GithubRepo({
    required this.fullName,
    required this.name,
    this.description,
    required this.defaultBranch,
    required this.private,
    required this.htmlUrl,
    required this.updatedAt,
  });

  factory GithubRepo.fromJson(Map<String, dynamic> json) {
    return GithubRepo(
      fullName: json['full_name'] as String,
      name: json['name'] as String,
      description: (json['description'] as String?)?.trim(),
      defaultBranch: json['default_branch'] as String? ?? 'main',
      private: json['private'] as bool? ?? false,
      htmlUrl: json['html_url'] as String,
      updatedAt: DateTime.tryParse(json['pushed_at'] as String? ?? '')
              ?.toLocal() ??
          DateTime.now(),
    );
  }
}
