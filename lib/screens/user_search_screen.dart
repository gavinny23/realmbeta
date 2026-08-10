import 'dart:async';
import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/presence_avatar.dart';
import 'user_profile_screen.dart';

/// Search for another user by username, opened from the search button on
/// the Explore feed. This is the entry point for finding a specific
/// locked drop now that the feed itself only surfaces already-unlocked
/// ones — search for whoever left it, then open their profile.
class UserSearchScreen extends StatefulWidget {
  final double? currentLat;
  final double? currentLng;

  UserSearchScreen({super.key, this.currentLat, this.currentLng});

  @override
  State<UserSearchScreen> createState() => _UserSearchScreenState();
}

class _UserSearchScreenState extends State<UserSearchScreen> {
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  bool _searched = false;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(Duration(milliseconds: 300), () => _search(query));
  }

  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.length < 2) {
      setState(() { _results = []; _searched = false; });
      return;
    }
    setState(() => _searching = true);
    try {
      final results = await SupabaseService.instance.searchUsers(q);
      final me = SupabaseService.instance.currentUser?.id;
      if (mounted) {
        setState(() {
          _results = results.where((r) => r['id'] != me).toList();
          _searched = true;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Search failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _openProfile(Map<String, dynamic> user) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(
          userId: user['id'] as String,
          username: user['username'] as String? ?? 'unknown',
          currentLat: widget.currentLat,
          currentLng: widget.currentLng,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        backgroundColor: RMColors.background,
        title: Text('Find a user'),
      ),
      body: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search by username',
                prefixIcon: Icon(Icons.search_rounded),
                suffixIcon: _searching
                    ? Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : (_ctrl.text.isNotEmpty
                        ? IconButton(
                            icon: Icon(Icons.clear_rounded),
                            onPressed: () {
                              _ctrl.clear();
                              setState(() { _results = []; _searched = false; });
                            },
                          )
                        : null),
              ),
              onChanged: _onChanged,
              onSubmitted: _search,
            ),
            SizedBox(height: 16),
            Expanded(child: _buildResults()),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (!_searched) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_search_rounded, color: RMColors.textHint, size: 44),
            SizedBox(height: 12),
            Text('Search for a username to see their drops.',
                textAlign: TextAlign.center,
                style: TextStyle(color: RMColors.textSecondary)),
          ],
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text('No users found.',
            style: TextStyle(color: RMColors.textSecondary)),
      );
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, __) => SizedBox(height: 4),
      itemBuilder: (context, i) {
        final r = _results[i];
        return Material(
          color: RMColors.surface,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _openProfile(r),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: RMColors.border),
              ),
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  PresenceAvatar(
                    radius: 20,
                    backgroundColor: RMColors.primaryDim,
                    avatarUrl: r['avatar_url'] as String?,
                    lastActiveAt:
                        DateTime.tryParse(r['last_active_at'] as String? ?? ''),
                    placeholder: Icon(Icons.person_rounded, color: RMColors.primary),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('@${r['username'] ?? ''}',
                            style: TextStyle(
                                color: RMColors.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 14)),
                        if ((r['display_name'] as String?)?.isNotEmpty == true)
                          Text(r['display_name'] as String,
                              style: TextStyle(
                                  color: RMColors.textSecondary, fontSize: 12)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: RMColors.textHint),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
