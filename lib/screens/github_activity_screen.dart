import 'package:flutter/material.dart';
import '../models/github_event.dart';
import '../services/github_service.dart';
import '../theme/rm_theme.dart';

/// The full activity history behind Dev Hub's "Recent activity" — that
/// section only ever teases the latest couple of events, "See more"
/// lands here for the complete list plus a stats header (profile
/// counts alongside numbers rolled up from the activity itself: how
/// many events, how many commits, how many distinct repos touched).
class GithubActivityScreen extends StatefulWidget {
  final Map<String, dynamic>? profile;

  const GithubActivityScreen({super.key, this.profile});

  @override
  State<GithubActivityScreen> createState() => _GithubActivityScreenState();
}

class _GithubActivityScreenState extends State<GithubActivityScreen> {
  List<GithubEvent>? _activity;
  bool _loading = false;
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
      // GitHub's public events feed tops out around 300 entries across
      // 10 pages of 30 — 100 per page is the API's own per-page ceiling,
      // so this is the most "everything recent" gets in one request.
      final activity = await GithubService.instance.fetchActivity(perPage: 100);
      if (mounted) setState(() => _activity = activity);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        title: const Text('All activity'),
        backgroundColor: RMColors.background,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: RMColors.primary,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildStatsCard(),
            const SizedBox(height: 24),
            Text('Every event',
                style: TextStyle(
                    color: RMColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15)),
            const SizedBox(height: 12),
            _buildBody(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsCard() {
    final profile = widget.profile;
    final activity = _activity;

    final repos = profile?['public_repos'] ?? '—';
    final followers = profile?['followers'] ?? '—';
    final following = profile?['following'] ?? '—';

    final eventCount = activity?.length;
    final commitCount = activity
        ?.where((e) => e.type == 'PushEvent')
        .fold<int>(0, (sum, e) => sum + (e.commitCount ?? 0));
    final repoTouched = activity?.map((e) => e.repoName).toSet().length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: RMColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RMColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Account',
              style: TextStyle(
                  color: RMColors.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12)),
          const SizedBox(height: 10),
          Row(
            children: [
              _statChip('Repos', '$repos'),
              const SizedBox(width: 10),
              _statChip('Followers', '$followers'),
              const SizedBox(width: 10),
              _statChip('Following', '$following'),
            ],
          ),
          const SizedBox(height: 16),
          Text('From this activity',
              style: TextStyle(
                  color: RMColors.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12)),
          const SizedBox(height: 10),
          Row(
            children: [
              _statChip('Events', eventCount == null ? '—' : '$eventCount'),
              const SizedBox(width: 10),
              _statChip('Commits', commitCount == null ? '—' : '$commitCount'),
              const SizedBox(width: 10),
              _statChip(
                  'Repos touched', repoTouched == null ? '—' : '$repoTouched'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statChip(String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: RMColors.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Text(value,
                style: TextStyle(
                    color: RMColors.textPrimary, fontWeight: FontWeight.w700)),
            Text(label,
                style: TextStyle(color: RMColors.textSecondary, fontSize: 11),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    final activity = _activity;
    if (activity == null) {
      if (_loading) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      if (_error != null) return _errorTile(_error!);
      return const SizedBox.shrink();
    }
    if (activity.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: RMColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: RMColors.border),
        ),
        child: Text(
          'No recent public activity — once you push, open a PR, or star '
          "something, it'll show up here.",
          style: TextStyle(color: RMColors.textSecondary),
        ),
      );
    }
    return Column(
      children: activity.map((event) => _activityTile(event)).toList(),
    );
  }

  Widget _activityTile(GithubEvent event) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: RMColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RMColors.border),
      ),
      child: Row(
        children: [
          Icon(_iconForType(event.type), color: RMColors.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(event.summary,
                    style: TextStyle(
                        color: RMColors.textPrimary, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(event.repoName,
                    style: TextStyle(color: RMColors.textSecondary, fontSize: 12)),
              ],
            ),
          ),
          Text(_relativeTime(event.createdAt),
              style: TextStyle(color: RMColors.textHint, fontSize: 11)),
        ],
      ),
    );
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'PushEvent':
        return Icons.upload_rounded;
      case 'PullRequestEvent':
        return Icons.merge_type_rounded;
      case 'IssuesEvent':
        return Icons.error_outline_rounded;
      case 'IssueCommentEvent':
      case 'PullRequestReviewCommentEvent':
        return Icons.comment_outlined;
      case 'WatchEvent':
        return Icons.star_border_rounded;
      case 'ForkEvent':
        return Icons.call_split_rounded;
      case 'CreateEvent':
        return Icons.add_circle_outline_rounded;
      case 'DeleteEvent':
        return Icons.delete_outline_rounded;
      case 'ReleaseEvent':
        return Icons.rocket_launch_outlined;
      default:
        return Icons.bolt_rounded;
    }
  }

  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    if (diff.inDays < 30) return '${diff.inDays}d';
    return '${(diff.inDays / 30).floor()}mo';
  }

  Widget _errorTile(String message) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: RMColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RMColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: TextStyle(color: RMColors.danger, fontSize: 13)),
          const SizedBox(height: 8),
          TextButton(onPressed: _load, child: const Text('Try again')),
        ],
      ),
    );
  }
}
