import 'package:flutter/material.dart';
import '../models/github_repo.dart';
import '../services/github_service.dart';
import '../theme/rm_theme.dart';
import 'github_file_browser_screen.dart';

/// Entry point into browsing + editing — lists the connected GitHub
/// account's own repos, most recently pushed first. Tapping one opens
/// [GithubFileBrowserScreen] at its root.
class GithubRepoBrowserScreen extends StatefulWidget {
  const GithubRepoBrowserScreen({super.key});

  @override
  State<GithubRepoBrowserScreen> createState() =>
      _GithubRepoBrowserScreenState();
}

class _GithubRepoBrowserScreenState extends State<GithubRepoBrowserScreen> {
  List<GithubRepo>? _repos;
  bool _loading = true;
  String? _error;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    GithubService.instance.addListener(_onServiceChanged);
    _load();
  }

  @override
  void dispose() {
    GithubService.instance.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    // connect() resolves once the OAuth browser is launched, not once
    // linking actually completes — that lands later via this
    // listener. If we're sitting on the repo-access error, that's the
    // moment to retry automatically instead of making the user tap
    // "Try again" a second time themselves.
    if (!mounted) return;
    if (_error != null && GithubService.instance.hasRepoAccess) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repos = await GithubService.instance.fetchRepos();
      if (mounted) setState(() => _repos = repos);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _creating = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        title: const Text('Your repos'),
        backgroundColor: RMColors.background,
      ),
      body: RefreshIndicator(
        color: RMColors.primary,
        backgroundColor: RMColors.surface,
        onRefresh: _load,
        child: _buildBody(),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _creating ? null : _createRepo,
        icon: _creating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add_rounded),
        label: Text(_creating ? 'Creating…' : 'New repo'),
      ),
    );
  }

  Future<void> _createRepo() async {
    final result = await showDialog<_NewRepoResult>(
      context: context,
      builder: (_) => const _NewRepoDialog(),
    );
    if (result == null) return;

    setState(() => _creating = true);
    try {
      final repo = await GithubService.instance.createRepo(
        name: result.name,
        description: result.description,
        private: result.private,
      );
      if (!mounted) return;
      setState(() {
        _repos = [repo, ...(_repos ?? const [])];
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Created ${repo.fullName}')));
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => GithubFileBrowserScreen(
            repoFullName: repo.fullName,
            defaultBranch: repo.defaultBranch,
            path: '',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't create that repo: $e")));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: RMColors.primary));
    }
    if (_error != null) {
      // "Try again" alone is a dead end for the repo-access error
      // specifically — the local token is just gone, so retrying the
      // same call fails forever. Route that one case back to Dev
      // Hub's reconnect flow instead of pretending a retry can help.
      final isAccessError = _error!.contains('reconnect from Dev Hub');
      return _centered(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: RMColors.danger, fontSize: 13)),
            const SizedBox(height: 12),
            if (isAccessError)
              FilledButton.icon(
                onPressed: _connecting
                    ? null
                    : () async {
                        setState(() => _connecting = true);
                        try {
                          await GithubService.instance.connect();
                        } finally {
                          if (mounted) setState(() => _connecting = false);
                        }
                      },
                icon: _connecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.link_rounded),
                label: Text(_connecting ? 'Opening GitHub…' : 'Reconnect GitHub'),
              )
            else
              TextButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    }
    final repos = _repos ?? const [];
    if (repos.isEmpty) {
      return _centered(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_outlined, color: RMColors.textHint, size: 48),
            const SizedBox(height: 12),
            Text('No repos found',
                style: TextStyle(
                    color: RMColors.textPrimary, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('Create a repo on GitHub and it\'ll show up here.',
                style: TextStyle(color: RMColors.textSecondary)),
          ],
        ),
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: repos.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _repoTile(repos[i]),
    );
  }

  Widget _repoTile(GithubRepo repo) {
    return Material(
      color: RMColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => GithubFileBrowserScreen(
              repoFullName: repo.fullName,
              defaultBranch: repo.defaultBranch,
              path: '',
            ),
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: RMColors.border),
          ),
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(
                repo.private ? Icons.lock_outline_rounded : Icons.book_outlined,
                color: RMColors.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(repo.name,
                        style: TextStyle(
                            color: RMColors.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 14)),
                    if (repo.description != null &&
                        repo.description!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(repo.description!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: RMColors.textSecondary, fontSize: 12)),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: RMColors.textHint),
            ],
          ),
        ),
      ),
    );
  }

  Widget _centered({required Widget child}) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: Padding(padding: const EdgeInsets.all(28), child: child)),
        ),
      ),
    );
  }
}

class _NewRepoResult {
  final String name;
  final String? description;
  final bool private;
  const _NewRepoResult({required this.name, this.description, required this.private});
}

/// Name, optional description, and a public/private toggle — the
/// minimum GitHub itself asks for when creating a repo through its
/// own "new repository" form.
class _NewRepoDialog extends StatefulWidget {
  const _NewRepoDialog();

  @override
  State<_NewRepoDialog> createState() => _NewRepoDialogState();
}

class _NewRepoDialogState extends State<_NewRepoDialog> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  bool _private = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(_NewRepoResult(
      name: name,
      description: _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
      private: _private,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: RMColors.surface,
      title: Text('New repo', style: TextStyle(color: RMColors.textPrimary)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            style: TextStyle(color: RMColors.textPrimary),
            decoration: const InputDecoration(hintText: 'Repo name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descCtrl,
            maxLines: 2,
            style: TextStyle(color: RMColors.textPrimary),
            decoration: const InputDecoration(hintText: 'Description (optional)'),
          ),
          CheckboxListTile(
            value: _private,
            onChanged: (v) => setState(() => _private = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            activeColor: RMColors.primary,
            title: Text('Private repo',
                style: TextStyle(color: RMColors.textPrimary, fontSize: 14)),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}
