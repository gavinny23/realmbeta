import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../services/audd_service.dart';
import '../services/music_crop_service.dart';
import '../services/music_library_service.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';

/// Second step of "attach music": given a [LibraryTrack] the person
/// already picked from their library, let them drag a fixed-length
/// window (capped at [SupabaseService.statusMaxVideoDurationSeconds])
/// over the track to choose which section to use, preview it on loop,
/// then trim it down with [MusicCropService] and hand back the result.
///
/// Tracks already at or under the limit skip straight to a confirm
/// step — there's nothing to choose.
class MusicCropScreen extends StatefulWidget {
  final LibraryTrack track;
  const MusicCropScreen({super.key, required this.track});

  static Future<CroppedMusicClip?> show(BuildContext context, LibraryTrack track) {
    return Navigator.of(context).push<CroppedMusicClip>(
      MaterialPageRoute(builder: (_) => MusicCropScreen(track: track)),
    );
  }

  @override
  State<MusicCropScreen> createState() => _MusicCropScreenState();
}

class _MusicCropScreenState extends State<MusicCropScreen> {
  static const _clipSeconds = SupabaseService.statusMaxVideoDurationSeconds;

  late final AudioPlayer _player;
  bool _playerReady = false;
  String? _loadError;

  Duration _trackDuration = Duration.zero;
  Duration _windowStart = Duration.zero;
  late final Duration _windowLength;
  bool get _needsCropping => widget.track.duration.inSeconds > _clipSeconds;

  bool _playing = false;
  Duration _position = Duration.zero;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _stateSub;

  bool _saving = false;
  bool _identifying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _trackDuration = widget.track.duration;
    _windowLength = _needsCropping
        ? const Duration(seconds: _clipSeconds)
        : widget.track.duration;
    _player = AudioPlayer();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      await _player.setFilePath(widget.track.filePath);
      if (!mounted) return;
      setState(() => _playerReady = true);
      _positionSub = _player.positionStream.listen((pos) {
        if (!mounted) return;
        setState(() => _position = pos);
        // Loop the preview back to the start of the selected window
        // once it plays past the window's end, rather than continuing
        // into the rest of the song.
        if (_playing && pos >= _windowStart + _windowLength) {
          _player.seek(_windowStart);
        }
      });
      _stateSub = _player.playerStateStream.listen((state) {
        if (!mounted) return;
        if (state.processingState == ProcessingState.completed) {
          setState(() => _playing = false);
        }
      });
    } catch (_) {
      if (mounted) setState(() => _loadError = "Couldn't load that track for preview.");
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (!_playerReady) return;
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
    } else {
      await _player.seek(_windowStart);
      await _player.play();
      setState(() => _playing = true);
    }
  }

  /// Moves the selection window by [deltaSeconds], clamped so it never
  /// runs past either end of the track.
  void _moveWindow(double deltaSeconds) {
    final maxStartSeconds =
        (_trackDuration - _windowLength).inMilliseconds / 1000;
    final newStartSeconds =
        (_windowStart.inMilliseconds / 1000 + deltaSeconds)
            .clamp(0.0, maxStartSeconds < 0 ? 0.0 : maxStartSeconds);
    setState(() {
      _windowStart = Duration(milliseconds: (newStartSeconds * 1000).round());
    });
    if (_playing) _player.seek(_windowStart);
  }

  Future<void> _confirm() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _player.pause();
      final File clipFile;
      if (_needsCropping) {
        clipFile = await MusicCropService.instance.trim(
          sourcePath: widget.track.filePath,
          start: _windowStart,
          duration: _windowLength,
        );
      } else {
        // Already short enough — use the original file untouched
        // rather than paying for a pointless re-encode.
        clipFile = File(widget.track.filePath);
      }

      // Best-effort audio-fingerprint ID against the actual clip
      // that's about to be attached — a no-op with no key configured,
      // and any failure here just means displayTitle/displayArtist
      // fall back to whatever tag the library had, same as before
      // this existed.
      AuddMatch? match;
      if (AuddService.instance.isEnabled) {
        if (mounted) setState(() => _identifying = true);
        match = await AuddService.instance.identify(clipFile);
        if (mounted) setState(() => _identifying = false);
      }

      if (!mounted) return;
      Navigator.of(context).pop(CroppedMusicClip(
        track: widget.track,
        start: _windowStart,
        duration: _windowLength,
        file: clipFile,
        identifiedTitle: match?.title,
        identifiedArtist: match?.artist,
      ));
    } on UnsupportedAudioFormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = "Couldn't prepare that clip — try again.");
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _label(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        backgroundColor: RMColors.background,
        title: const Text('Choose a section'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.music_note_rounded, color: RMColors.primary, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.track.displayLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: RMColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _needsCropping
                    ? 'Drag the highlighted section to pick which $_clipSeconds seconds to use.'
                    : "This track is under ${_clipSeconds}s, so the whole thing will be used.",
                style: TextStyle(color: RMColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 32),
              if (_loadError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(_loadError!,
                      style: TextStyle(color: RMColors.danger, fontSize: 13)),
                ),
              _buildTimeline(),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  '${_label(_windowStart)} – ${_label(_windowStart + _windowLength)} '
                  'of ${_label(_trackDuration)}',
                  style: TextStyle(color: RMColors.textSecondary, fontSize: 13),
                ),
              ),
              const SizedBox(height: 20),
              Center(
                child: IconButton.filled(
                  iconSize: 40,
                  style: IconButton.styleFrom(
                    backgroundColor: RMColors.primary,
                    padding: const EdgeInsets.all(16),
                  ),
                  onPressed: _playerReady ? _togglePlay : null,
                  icon: Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                  ),
                ),
              ),
              const Spacer(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(_error!,
                      style: TextStyle(color: RMColors.danger, fontSize: 13)),
                ),
              FilledButton(
                onPressed: _saving ? null : _confirm,
                child: _saving
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          ),
                          const SizedBox(width: 10),
                          Text(_identifying
                              ? 'Identifying song…'
                              : 'Preparing clip…'),
                        ],
                      )
                    : const Text('Use this clip'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The track's full duration as a horizontal bar, with the selected
  /// window drawn as a highlighted, draggable segment on top of it.
  /// Not a real amplitude waveform — no well-maintained, low-risk
  /// waveform-extraction package was worth pulling in for this pass —
  /// but it gives an accurate, proportional sense of where in the song
  /// the window sits, and dragging it is what actually lets the person
  /// crop from any section.
  Widget _buildTimeline() {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final totalMs = _trackDuration.inMilliseconds.clamp(1, 1 << 31);
      final pxPerMs = width / totalMs;
      final windowWidth =
          (_windowLength.inMilliseconds * pxPerMs).clamp(24.0, width);
      final windowLeft = _windowStart.inMilliseconds * pxPerMs;
      final playheadLeft = _needsCropping
          ? null
          : (_position.inMilliseconds * pxPerMs).clamp(0.0, width);

      return SizedBox(
        height: 64,
        child: Stack(
          children: [
            // The drag surface now covers the whole bar, not just the
            // highlighted window — on a long track the window can be a
            // small sliver (e.g. 30s of a 3:51 song is only ~13% of
            // this bar's width), and requiring a touch to land inside
            // that sliver made dragging feel broken when it was really
            // just an easy-to-miss hit target.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: _needsCropping
                  ? (details) => _moveWindow(details.delta.dx / pxPerMs / 1000)
                  : null,
              child: Container(
                height: 64,
                decoration: BoxDecoration(
                  color: RMColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            Positioned(
              left: windowLeft,
              width: windowWidth,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: RMColors.primary.withOpacity(0.35),
                    border: Border.all(color: RMColors.primary, width: 2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: _needsCropping
                      ? const Center(
                          child: Icon(Icons.drag_indicator_rounded,
                              color: Colors.white, size: 20),
                        )
                      : null,
                ),
              ),
            ),
            if (playheadLeft != null)
              Positioned(
                left: playheadLeft - 1,
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: Colors.white),
              ),
          ],
        ),
      );
    });
  }
}
