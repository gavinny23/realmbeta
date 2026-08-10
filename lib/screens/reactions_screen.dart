import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/supabase_service.dart';
import '../widgets/cheat_code_trigger.dart';
import '../widgets/emoji_input.dart';
import '../widgets/presence_avatar.dart';

class ReactionsScreen extends StatefulWidget {
  final String dropId;
  ReactionsScreen({super.key, required this.dropId});

  @override
  State<ReactionsScreen> createState() => _ReactionsScreenState();
}

class _ReactionsScreenState extends State<ReactionsScreen> {
  List<Map<String, dynamic>> _comments = [];
  int _likeCount = 0;
  bool _hasLiked = false;
  bool _loading = true;
  final _commentCtrl = TextEditingController();
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final interactions = await SupabaseService.instance
          .fetchInteractions(dropId: widget.dropId);
      final currentUser = SupabaseService.instance.currentUser;

      setState(() {
        _comments = interactions
            .where((i) => i['type'] == 'comment')
            .toList();
        _likeCount =
            interactions.where((i) => i['type'] == 'like').length;
        _hasLiked = interactions.any((i) =>
            i['type'] == 'like' && i['user_id'] == currentUser?.id);
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleLike() async {
    try {
      if (_hasLiked) {
        await SupabaseService.instance.removeLike(dropId: widget.dropId);
        setState(() {
          _hasLiked = false;
          _likeCount--;
        });
      } else {
        await SupabaseService.instance.addLike(dropId: widget.dropId);
        setState(() {
          _hasLiked = true;
          _likeCount++;
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _postComment() async {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _posting = true);
    try {
      await SupabaseService.instance.addComment(
        dropId: widget.dropId,
        content: text,
      );
      _commentCtrl.clear();
      await _load();
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Reactions')),
      body: _loading
          ? Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Like bar
                Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: _toggleLike,
                        child: Row(
                          children: [
                            Icon(
                              _hasLiked
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              color: _hasLiked ? Colors.red : Colors.grey,
                              size: 28,
                            ),
                            SizedBox(width: 6),
                            Text(
                              '$_likeCount',
                              style: TextStyle(fontSize: 16),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: 16),
                      Text(
                        '${_comments.length} comments',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Divider(height: 1),
                // Comments list
                Expanded(
                  child: _comments.isEmpty
                      ? Center(
                          child: Text('No comments yet — be the first.'))
                      : ListView.separated(
                          padding: EdgeInsets.all(16),
                          itemCount: _comments.length,
                          separatorBuilder: (_, __) =>
                              SizedBox(height: 12),
                          itemBuilder: (context, i) {
                            final c = _comments[i];
                            final createdAt = DateTime.tryParse(
                                    c['created_at'] as String? ?? '') ??
                                DateTime.now();
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                PresenceAvatar(
                                  radius: 16,
                                  avatarUrl:
                                      c['profiles']?['avatar_url'] as String?,
                                  lastActiveAt: DateTime.tryParse(
                                      c['profiles']?['last_active_at']
                                              as String? ??
                                          ''),
                                  placeholder: Icon(Icons.person, size: 16),
                                ),
                                SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            c['profiles']?['username']
                                                    as String? ??
                                                'unknown',
                                            style: TextStyle(
                                                fontWeight: FontWeight.w600),
                                          ),
                                          SizedBox(width: 8),
                                          Text(
                                            DateFormat('MMM d, h:mm a')
                                                .format(createdAt),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                        ],
                                      ),
                                      SizedBox(height: 2),
                                      Text(c['content'] as String? ?? ''),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                ),
                // Comment input
                SafeArea(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _commentCtrl,
                            onChanged: (v) => CheatCodeTrigger.watch(
                                context, _commentCtrl, v),
                            decoration: InputDecoration(
                              hintText: 'Add a comment...',
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              suffixIcon: EmojiSheetButton(
                                controller: _commentCtrl,
                              ),
                            ),
                            onSubmitted: (_) => _postComment(),
                          ),
                        ),
                        SizedBox(width: 8),
                        IconButton.filled(
                          onPressed: _posting ? null : _postComment,
                          icon: _posting
                              ? SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : Icon(Icons.send),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
