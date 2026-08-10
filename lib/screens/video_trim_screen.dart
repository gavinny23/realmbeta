import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';

/// The trim window the person picked in [VideoTrimScreen]: start point
/// plus length, both within the source video's bounds.
class VideoTrimSelection {
  final Duration start;
  final Duration duration;
  const VideoTrimSelection({required this.start, required this.duration});
}

/// Lets the person trim a status video by hand instead of it silently
/// getting cut to the first N seconds. The selected window is drawn as
/// a highlighted segment over the full-length timeline, with a handle
/// on each end:
///
///  * Drag the middle of the segment to slide the whole window earlier
///    or later without changing how long it is.
///  * Drag either end handle to shrink or grow the window itself — down
///    to [_minWindowSeconds], up to [_maxWindowSeconds] (the status
///    length cap), the same "knob" people expect from a video trimmer.
///
/// This only ever gets pushed when the source is longer than the cap —
/// there's nothing to trim otherwise.
class VideoTrimScreen extends StatefulWidget {
  final File file;
  final Duration videoDuration;

  const VideoTrimScreen({
    super.key,
    required this.file,
    required this.videoDuration,
  });

  static Future<VideoTrimSelection?> show(
    BuildContext context, {
    required File file,
    required Duration videoDuration,
  }) {
    return Navigator.of(context).push<VideoTrimSelection>(
      MaterialPageRoute(
        builder: (_) =>
            VideoTrimScreen(file: file, videoDuration: videoDuration),
      ),
    );
  }

  @override
  State<VideoTrimScreen> createState() => _VideoTrimScreenState();
}

class _VideoTrimScreenState extends State<VideoTrimScreen> {
  static const _maxWindowSeconds = SupabaseService.statusMaxVideoDurationSeconds;
  static const _minWindowSeconds = 3;

  VideoPlayerController? _ctrl;
  String? _loadError;

  late Duration _trackDuration;
  late Duration _windowStart;
  late Duration _windowLength;

  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _trackDuration = widget.videoDuration;
    // Start the window at the front of the clip, at the largest length
    // that still fits under the cap — the same "first N seconds"
    // default as before, just now adjustable.
    _windowLength = Duration(
      seconds: _maxWindowSeconds.clamp(0, _trackDuration.inSeconds),
    );
    _windowStart = Duration.zero;
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      final ctrl = VideoPlayerController.file(widget.file);
      await ctrl.initialize();
      ctrl.setLooping(false);
      ctrl.addListener(_onTick);
      if (!mounted) {
        ctrl.dispose();
        return;
      }
      setState(() => _ctrl = ctrl);
    } catch (_) {
      if (mounted) {
        setState(() => _loadError = "Couldn't load that video for preview.");
      }
    }
  }

  void _onTick() {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    // Loop playback back to the start of the selected window once it
    // reaches the end of the window, rather than playing into the part
    // of the clip that's about to get trimmed away.
    if (_playing && ctrl.value.position >= _windowStart + _windowLength) {
      ctrl.seekTo(_windowStart);
    }
    if (!_playing && ctrl.value.isPlaying) {
      setState(() => _playing = true);
    } else if (_playing && !ctrl.value.isPlaying && ctrl.value.position >= _trackDuration) {
      setState(() => _playing = false);
    }
  }

  @override
  void dispose() {
    _ctrl?.removeListener(_onTick);
    _ctrl?.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (_playing) {
      await ctrl.pause();
      setState(() => _playing = false);
    } else {
      await ctrl.seekTo(_windowStart);
      await ctrl.play();
      setState(() => _playing = true);
    }
  }

  double get _windowStartSeconds => _windowStart.inMilliseconds / 1000;
  double get _windowLengthSeconds => _windowLength.inMilliseconds / 1000;
  double get _trackSeconds => _trackDuration.inMilliseconds / 1000;

  void _applyWindow(double startSeconds, double lengthSeconds) {
    final clampedLength =
        lengthSeconds.clamp(_minWindowSeconds.toDouble(), _maxWindowSeconds.toDouble());
    final maxStart = (_trackSeconds - clampedLength).clamp(0.0, _trackSeconds);
    final clampedStart = startSeconds.clamp(0.0, maxStart);
    setState(() {
      _windowStart = Duration(milliseconds: (clampedStart * 1000).round());
      _windowLength = Duration(milliseconds: (clampedLength * 1000).round());
    });
    final ctrl = _ctrl;
    if (ctrl != null && ctrl.value.isInitialized) {
      ctrl.seekTo(_windowStart);
    }
  }

  /// Move the whole window without resizing it.
  void _dragMove(double deltaSeconds) {
    _applyWindow(_windowStartSeconds + deltaSeconds, _windowLengthSeconds);
  }

  /// Drag the left handle: start moves, end stays put.
  void _dragStartHandle(double deltaSeconds) {
    final fixedEnd = _windowStartSeconds + _windowLengthSeconds;
    final newStart = (_windowStartSeconds + deltaSeconds)
        .clamp(0.0, fixedEnd - _minWindowSeconds);
    final newLength = (fixedEnd - newStart).clamp(
        _minWindowSeconds.toDouble(), _maxWindowSeconds.toDouble());
    _applyWindow(fixedEnd - newLength, newLength);
  }

  /// Drag the right handle: end moves, start stays put.
  void _dragEndHandle(double deltaSeconds) {
    final fixedStart = _windowStartSeconds;
    final newEnd = (fixedStart + _windowLengthSeconds + deltaSeconds)
        .clamp(fixedStart + _minWindowSeconds, _trackSeconds);
    final newLength = (newEnd - fixedStart).clamp(
        _minWindowSeconds.toDouble(), _maxWindowSeconds.toDouble());
    _applyWindow(fixedStart, newLength);
  }

  void _confirm() {
    Navigator.of(context).pop(
      VideoTrimSelection(start: _windowStart, duration: _windowLength),
    );
  }

  String _label(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Trim video'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: _loadError != null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          _loadError!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: RMColors.danger),
                        ),
                      )
                    : (ctrl != null && ctrl.value.isInitialized)
                        ? GestureDetector(
                            onTap: _togglePlay,
                            child: AspectRatio(
                              aspectRatio: ctrl.value.aspectRatio,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  VideoPlayer(ctrl),
                                  if (!_playing)
                                    Container(
                                      color: Colors.black26,
                                      child: const Icon(
                                        Icons.play_arrow_rounded,
                                        color: Colors.white,
                                        size: 56,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          )
                        : const CircularProgressIndicator(color: Colors.white),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Drag the handles to trim, or drag the middle to move it. '
                    'Up to ${_maxWindowSeconds}s.',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  _buildTimeline(),
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      '${_label(_windowStart)} – ${_label(_windowStart + _windowLength)} '
                      '(${_windowLength.inSeconds}s) of ${_label(_trackDuration)}',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _confirm,
                    child: const Text('Use this section'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Full-length timeline bar with the selected window highlighted on
  /// top. Dragging the body of the window moves it; dragging either
  /// edge handle resizes it (the "knob" that shortens/lengthens the
  /// clip, capped between [_minWindowSeconds] and [_maxWindowSeconds]).
  Widget _buildTimeline() {
    const handleWidth = 28.0;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final pxPerSecond = _trackSeconds <= 0 ? 0.0 : width / _trackSeconds;
      final windowLeft = _windowStartSeconds * pxPerSecond;
      final windowWidth =
          (_windowLengthSeconds * pxPerSecond).clamp(handleWidth * 2, width);

      return SizedBox(
        height: 64,
        child: Stack(
          children: [
            Container(
              height: 64,
              decoration: BoxDecoration(
                color: RMColors.surfaceAlt,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            Positioned(
              left: windowLeft,
              width: windowWidth,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: pxPerSecond == 0
                    ? null
                    : (details) => _dragMove(details.delta.dx / pxPerSecond),
                child: Container(
                  decoration: BoxDecoration(
                    color: RMColors.primary.withOpacity(0.35),
                    border: Border.all(color: RMColors.primary, width: 2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Center(
                    child: Icon(Icons.drag_indicator_rounded,
                        color: Colors.white, size: 20),
                  ),
                ),
              ),
            ),
            // Left (start) handle.
            Positioned(
              left: (windowLeft - handleWidth / 2).clamp(0.0, width - handleWidth),
              top: 0,
              bottom: 0,
              width: handleWidth,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: pxPerSecond == 0
                    ? null
                    : (details) => _dragStartHandle(details.delta.dx / pxPerSecond),
                child: _buildHandle(),
              ),
            ),
            // Right (end) handle.
            Positioned(
              left: (windowLeft + windowWidth - handleWidth / 2)
                  .clamp(0.0, width - handleWidth),
              top: 0,
              bottom: 0,
              width: handleWidth,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: pxPerSecond == 0
                    ? null
                    : (details) => _dragEndHandle(details.delta.dx / pxPerSecond),
                child: _buildHandle(),
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildHandle() {
    return Center(
      child: Container(
        width: 8,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(4),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
      ),
    );
  }
}
