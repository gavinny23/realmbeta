import 'package:flutter/material.dart';
import '../models/github_repo.dart';
import '../screens/github_file_editor_screen.dart';
import '../services/github_service.dart';
import '../theme/rm_theme.dart';

enum _TermLineType { input, output, error, success }

class _TermLine {
  final String text;
  final _TermLineType type;
  const _TermLine(this.text, this.type);
}

/// A tiny, GitHub-only terminal: typed commands map onto
/// [GithubService] calls (list repos, browse a tree, cat/touch/rm a
/// file, `echo ... > file` to write and commit content, `new-repo` to
/// create one) instead of running a real shell — there's no
/// filesystem or process to run one against on-device, so this reads
/// commands in that shape and drives the same Contents API the
/// in-app editor and repo browser use.
///
/// Meant to be dropped into a fixed-height slot (see
/// [DevHubScreen]'s slide-down panel) — it fills whatever height it's
/// given rather than sizing itself.
class DevTerminalPanel extends StatefulWidget {
  final VoidCallback? onClose;
  const DevTerminalPanel({super.key, this.onClose});

  @override
  State<DevTerminalPanel> createState() => _DevTerminalPanelState();
}

class _DevTerminalPanelState extends State<DevTerminalPanel> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _inputFocus = FocusNode();

  final List<_TermLine> _lines = [];
  List<GithubRepo>? _repoCache;
  String? _repo; // "owner/repo"
  String? _branch;
  String _path = '';
  bool _busy = false;

  static const _connectedRequiredCommands = {
    'repos', 'use', 'ls', 'cd', 'pwd', 'cat', 'touch', 'rm', 'open',
    'new-repo', 'newrepo', 'echo',
  };

  @override
  void initState() {
    super.initState();
    _print('Realm dev terminal — type "help" to see what this understands.');
    if (!GithubService.instance.isConnected) {
      _print(
        "GitHub isn't connected yet — connect it from Dev Hub, then come back here.",
        _TermLineType.error,
      );
    }
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  String get _prompt {
    final who = GithubService.instance.username ?? 'guest';
    final where = _repo == null
        ? 'realm'
        : '${_repo!.split('/').last}:${_path.isEmpty ? '/' : '/$_path'}';
    return '$who@$where\$ ';
  }

  void _print(String text, [_TermLineType type = _TermLineType.output]) {
    if (!mounted) return;
    setState(() => _lines.add(_TermLine(text, type)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  String _joinPath(String base, String segment) =>
      base.isEmpty ? segment : '$base/$segment';

  GithubRepo? _findRepo(List<GithubRepo> repos, String query) {
    final q = query.toLowerCase();
    for (final r in repos) {
      if (r.fullName.toLowerCase() == q || r.name.toLowerCase() == q) {
        return r;
      }
    }
    return null;
  }

  Future<void> _submit() async {
    final raw = _inputCtrl.text;
    final input = raw.trim();
    _inputCtrl.clear();
    if (input.isEmpty || _busy) return;

    _print(_prompt + input, _TermLineType.input);
    final tokens =
        input.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final cmd = tokens.first.toLowerCase();

    if (_connectedRequiredCommands.contains(cmd) &&
        !GithubService.instance.isConnected) {
      _print("GitHub isn't connected — connect it from Dev Hub first.",
          _TermLineType.error);
      return;
    }

    setState(() => _busy = true);
    try {
      switch (cmd) {
        case 'help':
          _cmdHelp();
          break;
        case 'clear':
          setState(() => _lines.clear());
          break;
        case 'whoami':
          _print(GithubService.instance.username ?? '(not connected)');
          break;
        case 'pwd':
          _print(_repo == null
              ? '(no repo selected)'
              : '$_repo:/${_path.isEmpty ? '' : _path}');
          break;
        case 'repos':
          await _cmdRepos();
          break;
        case 'use':
          await _cmdUse(tokens);
          break;
        case 'ls':
          await _cmdLs(tokens);
          break;
        case 'cd':
          await _cmdCd(tokens);
          break;
        case 'cat':
          await _cmdCat(tokens);
          break;
        case 'touch':
          await _cmdTouch(tokens);
          break;
        case 'rm':
          await _cmdRm(tokens);
          break;
        case 'open':
          await _cmdOpen(tokens);
          break;
        case 'new-repo':
        case 'newrepo':
          await _cmdNewRepo(tokens);
          break;
        case 'echo':
          await _cmdEcho(input);
          break;
        case 'exit':
        case 'close':
        case 'quit':
          widget.onClose?.call();
          break;
        default:
          _print('command not found: $cmd (try "help")', _TermLineType.error);
      }
    } catch (e) {
      _print(e.toString(), _TermLineType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _cmdHelp() {
    const lines = [
      'repos                 list your repos',
      'use <repo>            switch to a repo (name or owner/repo)',
      'ls [path]              list a folder in the current repo',
      'cd <path|..>           change folder ("cd" alone → repo root)',
      'pwd                    show the current repo + folder',
      'cat <file>             print a file\'s contents',
      'touch <file>           create an empty file and commit it',
      'echo "text" > <file>  write text to a file and commit it',
      'rm <file>              delete a file (commits the deletion)',
      'open <file>            open a file in the full editor',
      'new-repo <name> [--private]   create a new repo and switch to it',
      'whoami / pwd / clear / exit',
    ];
    for (final l in lines) {
      _print(l);
    }
  }

  Future<List<GithubRepo>> _repos() async {
    return _repoCache ??= await GithubService.instance.fetchRepos();
  }

  Future<void> _cmdRepos() async {
    _print('fetching repos…');
    final repos = await _repos();
    if (repos.isEmpty) {
      _print('no repos found');
      return;
    }
    for (final r in repos) {
      final label = (r.private ? '(private)' : '(public)').padRight(9);
      _print('$label ${r.fullName}');
    }
  }

  Future<void> _cmdUse(List<String> tokens) async {
    if (tokens.length < 2) {
      _print('usage: use <repo>', _TermLineType.error);
      return;
    }
    final repos = await _repos();
    final match = _findRepo(repos, tokens[1]);
    if (match == null) {
      _print('no repo matching "${tokens[1]}" — try "repos" first',
          _TermLineType.error);
      return;
    }
    setState(() {
      _repo = match.fullName;
      _branch = match.defaultBranch;
      _path = '';
    });
    _print('switched to ${match.fullName}', _TermLineType.success);
  }

  Future<void> _cmdLs(List<String> tokens) async {
    if (_repo == null) {
      _print('no repo selected — try: use <repo>', _TermLineType.error);
      return;
    }
    final target = tokens.length > 1 ? _joinPath(_path, tokens[1]) : _path;
    final entries =
        await GithubService.instance.fetchContents(_repo!, path: target);
    if (entries.isEmpty) {
      _print('(empty)');
      return;
    }
    for (final e in entries) {
      _print('${e.isDirectory ? 'd' : '-'}  ${e.name}');
    }
  }

  Future<void> _cmdCd(List<String> tokens) async {
    if (_repo == null) {
      _print('no repo selected — try: use <repo>', _TermLineType.error);
      return;
    }
    if (tokens.length < 2 || tokens[1] == '/' || tokens[1] == '~') {
      setState(() => _path = '');
      return;
    }
    final arg = tokens[1];
    if (arg == '..') {
      if (_path.isEmpty) {
        _print('already at repo root');
        return;
      }
      final parts = _path.split('/')..removeLast();
      setState(() => _path = parts.join('/'));
      return;
    }
    final newPath = _joinPath(_path, arg);
    try {
      final entries =
          await GithubService.instance.fetchContents(_repo!, path: newPath);
      // A path pointing at a file (rather than a folder) comes back
      // as a single non-directory entry — cd shouldn't silently
      // "succeed" into that.
      if (entries.length == 1 && !entries.first.isDirectory) {
        _print('cd: $arg: not a folder', _TermLineType.error);
        return;
      }
      setState(() => _path = newPath);
    } catch (_) {
      _print('cd: $arg: not found', _TermLineType.error);
    }
  }

  Future<void> _cmdCat(List<String> tokens) async {
    if (_repo == null) {
      _print('no repo selected — try: use <repo>', _TermLineType.error);
      return;
    }
    if (tokens.length < 2) {
      _print('usage: cat <file>', _TermLineType.error);
      return;
    }
    final path = _joinPath(_path, tokens[1]);
    final file = await GithubService.instance.fetchFileContent(_repo!, path);
    if (file.content.isEmpty) {
      _print('(empty file)');
      return;
    }
    final preview = file.content.length > 2000
        ? '${file.content.substring(0, 2000)}\n… (truncated)'
        : file.content;
    _print(preview);
  }

  Future<void> _cmdTouch(List<String> tokens) async {
    if (_repo == null) {
      _print('no repo selected — try: use <repo>', _TermLineType.error);
      return;
    }
    if (tokens.length < 2) {
      _print('usage: touch <file>', _TermLineType.error);
      return;
    }
    final path = _joinPath(_path, tokens[1]);
    final result = await GithubService.instance.writeFile(
      repoFullName: _repo!,
      path: path,
      content: '',
      message: 'Create $path via Realm terminal',
      branch: _branch ?? 'main',
    );
    _print('created $path', _TermLineType.success);
    _print(result.commitUrl);
  }

  Future<void> _cmdRm(List<String> tokens) async {
    if (_repo == null) {
      _print('no repo selected — try: use <repo>', _TermLineType.error);
      return;
    }
    if (tokens.length < 2) {
      _print('usage: rm <file>', _TermLineType.error);
      return;
    }
    final path = _joinPath(_path, tokens[1]);
    final file = await GithubService.instance.fetchFileContent(_repo!, path);
    await GithubService.instance.deleteFile(
      repoFullName: _repo!,
      path: path,
      sha: file.sha,
      message: 'Delete $path via Realm terminal',
      branch: _branch ?? 'main',
    );
    _print('deleted $path', _TermLineType.success);
  }

  Future<void> _cmdOpen(List<String> tokens) async {
    if (_repo == null) {
      _print('no repo selected — try: use <repo>', _TermLineType.error);
      return;
    }
    if (tokens.length < 2) {
      _print('usage: open <file>', _TermLineType.error);
      return;
    }
    final path = _joinPath(_path, tokens[1]);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GithubFileEditorScreen(
          repoFullName: _repo!,
          defaultBranch: _branch ?? 'main',
          path: path,
        ),
      ),
    );
  }

  Future<void> _cmdNewRepo(List<String> tokens) async {
    if (tokens.length < 2) {
      _print('usage: new-repo <name> [--private]', _TermLineType.error);
      return;
    }
    final private = tokens.contains('--private');
    final name = tokens[1];
    _print('creating repo $name…');
    final repo = await GithubService.instance.createRepo(
      name: name,
      private: private,
    );
    _repoCache = [repo, ...?_repoCache];
    setState(() {
      _repo = repo.fullName;
      _branch = repo.defaultBranch;
      _path = '';
    });
    _print('created ${repo.fullName} — now using it', _TermLineType.success);
    _print(repo.htmlUrl);
  }

  Future<void> _cmdEcho(String raw) async {
    final match =
        RegExp(r'^echo\s+(.*?)\s*>\s*(\S+)$', dotAll: true).firstMatch(raw);
    if (match == null) {
      _print('usage: echo "text" > <file>', _TermLineType.error);
      return;
    }
    if (_repo == null) {
      _print('no repo selected — try: use <repo>', _TermLineType.error);
      return;
    }
    var content = match.group(1)!.trim();
    if (content.length >= 2 &&
        ((content.startsWith('"') && content.endsWith('"')) ||
            (content.startsWith("'") && content.endsWith("'")))) {
      content = content.substring(1, content.length - 1);
    }
    final path = _joinPath(_path, match.group(2)!);

    String? sha;
    try {
      final existing =
          await GithubService.instance.fetchFileContent(_repo!, path);
      sha = existing.sha;
    } catch (_) {
      sha = null; // doesn't exist yet — writeFile will create it
    }
    final result = await GithubService.instance.writeFile(
      repoFullName: _repo!,
      path: path,
      content: '$content\n',
      sha: sha,
      message: '${sha == null ? 'Create' : 'Update'} $path via Realm terminal',
      branch: _branch ?? 'main',
    );
    _print('${sha == null ? 'created' : 'updated'} $path',
        _TermLineType.success);
    _print(result.commitUrl);
  }

  Color _colorFor(_TermLineType type) {
    switch (type) {
      case _TermLineType.input:
        return RMColors.primary;
      case _TermLineType.error:
        return RMColors.danger;
      case _TermLineType.success:
        return RMColors.success;
      case _TermLineType.output:
        return RMColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          decoration: BoxDecoration(
            color: RMColors.surfaceAlt,
            border: Border(bottom: BorderSide(color: RMColors.border)),
          ),
          child: Row(
            children: [
              Icon(Icons.terminal_rounded, size: 16, color: RMColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _repo == null ? 'Terminal' : '$_repo — ${_branch ?? ''}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: RMColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      fontFamily: 'monospace'),
                ),
              ),
              IconButton(
                icon: Icon(Icons.close_rounded, color: RMColors.textSecondary),
                onPressed: widget.onClose,
                tooltip: 'Close terminal',
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: RMColors.background,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: ListView.builder(
              controller: _scrollCtrl,
              itemCount: _lines.length,
              itemBuilder: (context, i) {
                final line = _lines[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: SelectableText(
                    line.text,
                    style: TextStyle(
                      color: _colorFor(line.type),
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      height: 1.4,
                      fontWeight: line.type == _TermLineType.input
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: RMColors.surfaceAlt,
            border: Border(top: BorderSide(color: RMColors.border)),
          ),
          child: Row(
            children: [
              Text(_prompt,
                  style: TextStyle(
                      color: RMColors.primary,
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700)),
              Expanded(
                child: TextField(
                  controller: _inputCtrl,
                  focusNode: _inputFocus,
                  autofocus: false,
                  enabled: !_busy,
                  onSubmitted: (_) => _submit(),
                  style: TextStyle(
                      color: RMColors.textPrimary,
                      fontFamily: 'monospace',
                      fontSize: 12.5),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    hintText: 'type a command — try "help"',
                  ),
                ),
              ),
              _busy
                  ? const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      icon: Icon(Icons.send_rounded,
                          size: 18, color: RMColors.primary),
                      onPressed: _submit,
                      tooltip: 'Run',
                    ),
            ],
          ),
        ),
      ],
    );
  }
}
