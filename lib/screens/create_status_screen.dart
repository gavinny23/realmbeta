import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';
import '../services/data_saver_service.dart';
import '../services/music_crop_service.dart';
import '../services/music_library_service.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/cheat_code_trigger.dart';
import '../widgets/emoji_input.dart';
import 'music_crop_screen.dart';
import 'music_picker_sheet.dart';
import 'video_trim_screen.dart';

/// Posting flow for a single status: pick a photo or a short video,
/// preview it, add an optional caption, then upload. Unlike
/// [CreateFlickScreen] this always posts exactly one piece of media —
/// there's no separate feed to browse afterwards, since the whole
/// point of a status is that it just quietly expires in
/// [SupabaseService.statusMaxVideoDurationSeconds]-and-12-hours time.
///
/// Before anything is captured, this shows a live in-app camera
/// preview (photo/video mode toggle, flip, flash, and a round
/// gallery-shortcut button showing the user's most recent photo) —
/// the same shape as the status-composer camera screen in most chat
/// apps. Once something's picked or shot, it drops into the existing
/// preview + caption + share step below.
class CreateStatusScreen extends StatefulWidget {
  const CreateStatusScreen({super.key});

  @override
  State<CreateStatusScreen> createState() => _CreateStatusScreenState();
}

class _CreateStatusScreenState extends State<CreateStatusScreen>
    with WidgetsBindingObserver {
  final _captionCtrl = TextEditingController();
  File? _mediaFile;
  String? _mediaType; // 'photo' or 'video'
  VideoPlayerController? _previewCtrl;
  bool _saving = false;
  bool _trimming = false;
  double _progress = 0;
  String? _error;
  bool _wasTrimmed = false;
  Duration? _trimmedWindowLength;

  // ─── Attached music (AI title/artist detection lands in a follow-up
  // pass; see MusicPickerSheet / MusicCropScreen) ─────────────────────
  CroppedMusicClip? _musicClip;

  Future<void> _pickMusic() async {
    final track = await MusicPickerSheet.show(context);
    if (track == null || !mounted) return;
    final clip = await MusicCropScreen.show(context, track);
    if (clip != null && mounted) setState(() => _musicClip = clip);
  }

  // ─── Live camera state ──────────────────────────────────────────────
  List<CameraDescription>? _cameras;
  CameraController? _cameraController;
  int _lensIndex = 0;
  bool _cameraInitializing = true;
  String? _cameraError;
  bool _flashOn = false;
  String _captureMode = 'photo'; // 'photo' or 'video'
  bool _isRecording = false;
  Timer? _recordTimer;
  int _recordElapsedSeconds = 0;

  // Bottom-left gallery shortcut thumbnail — the most recent photo in
  // the user's library, same idea as the round gallery button on most
  // status/story composers.
  Uint8List? _galleryThumb;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
    _loadGalleryThumbnail();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordTimer?.cancel();
    _cameraController?.dispose();
    _captionCtrl.dispose();
    _previewCtrl?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (controller != null && controller.value.isInitialized) {
        controller.dispose();
        _cameraController = null;
      }
    } else if (state == AppLifecycleState.resumed) {
      // Also covers the case where the very first attempt (in
      // initState) ran before the OS permission dialog was answered
      // and came back with no controller at all — that failure used
      // to be permanent because this handler bailed out before ever
      // reaching this branch. Retrying here means granting the
      // permission and coming back to the app actually works instead
      // of requiring the screen to be reopened.
      if (controller == null || !controller.value.isInitialized) {
        _initCamera();
      }
    }
  }

  // ─── Camera lifecycle ───────────────────────────────────────────────

  Future<void> _initCamera() async {
    setState(() {
      _cameraInitializing = true;
      _cameraError = null;
    });
    try {
      _cameras ??= await availableCameras();
      final cameras = _cameras;
      if (cameras == null || cameras.isEmpty) {
        setState(() {
          _cameraError = "This device doesn't have a usable camera.";
          _cameraInitializing = false;
        });
        return;
      }
      final description = cameras[_lensIndex.clamp(0, cameras.length - 1)];
      final controller = CameraController(
        description,
        ResolutionPreset.high,
        enableAudio: true,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _cameraController = controller;
        _cameraInitializing = false;
      });
    } catch (e) {
      // Camera permission denied, in use elsewhere, or unsupported —
      // the gallery/record buttons below still work either way.
      debugPrint('[CreateStatusScreen] Camera init failed: $e');
      if (mounted) {
        setState(() {
          _cameraError =
              "Couldn't start the camera — you can still pick something "
              'from your gallery below.';
          _cameraInitializing = false;
        });
      }
    }
  }

  Future<void> _flipCamera() async {
    final cameras = _cameras;
    if (cameras == null || cameras.length < 2 || _isRecording) return;
    final old = _cameraController;
    _cameraController = null;
    setState(() => _cameraInitializing = true);
    await old?.dispose();
    _lensIndex = (_lensIndex + 1) % cameras.length;
    await _initCamera();
  }

  Future<void> _toggleFlash() async {
    final controller = _cameraController;
    if (controller == null) return;
    final next = !_flashOn;
    try {
      await controller.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      setState(() => _flashOn = next);
    } catch (_) {
      // Some front cameras don't support a torch — just leave it as-is.
    }
  }

  Future<void> _capturePhoto() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      final file = await controller.takePicture();
      _setPhoto(File(file.path));
    } catch (_) {
      setState(() => _error = "Couldn't take that photo — try again.");
    }
  }

  Future<void> _toggleVideoRecording() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    if (!_isRecording) {
      try {
        await controller.startVideoRecording();
        _recordElapsedSeconds = 0;
        _recordTimer?.cancel();
        _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted) return;
          setState(() => _recordElapsedSeconds++);
          // Auto-stop at the limit rather than letting the clip run
          // long and relying on the post-hoc trim step below.
          if (_recordElapsedSeconds >=
              SupabaseService.statusMaxVideoDurationSeconds) {
            _toggleVideoRecording();
          }
        });
        setState(() => _isRecording = true);
      } catch (_) {
        setState(() => _error = "Couldn't start recording — try again.");
      }
      return;
    }

    _recordTimer?.cancel();
    _recordTimer = null;
    try {
      final file = await controller.stopVideoRecording();
      setState(() => _isRecording = false);
      await _setVideo(File(file.path));
    } catch (_) {
      setState(() {
        _isRecording = false;
        _error = "Couldn't finish that recording — try again.";
      });
    }
  }

  // ─── Gallery shortcut ───────────────────────────────────────────────

  Future<void> _loadGalleryThumbnail() async {
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth && !permission.hasAccess) return;
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        onlyAll: true,
      );
      if (paths.isEmpty) return;
      final recent = await paths.first.getAssetListRange(start: 0, end: 1);
      if (recent.isEmpty) return;
      final thumb =
          await recent.first.thumbnailDataWithSize(const ThumbnailSize(120, 120));
      if (mounted && thumb != null) setState(() => _galleryThumb = thumb);
    } catch (_) {
      // No big deal — the button just falls back to a plain icon.
    }
  }

  Future<void> _openGalleryPicker() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: RMColors.surface,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Photo from gallery'),
              onTap: () => Navigator.pop(context, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('Video from gallery'),
              onTap: () => Navigator.pop(context, 'video'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'photo') await _pickPhoto(ImageSource.gallery);
    if (choice == 'video') await _pickVideo(ImageSource.gallery);
  }

  // ─── Media handling (unchanged upload path) ────────────────────────

  Future<void> _setVideo(File file) async {
    Duration? duration;
    try {
      final info = await VideoCompress.getMediaInfo(file.path);
      final ms = info.duration;
      if (ms != null) duration = Duration(milliseconds: ms.round());
    } catch (_) {}

    if (!mounted) return;
    var resolvedFile = file;
    var wasTrimmed = false;
    Duration? trimmedWindowLength;

    if (duration != null &&
        duration.inSeconds > SupabaseService.statusMaxVideoDurationSeconds) {
      // Longer than the status cap — let the person pick which section
      // to keep (drag to move it, drag either handle to shorten it)
      // instead of silently cutting to the first N seconds for them.
      final selection = await VideoTrimScreen.show(
        context,
        file: file,
        videoDuration: duration,
      );
      if (selection == null) {
        // They backed out of trimming — don't add a video at all,
        // same as if nothing had been picked/recorded.
        return;
      }
      setState(() {
        _trimming = true;
        _error = null;
      });
      try {
        final trimmed = await VideoCompress.compressVideo(
          file.path,
          quality: VideoQuality.DefaultQuality,
          startTime: selection.start.inSeconds,
          duration: selection.duration.inSeconds,
          deleteOrigin: false,
        );
        if (trimmed?.file != null) {
          resolvedFile = trimmed!.file!;
          wasTrimmed = true;
          trimmedWindowLength = selection.duration;
        }
      } catch (_) {
        // Trimming failed for some reason (unsupported codec, etc.) —
        // ask them to try a different section or file rather than
        // silently uploading something longer than the limit.
        if (mounted) {
          setState(() {
            _trimming = false;
            _error =
                "Couldn't trim that video — please try trimming it again "
                'or pick a shorter one.';
          });
        }
        return;
      }
      if (mounted) setState(() => _trimming = false);
    }

    _previewCtrl?.dispose();
    final ctrl = VideoPlayerController.file(resolvedFile);
    await ctrl.initialize();
    ctrl.setLooping(true);
    ctrl.play();

    if (!mounted) return;
    setState(() {
      _mediaFile = resolvedFile;
      _mediaType = 'video';
      _previewCtrl = ctrl;
      _error = null;
      _wasTrimmed = wasTrimmed;
      _trimmedWindowLength = trimmedWindowLength;
    });
  }

  void _setPhoto(File file) {
    _previewCtrl?.dispose();
    setState(() {
      _mediaFile = file;
      _mediaType = 'photo';
      _previewCtrl = null;
      _error = null;
      _wasTrimmed = false;
      _trimmedWindowLength = null;
    });
  }

  Future<void> _pickPhoto(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 90);
    if (picked != null) _setPhoto(File(picked.path));
  }

  Future<void> _pickVideo(ImageSource source) async {
    final picked = await ImagePicker().pickVideo(
      source: source,
      maxDuration:
          Duration(seconds: SupabaseService.statusMaxVideoDurationSeconds),
    );
    if (picked != null) await _setVideo(File(picked.path));
  }

  Future<void> _post() async {
    final file = _mediaFile;
    final mediaType = _mediaType;
    if (file == null || mediaType == null) {
      setState(() => _error = 'Add a photo or video first.');
      return;
    }
    setState(() { _saving = true; _error = null; _progress = 0; });

    try {
      final caption =
          _captionCtrl.text.trim().isEmpty ? null : _captionCtrl.text.trim();

      if (mediaType == 'video') {
        final dataSaver = DataSaverService.instance.enabled;
        File videoToUpload = file;
        try {
          final compressed = await VideoCompress.compressVideo(
            file.path,
            quality:
                dataSaver ? VideoQuality.LowQuality : VideoQuality.MediumQuality,
            deleteOrigin: false,
          );
          if (compressed?.file != null) videoToUpload = compressed!.file!;
        } catch (_) {
          // Fall back to the original file untouched.
        }

        final videoBytes = await videoToUpload.readAsBytes();
        await SupabaseService.instance.createStatus(
          mediaBytes: videoBytes,
          mediaType: 'video',
          extension: 'mp4',
          caption: caption,
          onProgress: (p) => mounted ? setState(() => _progress = p) : null,
        );
      } else {
        final photoBytes = await file.readAsBytes();
        await SupabaseService.instance.createStatus(
          mediaBytes: photoBytes,
          mediaType: 'photo',
          extension: 'jpg',
          caption: caption,
          onProgress: (p) => mounted ? setState(() => _progress = p) : null,
        );
      }

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ─── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_trimming) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(child: _buildTrimmingIndicator()),
      );
    }
    if (_mediaFile != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('New Status'),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(child: _buildPreview()),
              _buildCaptionAndShare(),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildCameraPreview(),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Spacer(),
                    if (_isRecording)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '0:${_recordElapsedSeconds.toString().padLeft(2, '0')} / '
                          '0:${SupabaseService.statusMaxVideoDurationSeconds}',
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      )
                    else
                      Text(
                        'Visible for 12 hours',
                        style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13),
                      ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(
                        _flashOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                        color: Colors.white,
                      ),
                      onPressed: _cameraController == null ? null : _toggleFlash,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(top: false, child: _buildBottomControls()),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    final controller = _cameraController;
    if (_cameraInitializing) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    if (_cameraError != null || controller == null || !controller.value.isInitialized) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam_off_rounded, color: Colors.white38, size: 48),
              const SizedBox(height: 12),
              Text(
                _cameraError ?? "Camera unavailable.",
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }
    // Camera preview's native resolution rarely matches the screen's
    // aspect ratio — cover-fit it like a native camera app rather than
    // showing letterboxing.
    final size = controller.value.previewSize;
    if (size == null) return const SizedBox.shrink();
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: size.height,
            height: size.width,
            child: CameraPreview(controller),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20, top: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _modeLabel('PHOTO', 'photo'),
              const SizedBox(width: 28),
              _modeLabel('VIDEO', 'video'),
            ],
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _galleryButton(),
                _shutterButton(),
                _flipButton(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeLabel(String label, String mode) {
    final active = _captureMode == mode;
    return GestureDetector(
      onTap: _isRecording ? null : () => setState(() => _captureMode = mode),
      child: Text(
        label,
        style: TextStyle(
          color: active ? Colors.white : Colors.white54,
          fontWeight: active ? FontWeight.bold : FontWeight.w500,
          letterSpacing: 1.2,
          fontSize: 13,
        ),
      ),
    );
  }

  Widget _galleryButton() {
    return GestureDetector(
      onTap: _openGalleryPicker,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          color: _galleryThumb == null ? Colors.white24 : null,
          image: _galleryThumb != null
              ? DecorationImage(image: MemoryImage(_galleryThumb!), fit: BoxFit.cover)
              : null,
        ),
        child: _galleryThumb == null
            ? const Icon(Icons.photo_library_outlined, color: Colors.white, size: 22)
            : null,
      ),
    );
  }

  Widget _shutterButton() {
    return GestureDetector(
      onTap: () {
        if (_captureMode == 'photo') {
          _capturePhoto();
        } else {
          _toggleVideoRecording();
        }
      },
      child: Container(
        width: 74,
        height: 74,
        padding: const EdgeInsets.all(4),
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          border: Border(
            top: BorderSide(color: Colors.white, width: 4),
            bottom: BorderSide(color: Colors.white, width: 4),
            left: BorderSide(color: Colors.white, width: 4),
            right: BorderSide(color: Colors.white, width: 4),
          ),
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            shape: _isRecording ? BoxShape.rectangle : BoxShape.circle,
            borderRadius: _isRecording ? BorderRadius.circular(8) : null,
            color: _captureMode == 'video' && _isRecording
                ? RMColors.danger
                : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _flipButton() {
    final canFlip = (_cameras?.length ?? 0) > 1;
    return SizedBox(
      width: 48,
      height: 48,
      child: canFlip
          ? IconButton(
              icon: const Icon(Icons.cameraswitch_rounded, color: Colors.white),
              onPressed: _isRecording ? null : _flipCamera,
            )
          : null,
    );
  }

  Widget _buildTrimmingIndicator() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: Colors.white),
          const SizedBox(height: 16),
          const Text(
            'Trimming your video…',
            style: TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _buildCaptionAndShare() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_wasTrimmed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.content_cut_rounded,
                      color: RMColors.primary, size: 15),
                  const SizedBox(width: 6),
                  Text(
                    _trimmedWindowLength != null
                        ? 'Trimmed to ${_trimmedWindowLength!.inSeconds}s'
                        : 'Trimmed to '
                            '${SupabaseService.statusMaxVideoDurationSeconds}s',
                    style: TextStyle(
                        color: RMColors.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
          _buildMusicRow(),
          const SizedBox(height: 10),
          TextField(
            controller: _captionCtrl,
            maxLength: 200,
            maxLines: 2,
            style: const TextStyle(color: Colors.white),
            onChanged: (v) =>
                CheatCodeTrigger.watch(context, _captionCtrl, v),
            decoration: InputDecoration(
              hintText: 'Add a caption…',
              hintStyle: const TextStyle(color: Colors.white54),
              counterStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: Colors.white12,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              suffixIcon: EmojiSheetButton(
                controller: _captionCtrl,
                color: Colors.white70,
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!,
                  style: TextStyle(color: RMColors.danger, fontSize: 13)),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _post,
            child: _saving
                ? SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                        value: _progress > 0 ? _progress : null),
                  )
                : const Text('Share to your status'),
          ),
        ],
      ),
    );
  }

  Widget _buildMusicRow() {
    final clip = _musicClip;
    if (clip == null) {
      return OutlinedButton.icon(
        onPressed: _pickMusic,
        icon: Icon(Icons.music_note_rounded, size: 18, color: RMColors.primary),
        label: const Text('Add music'),
        style: OutlinedButton.styleFrom(
          foregroundColor: RMColors.textPrimary,
          side: BorderSide(color: RMColors.border),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.music_note_rounded, size: 16, color: RMColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              clip.track.displayLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          GestureDetector(
            onTap: _pickMusic,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.content_cut_rounded, size: 16, color: Colors.white70),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _musicClip = null),
            child: const Icon(Icons.close_rounded, size: 16, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final ctrl = _previewCtrl;
    return Stack(
      alignment: Alignment.center,
      children: [
        if (_mediaType == 'video')
          (ctrl != null && ctrl.value.isInitialized)
              ? AspectRatio(
                  aspectRatio: ctrl.value.aspectRatio,
                  child: VideoPlayer(ctrl),
                )
              : CircularProgressIndicator(color: RMColors.primary)
        else
          InteractiveViewer(
            child: Image.file(_mediaFile!, fit: BoxFit.contain),
          ),
        Positioned(
          top: 12,
          right: 12,
          child: IconButton.filled(
            style: IconButton.styleFrom(backgroundColor: Colors.black54),
            icon: const Icon(Icons.close_rounded, color: Colors.white),
            onPressed: () {
              _previewCtrl?.dispose();
              setState(() {
                _mediaFile = null;
                _mediaType = null;
                _previewCtrl = null;
              });
            },
          ),
        ),
      ],
    );
  }
}
