import 'package:flutter/material.dart';
import '../models/github_content.dart';
import '../services/github_service.dart';
import '../theme/rm_theme.dart';
import 'github_file_editor_screen.dart';

/// One level of a repo's file tree. Tapping a folder pushes another
/// instance of this same screen scoped to that deeper [path]; tapping
/// a file opens [GithubFileEditorScreen]. The repo's own name is
/// shown at the root, and the current folder name for deeper levels —
/// the push stack itself acts as the breadcrumb trail.
class GithubFileBrowserScreen extends StatefulWidget {
  final String repoFullName;
  final String defaultBranch;
  final String path;

  const GithubFileBrowserScreen({
    super.key,
    required this.repoFullName,
    required this.defaultBranch,
    required this.path,
  });

  @override
  State<GithubFileBrowserScreen> createState() =>
      _GithubFileBrowserScreenState();
}

class _GithubFileBrowserScreenState extends State<GithubFileBrowserScreen> {
  List<GithubContent>? _entries;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await GithubService.instance
          .fetchContents(widget.repoFullName, path: widget.path);
      if (mounted) setState(() => _entries = entries);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String get _title {
    if (widget.path.isEmpty) return widget.repoFullName.split('/').last;
    return widget.path.split('/').last;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        title: Text(_title),
        backgroundColor: RMColors.background,
      ),
      body: RefreshIndicator(
        color: RMColors.primary,
        backgroundColor: RMColors.surface,
        onRefresh: _load,
        child: _buildBody(),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createFile,
        icon: const Icon(Icons.note_add_outlined),
        label: const Text('New file'),
      ),
    );
  }

  /// Prompts for a filename (relative to the current folder), then
  /// opens the editor in create mode. The listing refreshes on
  /// return either way — cheap, and means a file created and
  /// committed shows up immediately without a manual pull-to-refresh.
  Future<void> _createFile() async {
    final fileName = await showDialog<String>(
      context: context,
      builder: (ctx) => _NewFileNameDialog(currentPath: widget.path),
    );
    if (fileName == null || fileName.isEmpty || !mounted) return;

    final fullPath =
        widget.path.isEmpty ? fileName : '${widget.path}/$fileName';
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GithubFileEditorScreen(
          repoFullName: widget.repoFullName,
          defaultBranch: widget.defaultBranch,
          path: fullPath,
          isNewFile: true,
        ),
      ),
    );
    if (mounted) _load();
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: RMColors.primary));
    }
    if (_error != null) {
      return _centered(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: RMColors.danger, fontSize: 13)),
            const SizedBox(height: 12),
            TextButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    }
    final entries = _entries ?? const [];
    if (entries.isEmpty) {
      return _centered(
        child: Text('This folder is empty.',
            style: TextStyle(color: RMColors.textSecondary)),
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, i) => _entryTile(entries[i]),
    );
  }

  Widget _entryTile(GithubContent entry) {
    return Material(
      color: RMColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => entry.isDirectory ? _openFolder(entry) : _openFile(entry),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: RMColors.border),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(
                entry.isDirectory
                    ? Icons.folder_rounded
                    : Icons.insert_drive_file_outlined,
                color: entry.isDirectory ? RMColors.accent : RMColors.textSecondary,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(entry.name,
                    style: TextStyle(color: RMColors.textPrimary, fontSize: 14)),
              ),
              if (entry.isDirectory)
                Icon(Icons.chevron_right_rounded, color: RMColors.textHint)
              else
                Text(_formatSize(entry.size),
                    style: TextStyle(color: RMColors.textHint, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }

  void _openFolder(GithubContent entry) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GithubFileBrowserScreen(
          repoFullName: widget.repoFullName,
          defaultBranch: widget.defaultBranch,
          path: entry.path,
        ),
      ),
    );
  }

  void _openFile(GithubContent entry) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GithubFileEditorScreen(
          repoFullName: widget.repoFullName,
          defaultBranch: widget.defaultBranch,
          path: entry.path,
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
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

/// Asks for a new file's name (and, via [currentPath], shows exactly
/// where it'll land) before handing off to the editor. Only checks
/// for an empty name — a name that collides with something already
/// there just becomes a normal overwrite-on-commit, same as it would
/// from the GitHub web UI.
class _NewFileNameDialog extends StatefulWidget {
  final String currentPath;
  const _NewFileNameDialog({required this.currentPath});

  @override
  State<_NewFileNameDialog> createState() => _NewFileNameDialogState();
}

class _NewFileNameDialogState extends State<_NewFileNameDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final location = widget.currentPath.isEmpty ? '/' : '/${widget.currentPath}/';
    return AlertDialog(
      backgroundColor: RMColors.surface,
      title: Text('New file', style: TextStyle(color: RMColors.textPrimary)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Creating in $location',
              style: TextStyle(color: RMColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            style: TextStyle(color: RMColors.textPrimary),
            decoration: const InputDecoration(hintText: 'e.g. notes.md'),
            onSubmitted: (_) => _submit(),
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
          child: const Text('Next'),
        ),
      ],
    );
  }
}
