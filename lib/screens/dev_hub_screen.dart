import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/dev_hub_build.dart';
import '../models/github_event.dart';
import '../services/cheat_code_service.dart';
import '../services/github_service.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/dev_terminal_panel.dart';
import '../widgets/presence_avatar.dart';
import 'github_activity_screen.dart';
import 'github_repo_browser_screen.dart';

/// Connecting a GitHub account, browsing + editing + committing to
/// its repos from an in-app editor, and the cross-user "what
/// everyone's building" feed of commits made that way.
class DevHubScreen extends StatefulWidget {
  const DevHubScreen({super.key});

  @override
  State<DevHubScreen> createState() => _DevHubScreenState();
}

class _DevHubScreenState extends State<DevHubScreen> {
  Map<String, dynamic>? _profile;
  List<GithubEvent>? _activity;
  bool _loadingData = false;
  String? _dataError;
  String? _connectError;

  List<DevHubBuild>? _feed;
  bool _feedLoading = false;
  String? _feedError;

  bool _terminalOpen = false;

  @override
  void initState() {
    super.initState();
    GithubService.instance.addListener(_onServiceChanged);
    if (GithubService.instance.isConnected) _loadData();
    GithubService.instance.refreshRepoAccess();
    _loadFeed();
  }

  @override
  void dispose() {
    GithubService.instance.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (!mounted) return;
    setState(() {});
    if (GithubService.instance.isConnected && _profile == null) _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _loadingData = true;
      _dataError = null;
    });
    try {
      final results = await Future.wait([
        GithubService.instance.fetchProfile(),
        GithubService.instance.fetchActivity(),
      ]);
      if (!mounted) return;
      setState(() {
        _profile = results[0] as Map<String, dynamic>;
        _activity = results[1] as List<GithubEvent>;
      });
    } catch (e) {
      if (mounted) setState(() => _dataError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingData = false);
    }
  }

  Future<void> _loadFeed() async {
    setState(() {
      _feedLoading = true;
      _feedError = null;
    });
    try {
      final feed = await SupabaseService.instance.fetchDevHubFeed();
      if (mounted) setState(() => _feed = feed);
    } catch (e) {
      if (mounted) setState(() => _feedError = e.toString());
    } finally {
      if (mounted) setState(() => _feedLoading = false);
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      if (GithubService.instance.isConnected) _loadData(),
      _loadFeed(),
    ]);
  }

  Future<void> _connect() async {
    setState(() => _connectError = null);
    try {
      await GithubService.instance.connect();
    } catch (e) {
      if (mounted) setState(() => _connectError = e.toString());
    }
  }

  Future<void> _confirmDisconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: RMColors.surface,
        title: Text('Disconnect GitHub?', style: TextStyle(color: RMColors.textPrimary)),
        content: Text(
          "You'll need to reconnect to see your profile and activity here again.",
          style: TextStyle(color: RMColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Disconnect', style: TextStyle(color: RMColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await GithubService.instance.disconnect();
      setState(() {
        _profile = null;
        _activity = null;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't disconnect: $e")));
      }
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        title: const Text('Dev Hub'),
        backgroundColor: RMColors.background,
      ),
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _refreshAll,
            color: RMColors.primary,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                GithubService.instance.isConnected
                    ? _buildConnectedTop()
                    : _buildDisconnectedCard(),
                const SizedBox(height: 28),
                Text('Cheat codes',
                    style: TextStyle(
                        color: RMColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 15)),
                const SizedBox(height: 12),
                const _CheatCodesSection(),
                const SizedBox(height: 28),
                Text("What everyone's building",
                    style: TextStyle(
                        color: RMColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 15)),
                const SizedBox(height: 12),
                _buildFeedSection(),
              ],
            ),
          ),
          _buildTerminalOverlay(),
        ],
      ),
      floatingActionButton: _terminalOpen
          ? null
          : FloatingActionButton(
              heroTag: 'dev_hub_terminal_fab',
              backgroundColor: RMColors.surfaceAlt,
              foregroundColor: RMColors.primary,
              onPressed: () => setState(() => _terminalOpen = true),
              tooltip: 'Open terminal',
              child: const Icon(Icons.terminal_rounded),
            ),
    );
  }

  /// The mini terminal drawer — anchored to the top of the screen and
  /// dropping down over the rest of Dev Hub rather than sliding up
  /// like a normal bottom sheet, so it reads as a console dropping
  /// in rather than another modal stacking on top of the tab. A
  /// dimmed, tap-to-close backdrop fills whatever's left below it
  /// while it's open; both the backdrop and the panel itself are
  /// skipped from the layout entirely while closed so they don't
  /// intercept taps meant for the page underneath.
  Widget _buildTerminalOverlay() {
    if (!_terminalOpen) return const SizedBox.shrink();
    final screenHeight = MediaQuery.of(context).size.height;
    final panelHeight = (screenHeight * 0.55).clamp(320.0, 560.0).toDouble();
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => setState(() => _terminalOpen = false),
            child: Container(color: Colors.black.withOpacity(0.45)),
          ),
        ),
        Align(
          alignment: Alignment.topCenter,
          child: Material(
            color: RMColors.background,
            elevation: 12,
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(18),
            ),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: double.infinity,
              height: panelHeight,
              child: SafeArea(
                bottom: false,
                child: DevTerminalPanel(
                  onClose: () => setState(() => _terminalOpen = false),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDisconnectedCard() {
    final connecting = GithubService.instance.connecting;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: RMColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RMColors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.code_rounded, color: RMColors.primary, size: 56),
          const SizedBox(height: 16),
          Text(
            'Connect your GitHub',
            style: TextStyle(
                color: RMColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Show your profile and recent activity, browse and edit your '
            'repos right from the app, and share what you commit with '
            'everyone else here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: RMColors.textSecondary),
          ),
          const SizedBox(height: 24),
          if (_connectError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_connectError!,
                  style: TextStyle(color: RMColors.danger, fontSize: 13),
                  textAlign: TextAlign.center),
            ),
          FilledButton.icon(
            onPressed: connecting ? null : _connect,
            icon: connecting
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.link_rounded),
            label: Text(connecting ? 'Opening GitHub…' : 'Connect GitHub'),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectedTop() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildProfileCard(),
        const SizedBox(height: 16),
        _buildBrowseButton(),
        const SizedBox(height: 24),
        Text('Recent activity',
            style: TextStyle(
                color: RMColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 15)),
        const SizedBox(height: 12),
        _buildActivitySection(),
      ],
    );
  }

  Widget _buildBrowseButton() {
    // The identity being linked ([isConnected], already true here since
    // this is only reached from _buildConnectedTop) doesn't guarantee
    // the local repo-scoped token survived — e.g. after a reinstall.
    // Only enable Browse & edit once [hasRepoAccess] confirms that
    // token actually exists, otherwise it's a guaranteed dead end.
    final hasAccess = GithubService.instance.hasRepoAccess;
    final connecting = GithubService.instance.connecting;

    return Material(
      color: RMColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: !hasAccess || connecting
            ? null
            : () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const GithubRepoBrowserScreen()),
                ),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: hasAccess ? RMColors.border : RMColors.border.withOpacity(0.5)),
          ),
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(Icons.folder_open_rounded,
                  color: hasAccess
                      ? RMColors.primary
                      : RMColors.textHint),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Browse & edit',
                        style: TextStyle(
                            color: hasAccess
                                ? RMColors.textPrimary
                                : RMColors.textHint,
                            fontWeight: FontWeight.w700,
                            fontSize: 14)),
                    Text(
                      hasAccess
                          ? 'Open a repo, edit a file, commit right here'
                          : 'Repo access expired — reconnect to use this',
                      style: TextStyle(
                          color: RMColors.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (hasAccess)
                Icon(Icons.chevron_right_rounded, color: RMColors.textHint)
              else
                TextButton(
                  onPressed: connecting ? null : _connect,
                  child: Text(connecting ? 'Opening…' : 'Reconnect'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProfileCard() {
    final profile = _profile;
    if (profile == null) {
      return _loadingData
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          : _dataError != null
              ? _errorTile(_dataError!)
              : const SizedBox.shrink();
    }

    final avatarUrl = profile['avatar_url'] as String?;
    final name = (profile['name'] as String?)?.trim();
    final login = profile['login'] as String? ?? GithubService.instance.username ?? '';
    final bio = (profile['bio'] as String?)?.trim();
    final htmlUrl = profile['html_url'] as String? ?? 'https://github.com/$login';
    final repos = profile['public_repos'] ?? 0;
    final followers = profile['followers'] ?? 0;
    final following = profile['following'] ?? 0;

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
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: RMColors.surfaceAlt,
                backgroundImage:
                    avatarUrl != null ? CachedNetworkImageProvider(avatarUrl) : null,
                child: avatarUrl == null
                    ? Icon(Icons.person_rounded, color: RMColors.textSecondary)
                    : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (name?.isNotEmpty ?? false) ? name! : login,
                      style: TextStyle(
                          color: RMColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 16),
                    ),
                    Text('@$login', style: TextStyle(color: RMColors.textSecondary)),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => _openUrl(htmlUrl),
                child: Icon(Icons.open_in_new_rounded,
                    color: RMColors.textSecondary, size: 20),
              ),
            ],
          ),
          if (bio != null && bio.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(bio, style: TextStyle(color: RMColors.textPrimary)),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              _statChip('Repos', '$repos'),
              const SizedBox(width: 10),
              _statChip('Followers', '$followers'),
              const SizedBox(width: 10),
              _statChip('Following', '$following'),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _confirmDisconnect,
              child: Text('Disconnect', style: TextStyle(color: RMColors.danger)),
            ),
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
            Text(label, style: TextStyle(color: RMColors.textSecondary, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _buildActivitySection() {
    final activity = _activity;
    if (activity == null) {
      return _loadingData
          ? const SizedBox.shrink()
          : _dataError != null
              ? _errorTile(_dataError!)
              : const SizedBox.shrink();
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
    const previewCount = 2;
    final preview = activity.take(previewCount).toList();
    return Column(
      children: [
        ...preview.map((event) => _activityTile(event)),
        if (activity.length > previewCount) _buildSeeMoreTile(),
      ],
    );
  }

  Widget _buildSeeMoreTile() {
    return Material(
      color: RMColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => GithubActivityScreen(profile: _profile),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: RMColors.border),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('See more',
                  style: TextStyle(
                      color: RMColors.primary, fontWeight: FontWeight.w700)),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded, color: RMColors.primary, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _activityTile(GithubEvent event) {
    return GestureDetector(
      onTap: () => _openUrl(event.repoUrl),
      child: Container(
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

  Widget _errorTile(String message, {VoidCallback? onRetry}) {
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
          TextButton(
              onPressed: onRetry ?? _loadData, child: const Text('Try again')),
        ],
      ),
    );
  }

  Widget _buildFeedSection() {
    final feed = _feed;
    if (feed == null) {
      return _feedLoading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          : _feedError != null
              ? _errorTile(_feedError!, onRetry: _loadFeed)
              : const SizedBox.shrink();
    }
    if (feed.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: RMColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: RMColors.border),
        ),
        child: Text(
          'Nobody has shared a build yet — commit a change from the '
          "in-app editor and it'll show up here for everyone.",
          style: TextStyle(color: RMColors.textSecondary),
        ),
      );
    }
    return Column(
      children: feed.map((build) => _buildTile(build)).toList(),
    );
  }

  Widget _buildTile(DevHubBuild build) {
    return GestureDetector(
      onTap: () => _openUrl(build.commitUrl),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: RMColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: RMColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PresenceAvatar(
              radius: 18,
              backgroundColor: RMColors.primaryDim,
              avatarUrl: build.creatorAvatarUrl,
              placeholder: Icon(Icons.person_rounded,
                  color: RMColors.primary, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '@${build.creatorUsername} ',
                                style: TextStyle(
                                    color: RMColors.textPrimary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13),
                              ),
                              TextSpan(
                                text: 'committed to ${build.repoFullName}',
                                style: TextStyle(
                                    color: RMColors.textSecondary,
                                    fontSize: 13),
                              ),
                            ],
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(_relativeTime(build.createdAt),
                          style:
                              TextStyle(color: RMColors.textHint, fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(build.commitMessage,
                      style: TextStyle(
                          color: RMColors.textPrimary, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(build.filePath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: RMColors.textSecondary,
                          fontSize: 12,
                          fontFamily: 'monospace')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Toggle + status for the local, on-device-only cheat codes (e.g.
/// typing "/get-verified" into any message or comment box). This
/// never touches Supabase and nobody else ever sees it — it's purely
/// so you can preview what a verified profile looks like on your own
/// device, on your own account, without a real verification flow.
class _CheatCodesSection extends StatefulWidget {
  const _CheatCodesSection();

  @override
  State<_CheatCodesSection> createState() => _CheatCodesSectionState();
}

class _CheatCodesSectionState extends State<_CheatCodesSection> {
  @override
  void initState() {
    super.initState();
    CheatCodeService.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    CheatCodeService.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  String _formatRemaining(Duration d) {
    if (d.inHours >= 24) {
      final days = d.inHours / 24;
      return '${days.toStringAsFixed(days.truncateToDouble() == days ? 0 : 1)}d left';
    }
    if (d.inHours >= 1) return '${d.inHours}h left';
    return '${d.inMinutes}m left';
  }

  @override
  Widget build(BuildContext context) {
    final service = CheatCodeService.instance;
    final statusLoading = !service.isLoaded;
    final statusRows = <Widget>[];
    if (statusLoading) {
      // The persisted state hasn't been read back yet (this races
      // main.dart's unawaited load() on the very first frame) — show a
      // blurred placeholder with its own progress bar rather than
      // rendering nothing and then having real rows pop in a moment
      // later once load() resolves.
      statusRows.add(_statusSkeletonRow());
    } else {
      if (service.isVerified) {
        statusRows.add(_statusRow(
          icon: Icons.verified_rounded,
          iconColor: Colors.blue,
          label:
              'Verified badge · ${_formatRemaining(service.verifiedRemaining!)}',
        ));
      }
      if (service.hasGoldFrame) {
        statusRows.add(_statusRow(
          icon: Icons.workspace_premium_rounded,
          iconColor: Colors.amber,
          label:
              'Gold frame · ${_formatRemaining(service.goldFrameRemaining!)}',
        ));
      }
      if (service.hasOgBadge) {
        statusRows.add(_statusRow(
          icon: Icons.auto_awesome_rounded,
          iconColor: Colors.amber,
          label: 'OG badge active',
        ));
      }
    }

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
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Cheat mode',
                        style: TextStyle(
                            color: RMColors.textPrimary,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                      'While on, typing one of the codes below into '
                      'any message or comment box redeems it locally '
                      "— nothing here is sent anywhere or seen by "
                      'anyone else.',
                      style: TextStyle(
                          color: RMColors.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Switch(
                value: service.enabled,
                activeColor: RMColors.primary,
                onChanged: (v) => service.setEnabled(v),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _codeRow(CheatCodeService.verifiedTrigger,
              'Blue tick on your profile, 3 days'),
          _codeRow(CheatCodeService.goldFrameTrigger,
              'Gold avatar ring, 24 hours'),
          _codeRow(CheatCodeService.ogBadgeTrigger,
              'Early-adopter chip, toggles on/off'),
          _codeRow(CheatCodeService.rankTrigger,
              'Your real follower/engagement rank vs everyone else'),
          if (statusRows.isNotEmpty) ...[
            const SizedBox(height: 4),
            ...statusRows,
            if (!statusLoading)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => service.clearAll(),
                  child: const Text('Clear all'),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _codeRow(String trigger, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(trigger,
              style: TextStyle(
                  color: RMColors.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  fontFamily: 'monospace')),
          const SizedBox(width: 8),
          Expanded(
            child: Text(description,
                style: TextStyle(color: RMColors.textSecondary, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _statusSkeletonRow() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
            // A generic status row, blurred so it reads as "loading"
            // rather than as real (if stale) content.
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                color: RMColors.surfaceAlt,
                child: Row(
                  children: [
                    Icon(Icons.verified_rounded,
                        color: RMColors.textSecondary, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Checking your status…',
                          style: TextStyle(
                              color: RMColors.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13)),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SizedBox(
                height: 3,
                child: LinearProgressIndicator(
                  backgroundColor: RMColors.surfaceAlt,
                  valueColor: AlwaysStoppedAnimation<Color>(RMColors.primary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusRow({
    required IconData icon,
    required Color iconColor,
    required String label,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: RMColors.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: RMColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}
