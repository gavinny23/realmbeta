import 'dart:async';
import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import 'presence_avatar.dart';

/// A [TextEditingController] that paints `@username` in
/// [RMColors.mention] blue — but only for usernames that have actually
/// resolved to a real, taggable account (see [markResolved]). Anything
/// typed after an `@` that hasn't resolved — because it doesn't match
/// a real user, or because that user has turned off "Allow tagging" in
/// their privacy settings — stays plain text. This is what makes
/// tagging feel "confirmed": the color itself tells you whether the
/// mention will actually notify/link that person.
class MentionTextEditingController extends TextEditingController {
  MentionTextEditingController({super.text});

  /// Lowercased usernames known to be valid, taggable mentions.
  final Set<String> resolvedMentions = {};

  static final RegExp _mentionPattern = RegExp(r'@[A-Za-z0-9_]+');
  static final RegExp _wordChar = RegExp(r'[A-Za-z0-9_@]');

  /// Marks [username] as a confirmed mention and repaints so any
  /// matching `@username` in the current text turns blue immediately.
  void markResolved(String username) {
    if (resolvedMentions.add(username.toLowerCase())) {
      notifyListeners();
    }
  }

  /// All confirmed (blue) mentions currently present in the text —
  /// handy for UI decisions that should only fire for mentions the
  /// user actually saw resolve.
  Set<String> mentionsInText() {
    final found = <String>{};
    for (final m in _mentionPattern.allMatches(text)) {
      final uname = m.group(0)!.substring(1).toLowerCase();
      if (resolvedMentions.contains(uname)) found.add(uname);
    }
    return found;
  }

  /// Every `@word` in the text, whether or not it resolved locally.
  /// Use this (not [mentionsInText]) when deciding who to invite on
  /// send: resolution depends on a 250ms-debounced search, so a fast
  /// send can beat it — this method lets the server (the actual
  /// enforcement point in `invite_mentioned_user`) be the judge of
  /// validity instead of silently dropping the invite.
  Set<String> allMentionsInText() {
    return _mentionPattern
        .allMatches(text)
        .map((m) => m.group(0)!.substring(1).toLowerCase())
        .toSet();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final source = text;
    final mentionStyle = (style ?? const TextStyle()).copyWith(
      color: RMColors.mention,
      fontWeight: FontWeight.w700,
    );
    final spans = <InlineSpan>[];
    int last = 0;
    for (final m in _mentionPattern.allMatches(source)) {
      final start = m.start;
      final prevChar = start > 0 ? source[start - 1] : '';
      final atWordStart = prevChar.isEmpty || !_wordChar.hasMatch(prevChar);
      final uname = m.group(0)!.substring(1).toLowerCase();
      final isValid = atWordStart && resolvedMentions.contains(uname);
      if (start > last) {
        spans.add(TextSpan(text: source.substring(last, start), style: style));
      }
      spans.add(TextSpan(text: m.group(0), style: isValid ? mentionStyle : style));
      last = m.end;
    }
    if (last < source.length) {
      spans.add(TextSpan(text: source.substring(last), style: style));
    }
    return TextSpan(style: style, children: spans);
  }
}

/// Drop-in replacement for a plain `TextField` that adds @mention
/// autocomplete. Pass a [MentionTextEditingController] (not a plain
/// `TextEditingController`) so typed mentions can highlight blue once
/// they resolve to a real, taggable user.
///
/// Usage mirrors `TextField` closely so it's a low-friction swap in
/// existing composers (comments, chat, captions, etc.):
///
/// ```dart
/// final _commentCtrl = MentionTextEditingController();
/// ...
/// MentionComposerField(
///   controller: _commentCtrl,
///   decoration: InputDecoration(hintText: 'Add a comment...'),
///   onSubmitted: (_) => _postComment(),
/// )
/// ```
class MentionComposerField extends StatefulWidget {
  final MentionTextEditingController controller;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final TextStyle? style;
  final int? minLines;
  final int maxLines;
  final TextCapitalization textCapitalization;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;
  final bool autofocus;

  const MentionComposerField({
    super.key,
    required this.controller,
    this.focusNode,
    this.decoration,
    this.style,
    this.minLines,
    this.maxLines = 1,
    this.textCapitalization = TextCapitalization.none,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.autofocus = false,
  });

  @override
  State<MentionComposerField> createState() => _MentionComposerFieldState();
}

class _MentionComposerFieldState extends State<MentionComposerField> {
  List<Map<String, dynamic>> _suggestions = [];
  Timer? _debounce;
  String? _activeQuery;
  int _queryStart = -1;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    final text = widget.controller.text;
    final cursor = widget.controller.selection.baseOffset;
    if (cursor < 0) {
      _closeSuggestions();
      return;
    }

    // Walk backward from the cursor to find an "@" that starts the
    // word we're currently sitting in, stopping at whitespace or the
    // start of the text — that's the mention being typed right now.
    int i = cursor;
    while (i > 0 && text[i - 1] != '@' && !_isBreak(text[i - 1])) {
      i--;
    }
    final hasAt = i > 0 && text[i - 1] == '@';
    if (!hasAt) {
      _closeSuggestions();
      return;
    }
    final query = text.substring(i, cursor);
    _queryStart = i - 1; // include the '@'
    if (query == _activeQuery) return;
    _activeQuery = query;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(query));
  }

  bool _isBreak(String ch) => ch == ' ' || ch == '\n' || ch == '\t';

  Future<void> _search(String query) async {
    if (query.isEmpty) {
      if (mounted) setState(() => _suggestions = []);
      return;
    }
    try {
      final results = await SupabaseService.instance.searchMentionableUsers(query);
      if (!mounted || query != _activeQuery) return;
      // Anyone returned here has tagging enabled, so a typed name that
      // exactly matches one can turn blue right away, without waiting
      // for the person to tap it from the list.
      for (final r in results) {
        final uname = r['username'] as String?;
        if (uname != null && uname.toLowerCase() == query.toLowerCase()) {
          widget.controller.markResolved(uname);
        }
      }
      setState(() => _suggestions = results);
    } catch (_) {
      if (mounted) setState(() => _suggestions = []);
    }
  }

  void _closeSuggestions() {
    _activeQuery = null;
    _queryStart = -1;
    if (_suggestions.isNotEmpty) setState(() => _suggestions = []);
  }

  void _pickSuggestion(Map<String, dynamic> user) {
    final username = user['username'] as String? ?? '';
    if (username.isEmpty || _queryStart < 0) return;
    final text = widget.controller.text;
    final cursor = widget.controller.selection.baseOffset;
    final end = cursor >= 0 ? cursor : text.length;
    final insertion = '@$username ';
    final newText = text.replaceRange(_queryStart, end, insertion);
    widget.controller.markResolved(username);
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: _queryStart + insertion.length),
    );
    _closeSuggestions();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_suggestions.isNotEmpty) _buildSuggestions(),
        TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          decoration: widget.decoration,
          style: widget.style,
          minLines: widget.minLines,
          maxLines: widget.maxLines,
          textCapitalization: widget.textCapitalization,
          textInputAction: widget.textInputAction,
          autofocus: widget.autofocus,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          onTap: widget.onTap,
        ),
      ],
    );
  }

  Widget _buildSuggestions() {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(
        color: RMColors.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RMColors.border),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _suggestions.length,
        itemBuilder: (context, i) {
          final u = _suggestions[i];
          return InkWell(
            onTap: () => _pickSuggestion(u),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  PresenceAvatar(
                    radius: 13,
                    backgroundColor: RMColors.primaryDim,
                    avatarUrl: u['avatar_url'] as String?,
                    placeholder: Icon(Icons.person_rounded,
                        size: 14, color: RMColors.primary),
                  ),
                  const SizedBox(width: 8),
                  Text('@${u['username'] ?? ''}',
                      style: TextStyle(
                          color: RMColors.mention, fontWeight: FontWeight.w700)),
                  if ((u['display_name'] as String?)?.isNotEmpty == true) ...[
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        u['display_name'] as String,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: RMColors.textSecondary, fontSize: 12),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
