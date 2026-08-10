import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import '../models/status_post.dart';
import '../services/data_saver_service.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/presence_avatar.dart';

/// Full-screen story-style viewer for a single creator's active
/// statuses, oldest first. Each story auto-advances on a timer (fixed
/// length for photos, actual clip length for video), can be paused by
/// holding, and always shows how long it has left before it
/// disappears for good — see [StatusPost.remainingLabel].
class StatusViewerScreen extends StatefulWidget {
  final String creatorId;

  const StatusViewerScreen({super.key, required this.creatorId});

  @override
  State<StatusViewerScreen> createState() => _StatusViewerScreenState();
}

class _StatusViewerScreenState extends State<StatusViewerScreen>
    with SingleTickerProviderStateMixin {
  static const _photoDuration = Duration(seconds: 6);

  List<StatusPost> _statuses = [];
  int _index = 0;
  bool _loading = true;
  String? _error;

  late final AnimationController _progressCtrl;
  VideoPlayerController? _videoCtrl;
  final Set<String> _markedViewed = {};

  // Swipe-up-to-reply: hidden by default, slides up over the media
  // once the person swipes up (or taps the hint), same gesture IG and
  // WhatsApp Status use.
  bool _showReply = false;
  bool _sendingReply = false;
  final _replyController = TextEditingController();
  final _replyFocusNode = FocusNode();

  bool get _isMine =>
      _statuses.isNotEmpty &&
      _statuses[_index].creatorId == SupabaseService.instance.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _progressCtrl = AnimationController(vsync: this);
    _progressCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) _advance(forward: true);
    });
    _load();
  }

  @override
  void dispose() {
    _progressCtrl.dispose();
    _videoCtrl?.dispose();
    _replyController.dispose();
    _replyFocusNode.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final statuses =
          await SupabaseService.instance.fetchUserStatuses(widget.creatorId);
      if (!mounted) return;
      if (statuses.isEmpty) {
        setState(() { _loading = false; _error = 'This status has expired.'; });
        return;
      }
      setState(() { _statuses = statuses; _loading = false; });
      _playCurrent();
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  bool _isGated(String url) =>
      DataSaverService.instance.enabled &&
      !DataSaverService.instance.isUnlocked(url);

  Future<void> _playCurrent() async {
    _progressCtrl.stop();
    _progressCtrl.reset();
    _videoCtrl?.dispose();
    _videoCtrl = null;

    final current = _statuses[_index];

    // Best-effort — a missed "seen" marker just leaves the ring
    // showing unviewed a little longer, never worth blocking on.
    if (_markedViewed.add(current.id)) {
      SupabaseService.instance.markStatusViewed(current.id);
    }

    // Data saver: don't pull the photo/video down (or start the
    // auto-advance timer) until the person taps to download it —
    // otherwise the story would silently finish loading, and time
    // out, behind a blurred screen they never asked to fetch.
    if (_isGated(current.mediaUrl)) {
      if (mounted) setState(() {});
      return;
    }

    if (current.mediaType == 'video') {
      final ctrl = VideoPlayerController.networkUrl(Uri.parse(current.mediaUrl));
      _videoCtrl = ctrl;
      try {
        await ctrl.initialize();
        if (!mounted || _statuses[_index].id != current.id) return;
        ctrl.play();
        _progressCtrl.duration = ctrl.value.duration;
      } catch (_) {
        // Failed to load — fall back to the fixed photo-style timer
        // rather than getting stuck on a story that never advances.
        _progressCtrl.duration = _photoDuration;
      }
    } else {
      _progressCtrl.duration = _photoDuration;
    }

    if (mounted) setState(() {});
    _progressCtrl.forward(from: 0);
  }

  /// The person tapped the download button on a gated story — unlock
  /// it for the rest of the session and load it for real.
  void _downloadCurrent() {
    DataSaverService.instance.unlock(_statuses[_index].mediaUrl);
    _playCurrent();
  }

  void _advance({required bool forward}) {
    if (forward) {
      if (_index < _statuses.length - 1) {
        setState(() => _index++);
        _playCurrent();
      } else {
        Navigator.of(context).pop();
      }
    } else {
      if (_index > 0) {
        setState(() => _index--);
        _playCurrent();
      } else {
        _progressCtrl.forward(from: 0); // already at the first story
      }
    }
  }

  void _pause() {
    _progressCtrl.stop();
    _videoCtrl?.pause();
  }

  void _resume() {
    _progressCtrl.forward();
    _videoCtrl?.play();
  }

  /// Swipe up (or tap the hint) on someone else's status — never your
  /// own, there's no one to reply to there.
  void _openReply() {
    if (_isMine || _showReply) return;
    _pause();
    setState(() => _showReply = true);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _replyFocusNode.requestFocus());
  }

  void _closeReply() {
    if (!_showReply) return;
    _replyFocusNode.unfocus();
    setState(() => _showReply = false);
    _resume();
  }

  Future<void> _sendReply() async {
    final text = _replyController.text.trim();
    if (text.isEmpty || _sendingReply) return;
    final current = _statuses[_index];

    setState(() => _sendingReply = true);
    try {
      await SupabaseService.instance
          .sendMessage(recipientId: current.creatorId, content: text);
      if (!mounted) return;
      _replyController.clear();
      _replyFocusNode.unfocus();
      setState(() { _showReply = false; _sendingReply = false; });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Reply sent to @${current.creatorUsername}'),
          duration: const Duration(seconds: 2),
        ),
      );
      _resume();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sendingReply = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Couldn't send reply: $e")));
    }
  }

  Future<void> _confirmDelete() async {
    final current = _statuses[_index];
    _pause();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: RMColors.surface,
        title: const Text('Delete this status?'),
        content: const Text('This removes it immediately for everyone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Delete', style: TextStyle(color: RMColors.danger))),
        ],
      ),
    );
    if (confirmed != true) {
      _resume();
      return;
    }
    try {
      await SupabaseService.instance.deleteStatus(current.id);
      if (!mounted) return;
      setState(() => _statuses.removeAt(_index));
      if (_statuses.isEmpty) {
        Navigator.of(context).pop();
      } else {
        if (_index >= _statuses.length) _index = _statuses.length - 1;
        _playCurrent();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Couldn\'t delete: $e')));
        _resume();
      }
    }
  }

  Future<void> _showViewers() async {
    final current = _statuses[_index];
    _pause();
    try {
      final viewers =
          await SupabaseService.instance.fetchStatusViewers(current.id);
      if (!mounted) return;
      await showModalBottomSheet(
        context: context,
        backgroundColor: RMColors.surface,
        isScrollControlled: true,
        builder: (_) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${viewers.length} ${viewers.length == 1 ? 'view' : 'views'}',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Flexible(
                  child: viewers.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          child: Text('No views yet',
                              style: TextStyle(color: RMColors.textSecondary)),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: viewers.length,
                          itemBuilder: (context, i) {
                            final v = viewers[i];
                            return ListTile(
                              leading: PresenceAvatar(
                                radius: 20,
                                backgroundColor: RMColors.primaryDim,
                                avatarUrl: v['avatar_url'] as String?,
                                lastActiveAt: DateTime.tryParse(
                                    v['last_active_at'] as String? ?? ''),
                                placeholder: Icon(Icons.person_rounded,
                                    color: RMColors.primary),
                              ),
                              title: Text('@${v['username']}'),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (_) {
      // Non-fatal — just skip showing the sheet.
    } finally {
      if (mounted) _resume();
    }
  }

  Widget _buildDownloadGate() {
    final current = _statuses[_index];
    return Stack(
      fit: StackFit.expand,
      children: [
        if (current.mediaType == 'photo')
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
            child: CachedNetworkImage(
              imageUrl: current.mediaUrl,
              fit: BoxFit.cover,
              memCacheWidth: 24,
              errorWidget: (_, __, ___) =>
                  Container(color: RMColors.surfaceAlt),
            ),
          )
        else
          Container(color: RMColors.surfaceAlt),
        Container(color: Colors.black.withOpacity(0.25)),
        Center(
          child: GestureDetector(
            onTap: _downloadCurrent,
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black45,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: const Icon(Icons.download_rounded,
                  color: Colors.white, size: 28),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: RMColors.primary)),
      );
    }
    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome_motion_outlined,
                    color: Colors.white38, size: 48),
                const SizedBox(height: 12),
                Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(side: BorderSide(color: Colors.white38)),
                  child: const Text('Close', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final current = _statuses[_index];

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: GestureDetector(
          onTapUp: (details) {
            if (_showReply) {
              _closeReply();
              return;
            }
            final width = MediaQuery.of(context).size.width;
            if (details.globalPosition.dx < width / 3) {
              _advance(forward: false);
            } else {
              _advance(forward: true);
            }
          },
          onLongPressStart: (_) {
            if (!_showReply) _pause();
          },
          onLongPressEnd: (_) {
            if (!_showReply) _resume();
          },
          onVerticalDragEnd: (details) {
            if (_showReply) return;
            final velocity = details.primaryVelocity ?? 0;
            if (velocity < -250) _openReply();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(color: Colors.black),
              if (_isGated(current.mediaUrl))
                _buildDownloadGate()
              else if (current.mediaType == 'video')
                (_videoCtrl != null && _videoCtrl!.value.isInitialized)
                    ? Center(
                        child: AspectRatio(
                          aspectRatio: _videoCtrl!.value.aspectRatio,
                          child: VideoPlayer(_videoCtrl!),
                        ),
                      )
                    : Center(child: CircularProgressIndicator(color: RMColors.primary))
              else
                Center(
                  child: CachedNetworkImage(
                    imageUrl: current.mediaUrl,
                    fit: BoxFit.contain,
                    width: double.infinity,
                  ),
                ),

              IgnorePointer(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 220),
                  opacity: _showReply ? 1 : 0,
                  child: Container(color: Colors.black45),
                ),
              ),

              // Segmented progress bars, one per story.
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: Row(
                  children: [
                    for (var i = 0; i < _statuses.length; i++) ...[
                      if (i > 0) const SizedBox(width: 4),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: SizedBox(
                            height: 2.5,
                            child: i < _index
                                ? Container(color: Colors.white)
                                : i > _index
                                    ? Container(color: Colors.white24)
                                    : AnimatedBuilder(
                                        animation: _progressCtrl,
                                        builder: (context, _) =>
                                            LinearProgressIndicator(
                                          value: _progressCtrl.value,
                                          backgroundColor: Colors.white24,
                                          valueColor: const AlwaysStoppedAnimation(
                                              Colors.white),
                                        ),
                                      ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Header: creator + countdown + close.
              Positioned(
                top: 22,
                left: 12,
                right: 12,
                child: Row(
                  children: [
                    PresenceAvatar(
                      radius: 16,
                      backgroundColor: RMColors.primaryDim,
                      avatarUrl: current.creatorAvatarUrl,
                      lastActiveAt: current.creatorLastActiveAt,
                      // Sits directly on top of the photo/video, not a
                      // card surface — a surface-colored badge ring
                      // would look like a stray patch, so this one
                      // rings against a translucent dark border
                      // instead, same treatment as the gradient/credit
                      // overlays elsewhere on media in this app.
                      badgeBorderColor: Colors.black.withOpacity(0.6),
                      placeholder: Icon(Icons.person_rounded,
                          color: RMColors.primary, size: 16),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('@${current.creatorUsername}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13)),
                          Text(current.remainingLabel,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 11.5)),
                        ],
                      ),
                    ),
                    if (_isMine)
                      IconButton(
                        icon: const Icon(Icons.delete_outline_rounded, color: Colors.white),
                        onPressed: _confirmDelete,
                      ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),

              // Caption, bottom.
              if (current.caption != null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: _isMine ? 64 : 24,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(current.caption!,
                        style: const TextStyle(color: Colors.white, fontSize: 14)),
                  ),
                ),

              // Own status: view count, tappable.
              if (_isMine)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 20,
                  child: GestureDetector(
                    onTap: _showViewers,
                    child: Row(
                      children: [
                        const Icon(Icons.remove_red_eye_outlined,
                            color: Colors.white70, size: 16),
                        const SizedBox(width: 6),
                        Text('${current.viewCount} ${current.viewCount == 1 ? 'view' : 'views'}',
                            style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                      ],
                    ),
                  ),
                ),

              // Someone else's status: swipe-up-to-reply hint, tap
              // also works for anyone who'd rather not swipe.
              if (!_isMine && !_showReply)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 18,
                  child: GestureDetector(
                    onTap: _openReply,
                    behavior: HitTestBehavior.opaque,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.keyboard_arrow_up_rounded,
                            color: Colors.white54, size: 22),
                        Text(
                          'Reply to @${current.creatorUsername}',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),

              // Swipe-up reply box — slides up from off-screen and
              // sits just above the keyboard.
              AnimatedPositioned(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                left: 0,
                right: 0,
                bottom: _showReply
                    ? MediaQuery.of(context).viewInsets.bottom + 12
                    : -80,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Container(
                          constraints: const BoxConstraints(maxHeight: 120),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.white30),
                          ),
                          child: TextField(
                            controller: _replyController,
                            focusNode: _replyFocusNode,
                            minLines: 1,
                            maxLines: 4,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _sendReply(),
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                            cursorColor: RMColors.primary,
                            decoration: InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                              hintText: 'Reply to @${current.creatorUsername}...',
                              hintStyle: const TextStyle(color: Colors.white54, fontSize: 14),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: _closeReply,
                        child: Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          child: const Icon(Icons.close_rounded, color: Colors.white70),
                        ),
                      ),
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: RMColors.primary,
                        ),
                        child: _sendingReply
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : IconButton(
                                icon: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                                onPressed: _sendReply,
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
