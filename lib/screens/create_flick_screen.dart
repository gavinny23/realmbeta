import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';
import '../services/data_saver_service.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/emoji_input.dart';

/// Posting flow for a single Flick: pick or record a video, preview it,
/// add an optional caption, then upload. Videos over
/// [SupabaseService.flickMaxDurationSeconds] are rejected up front so
/// the person isn't left waiting through a compress+upload only to be
/// told "too long" at the very end.
class CreateFlickScreen extends StatefulWidget {
  const CreateFlickScreen({super.key});

  @override
  State<CreateFlickScreen> createState() => _CreateFlickScreenState();
}

class _CreateFlickScreenState extends State<CreateFlickScreen> {
  final _captionCtrl = TextEditingController();
  File? _videoFile;
  VideoPlayerController? _previewCtrl;
  Duration? _duration;
  bool _saving = false;
  double _progress = 0;
  String? _error;

  @override
  void dispose() {
    _captionCtrl.dispose();
    _previewCtrl?.dispose();
    super.dispose();
  }

  Future<void> _setVideo(File file) async {
    Duration? duration;
    try {
      final info = await VideoCompress.getMediaInfo(file.path);
      final ms = info.duration;
      if (ms != null) duration = Duration(milliseconds: ms.round());
    } catch (_) {}

    if (duration != null &&
        duration.inSeconds > SupabaseService.flickMaxDurationSeconds) {
      setState(() => _error =
          'That video is ${duration!.inSeconds}s — flicks can be at most '
          '${SupabaseService.flickMaxDurationSeconds} seconds. Trim it and try again.');
      return;
    }

    _previewCtrl?.dispose();
    final ctrl = VideoPlayerController.file(file);
    await ctrl.initialize();
    ctrl.setLooping(true);
    ctrl.play();

    if (!mounted) return;
    setState(() {
      _videoFile = file;
      _duration = duration ?? ctrl.value.duration;
      _previewCtrl = ctrl;
      _error = null;
    });
  }

  Future<void> _pickFromGallery() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    final path = result?.files.single.path;
    if (path != null) await _setVideo(File(path));
  }

  Future<void> _recordVideo() async {
    final picked = await ImagePicker().pickVideo(
      source: ImageSource.camera,
      maxDuration: Duration(seconds: SupabaseService.flickMaxDurationSeconds),
    );
    if (picked != null) await _setVideo(File(picked.path));
  }

  Future<void> _post() async {
    final file = _videoFile;
    if (file == null) {
      setState(() => _error = 'Pick or record a video first.');
      return;
    }
    setState(() { _saving = true; _error = null; _progress = 0; });

    try {
      final dataSaver = DataSaverService.instance.enabled;
      File videoToUpload = file;
      String extension = 'mp4';
      try {
        final compressed = await VideoCompress.compressVideo(
          file.path,
          quality: dataSaver ? VideoQuality.LowQuality : VideoQuality.MediumQuality,
          deleteOrigin: false,
        );
        if (compressed?.file != null) videoToUpload = compressed!.file!;
      } catch (_) {
        // Fall back to the original file untouched.
      }

      List<int>? thumbRaw;
      try {
        final thumbFile =
            await VideoCompress.getFileThumbnail(file.path, quality: 50);
        thumbRaw = await thumbFile.readAsBytes();
      } catch (_) {}
      final Uint8List? thumbBytes =
          thumbRaw != null ? Uint8List.fromList(thumbRaw) : null;

      final videoBytes = await videoToUpload.readAsBytes();
      final duration = _duration ?? Duration.zero;

      await SupabaseService.instance.createFlick(
        videoBytes: videoBytes,
        extension: extension,
        durationSeconds: duration.inSeconds.clamp(1, SupabaseService.flickMaxDurationSeconds).toInt(),
        caption: _captionCtrl.text.trim().isEmpty ? null : _captionCtrl.text.trim(),
        thumbBytes: thumbBytes,
        onProgress: (p) => mounted ? setState(() => _progress = p) : null,
      );

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('New Flick'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _videoFile == null
                  ? _buildPickers()
                  : _buildPreview(),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_videoFile != null)
                    TextField(
                      controller: _captionCtrl,
                      maxLength: 300,
                      maxLines: 2,
                      style: TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Write a caption…',
                        hintStyle: TextStyle(color: Colors.white54),
                        counterStyle: TextStyle(color: Colors.white38),
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
                      padding: EdgeInsets.only(top: 10),
                      child: Text(_error!,
                          style: TextStyle(color: RMColors.danger, fontSize: 13)),
                    ),
                  SizedBox(height: 12),
                  if (_videoFile != null)
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
                          : Text('Post Flick'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPickers() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.movie_creation_outlined, color: Colors.white38, size: 56),
          SizedBox(height: 8),
          Text('Up to ${SupabaseService.flickMaxDurationSeconds} seconds',
              style: TextStyle(color: Colors.white54)),
          SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _recordVideo,
            icon: Icon(Icons.videocam_rounded),
            label: Text('Record a video'),
          ),
          SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickFromGallery,
            icon: Icon(Icons.video_library_outlined, color: Colors.white),
            label: Text('Choose from gallery', style: TextStyle(color: Colors.white)),
            style: OutlinedButton.styleFrom(side: BorderSide(color: Colors.white38)),
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
        if (ctrl != null && ctrl.value.isInitialized)
          AspectRatio(
            aspectRatio: ctrl.value.aspectRatio,
            child: VideoPlayer(ctrl),
          )
        else
          CircularProgressIndicator(color: RMColors.primary),
        Positioned(
          top: 12,
          right: 12,
          child: IconButton.filled(
            style: IconButton.styleFrom(backgroundColor: Colors.black54),
            icon: Icon(Icons.close_rounded, color: Colors.white),
            onPressed: () {
              _previewCtrl?.dispose();
              setState(() {
                _videoFile = null;
                _previewCtrl = null;
                _duration = null;
              });
            },
          ),
        ),
      ],
    );
  }
}

