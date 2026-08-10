import 'package:flutter/material.dart';
import '../models/github_content.dart';
import '../services/github_service.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';

/// Views and edits a single repo file's text content, committing
/// straight back to GitHub via the Contents API when the person taps
/// Commit. A successful commit can optionally also post to the
/// cross-user "what everyone's building" feed (see
/// SupabaseService.shareDevHubBuild) — that's a separate, best-effort
/// step after the real commit, so a feed-post failure never rolls
/// back or hides a commit that already landed.
class GithubFileEditorScreen extends StatefulWidget {
  final String repoFullName;
  final String defaultBranch;
  final String path;

  /// True when [path] doesn't exist yet — the editor opens straight
  /// into an empty buffer instead of fetching, and the first Commit
  /// creates the file (via [GithubService.writeFile] with no sha)
  /// rather than updating one. See [GithubFileBrowserScreen]'s "New
  /// file" action, which is the only place that passes this.
  final bool isNewFile;

  const GithubFileEditorScreen({
    super.key,
    required this.repoFullName,
    required this.defaultBranch,
    required this.path,
    this.isNewFile = false,
  });

  @override
  State<GithubFileEditorScreen> createState() =>
      _GithubFileEditorScreenState();
}

class _GithubFileEditorScreenState extends State<GithubFileEditorScreen> {
  final _controller = TextEditingController();
  GithubFileContent? _file;
  String? _sha;
  String _originalText = '';
  bool _loading = true;
  bool _committing = false;
  String? _error;
  // Flips to false the moment the new file's first commit lands —
  // after that it behaves exactly like an existing file (dirty only
  // when the text actually differs from what's on GitHub).
  late bool _isNew = widget.isNewFile;

  bool get _dirty => _isNew
      ? true
      : (_file != null && _controller.text != _originalText);

  @override
  void initState() {
    super.initState();
    if (widget.isNewFile) {
      // Nothing to fetch — starts as an empty buffer the person types
      // straight into, same as opening a new file in any editor.
      _loading = false;
      _file = GithubFileContent(path: widget.path, sha: '', content: '');
    } else {
      _load();
    }
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final file = await GithubService.instance
          .fetchFileContent(widget.repoFullName, widget.path);
      if (!mounted) return;
      setState(() {
        _file = file;
        _sha = file.sha;
        _originalText = file.content;
        _controller.text = file.content;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _confirmDiscard() async {
    // For a brand-new, still-empty file there's nothing to lose yet —
    // _dirty is always true for a new file (so Commit stays available
    // even to save it empty), but that shouldn't by itself trigger a
    // "you'll lose your changes" prompt on the way out.
    final hasUnsavedWork = _isNew ? _controller.text.isNotEmpty : _dirty;
    if (!hasUnsavedWork) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: RMColors.surface,
        title: Text('Discard changes?',
            style: TextStyle(color: RMColors.textPrimary)),
        content: Text(
          "You've made changes that haven't been committed. Leaving now will lose them.",
          style: TextStyle(color: RMColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Discard', style: TextStyle(color: RMColors.danger)),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  Future<void> _commit() async {
    if (_committing) return;
    if (!_isNew && _sha == null) return;

    final result = await showDialog<_CommitDialogResult>(
      context: context,
      builder: (_) => _CommitMessageDialog(
        fileName: widget.path.split('/').last,
        isNewFile: _isNew,
      ),
    );
    if (result == null) return;

    setState(() => _committing = true);
    try {
      final commitResult = _isNew
          ? await GithubService.instance.writeFile(
              repoFullName: widget.repoFullName,
              path: widget.path,
              content: _controller.text,
              message: result.message,
              branch: widget.defaultBranch,
            )
          : await GithubService.instance.commitFile(
              repoFullName: widget.repoFullName,
              path: widget.path,
              content: _controller.text,
              sha: _sha!,
              message: result.message,
              branch: widget.defaultBranch,
            );

      if (result.shareToFeed) {
        try {
          await SupabaseService.instance.shareDevHubBuild(
            repoFullName: widget.repoFullName,
            repoHtmlUrl: 'https://github.com/${widget.repoFullName}',
            filePath: widget.path,
            commitMessage: result.message,
            commitUrl: commitResult.commitUrl,
          );
        } catch (_) {
          // Best-effort — the commit itself already succeeded, so a
          // feed-post failure here shouldn't read as the commit having
          // failed too.
        }
      }

      if (!mounted) return;
      setState(() {
        _sha = commitResult.newSha;
        _originalText = _controller.text;
        _isNew = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Committed to ${widget.defaultBranch}')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't commit: $e")));
      }
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _confirmDiscard() && mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: RMColors.background,
        appBar: AppBar(
          title: Text(widget.path.split('/').last),
          backgroundColor: RMColors.background,
          actions: [
            if (_file != null)
              _committing
                  ? const Padding(
                      padding: EdgeInsets.only(right: 16),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : TextButton(
                      onPressed: _dirty ? _commit : null,
                      child: Text(_isNew ? 'Create' : 'Commit',
                          style: TextStyle(
                              color: _dirty
                                  ? RMColors.primary
                                  : RMColors.textHint,
                              fontWeight: FontWeight.w700)),
                    ),
          ],
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: RMColors.primary));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
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
        ),
      );
    }
    return Container(
      color: RMColors.surface,
      padding: const EdgeInsets.all(12),
      child: TextField(
        controller: _controller,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: TextStyle(
          color: RMColors.textPrimary,
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.4,
        ),
        decoration: const InputDecoration(
          border: InputBorder.none,
          filled: false,
          isCollapsed: true,
        ),
      ),
    );
  }
}

class _CommitDialogResult {
  final String message;
  final bool shareToFeed;
  const _CommitDialogResult({required this.message, required this.shareToFeed});
}

class _CommitMessageDialog extends StatefulWidget {
  final String fileName;
  final bool isNewFile;
  const _CommitMessageDialog({required this.fileName, this.isNewFile = false});

  @override
  State<_CommitMessageDialog> createState() => _CommitMessageDialogState();
}

class _CommitMessageDialogState extends State<_CommitMessageDialog> {
  late final TextEditingController _messageCtrl = TextEditingController(
      text:
          '${widget.isNewFile ? 'Create' : 'Update'} ${widget.fileName}');
  bool _shareToFeed = true;

  @override
  void dispose() {
    _messageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: RMColors.surface,
      title: Text(widget.isNewFile ? 'Create file' : 'Commit changes',
          style: TextStyle(color: RMColors.textPrimary)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _messageCtrl,
            autofocus: true,
            maxLength: 280,
            maxLines: 2,
            style: TextStyle(color: RMColors.textPrimary),
            decoration: const InputDecoration(hintText: 'Commit message'),
          ),
          CheckboxListTile(
            value: _shareToFeed,
            onChanged: (v) => setState(() => _shareToFeed = v ?? true),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            activeColor: RMColors.primary,
            title: Text("Share to Dev Hub feed",
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
          onPressed: () {
            final message = _messageCtrl.text.trim();
            if (message.isEmpty) return;
            Navigator.of(context).pop(
              _CommitDialogResult(message: message, shareToFeed: _shareToFeed),
            );
          },
          child: Text(widget.isNewFile ? 'Create' : 'Commit'),
        ),
      ],
    );
  }
}
