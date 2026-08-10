import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:video_compress/video_compress.dart';
import '../models/drop.dart';
import '../services/data_saver_service.dart';
import '../services/supabase_service.dart';
import '../services/onboarding_service.dart';
import '../services/drop_events.dart';
import '../services/music_crop_service.dart';
import '../services/music_library_service.dart';
import '../theme/rm_theme.dart';
import 'music_crop_screen.dart';
import 'music_picker_sheet.dart';
import '../widgets/presence_avatar.dart';
import '../widgets/tutorial_overlay.dart';
import '../widgets/location_autocomplete_field.dart';
import '../widgets/upload_progress_toast.dart';
import '../widgets/emoji_input.dart';

/// Argument bundle for [_resizeAndEncodeJpeg] — `compute` requires a
/// single argument, so the resize/quality settings travel with the bytes.
class _PhotoCompressArgs {
  final Uint8List bytes;
  final int maxDimension;
  final int quality;
  _PhotoCompressArgs({
    required this.bytes,
    required this.maxDimension,
    required this.quality,
  });
}

/// Decodes, downsamples (if needed), and re-encodes a photo as JPEG.
/// Runs on a background isolate via `compute` — must be a top-level
/// (or static) function for that. Returns null if the bytes can't be
/// decoded as an image at all.
Uint8List? _resizeAndEncodeJpeg(_PhotoCompressArgs args) {
  final decoded = img.decodeImage(args.bytes);
  if (decoded == null) return null;

  img.Image toEncode = decoded;
  final longestEdge = decoded.width > decoded.height ? decoded.width : decoded.height;
  if (longestEdge > args.maxDimension) {
    toEncode = decoded.width >= decoded.height
        ? img.copyResize(decoded, width: args.maxDimension)
        : img.copyResize(decoded, height: args.maxDimension);
  }

  return Uint8List.fromList(img.encodeJpg(toEncode, quality: args.quality));
}

class _VideoCompressResult {
  final Uint8List bytes;
  /// New extension to use, or null to keep the original file's extension
  /// (compression was skipped/failed and the source bytes are unchanged).
  final String? extension;
  final Uint8List? thumbBytes;
  _VideoCompressResult({required this.bytes, this.extension, this.thumbBytes});
}

/// One file the user has picked to attach to this drop, plus everything
/// needed to preview and later upload it.
class _PickedMedia {
  final File file;
  final String mediaType; // 'photo' | 'video' | 'document'
  final String fileName;
  int? sizeBytes;

  _PickedMedia({
    required this.file,
    required this.mediaType,
    required this.fileName,
    this.sizeBytes,
  });

  String get extension {
    final parts = file.path.split('.');
    return parts.length > 1 ? parts.last.toLowerCase() : 'bin';
  }
}

class CreateDropScreen extends StatefulWidget {
  final double lat;
  final double lng;

  CreateDropScreen({super.key, required this.lat, required this.lng});

  @override
  State<CreateDropScreen> createState() => _CreateDropScreenState();
}

class _CreateDropScreenState extends State<CreateDropScreen>
    with SingleTickerProviderStateMixin {
  final _captionCtrl = TextEditingController();
  final _userSearchCtrl = TextEditingController();
  int _radius = 50;
  final List<_PickedMedia> _mediaList = [];
  String _visibility = 'public';
  bool _allowDownload = true;
  List<String> _allowedUsers = [];
  List<Map<String, dynamic>> _userSuggestions = [];
  bool _saving = false;
  bool _searchingUsers = false;
  bool _showTutorial = false;
  String? _error;

  // ─── Attached music. Title/artist come from MusicCropScreen, which
  // runs an AudD fingerprint match against the clip and prefers that
  // over the device's own (often missing/wrong) file tag — see
  // CroppedMusicClip.displayTitle/displayArtist. ─────────────────────
  CroppedMusicClip? _musicClip;

  Future<void> _pickMusic() async {
    final track = await MusicPickerSheet.show(context);
    if (track == null || !mounted) return;
    final clip = await MusicCropScreen.show(context, track);
    if (clip != null && mounted) setState(() => _musicClip = clip);
  }

  late AnimationController _enterCtrl;
  late Animation<double> _enterFade;

  @override
  void initState() {
    super.initState();
    _enterCtrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 400),
    )..forward();
    _enterFade = CurvedAnimation(parent: _enterCtrl, curve: Curves.easeOut);
    _checkTutorial();
  }

  @override
  void dispose() {
    _captionCtrl.dispose();
    _userSearchCtrl.dispose();
    _enterCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkTutorial() async {
    final show = await OnboardingService.instance.shouldShowDropTutorial();
    if (mounted) setState(() => _showTutorial = show);
  }

  /// Reads file size off disk (falls back to null on any read error —
  /// we'd rather show "no size" than block the pick).
  Future<int?> _sizeOf(File file) async {
    try {
      return await file.length();
    } catch (_) {
      return null;
    }
  }

  /// Resizes + re-encodes a photo before upload. Runs on a background
  /// isolate via `compute` since decoding/encoding a full-resolution
  /// photo is heavy enough to jank the UI if done on the main isolate.
  /// Falls back to the original bytes untouched if decoding fails
  /// (unsupported format, corrupt file, etc.) — better to upload the
  /// original than to fail the whole drop over a thumbnail nicety.
  Future<Uint8List> _compressPhoto(Uint8List bytes) async {
    try {
      final result = await compute(_resizeAndEncodeJpeg, _PhotoCompressArgs(
        bytes: bytes,
        maxDimension: DataSaverService.instance.photoMaxDimension,
        quality: DataSaverService.instance.photoQuality,
      ));
      // Only use the compressed version if it's actually smaller —
      // a tiny/already-compressed source image can re-encode larger.
      return result != null && result.length < bytes.length ? result : bytes;
    } catch (_) {
      return bytes;
    }
  }

  /// Compresses a video before upload and grabs a static first-frame
  /// thumbnail alongside it (used by the feed instead of ever spinning
  /// up a real video player per card — see media_thumbnail.dart).
  /// Returns the (possibly unchanged) video bytes/extension plus the
  /// thumbnail bytes, or nulls for the thumbnail if generation fails.
  Future<_VideoCompressResult> _compressVideo(File file) async {
    final dataSaver = DataSaverService.instance.enabled;
    File? compressed;
    Uint8List? thumbBytes;
    try {
      final info = await VideoCompress.compressVideo(
        file.path,
        quality: dataSaver ? VideoQuality.LowQuality : VideoQuality.MediumQuality,
        deleteOrigin: false,
      );
      compressed = info?.file;
    } catch (_) {
      // Compression can fail on some devices/formats — just fall back
      // to uploading the original file untouched.
      compressed = null;
    }

    try {
      final thumbFile = await VideoCompress.getFileThumbnail(
        file.path,
        quality: 50,
      );
      thumbBytes = await thumbFile.readAsBytes();
    } catch (_) {
      thumbBytes = null;
    }

    if (compressed != null) {
      final compressedBytes = await compressed.readAsBytes();
      final originalSize = await _sizeOf(file) ?? compressedBytes.length + 1;
      if (compressedBytes.length < originalSize) {
        return _VideoCompressResult(
          bytes: compressedBytes,
          extension: 'mp4',
          thumbBytes: thumbBytes,
        );
      }
    }

    return _VideoCompressResult(
      bytes: await file.readAsBytes(),
      extension: null, // caller keeps the original extension
      thumbBytes: thumbBytes,
    );
  }

  Future<void> _addPicked(File file, String mediaType, String name) async {
    final size = await _sizeOf(file);
    if (!mounted) return;
    setState(() {
      _mediaList.add(_PickedMedia(
        file: file,
        mediaType: mediaType,
        fileName: name,
        sizeBytes: size,
      ));
      _error = null;
    });
  }

  /// Quick single photo capture straight from the camera.
  Future<void> _capturePhoto() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: 1600,
      imageQuality: 85,
    );
    if (picked != null) {
      await _addPicked(File(picked.path), 'photo', picked.name);
    }
  }

  /// Pick one or more photos from the gallery.
  Future<void> _pickPhotos() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (result == null) return;
    for (final f in result.files) {
      if (f.path == null) continue;
      await _addPicked(File(f.path!), 'photo', f.name);
    }
  }

  /// Pick one or more videos. Anything longer than [_maxVideoSeconds] is
  /// rejected up front — checking duration here (rather than after a
  /// slow compress+upload) means the user finds out immediately.
  static const _maxVideoSeconds = 30;

  Future<void> _pickVideos() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: true,
    );
    if (result == null) return;
    var rejectedCount = 0;
    for (final f in result.files) {
      if (f.path == null) continue;
      final path = f.path!;
      Duration? duration;
      try {
        final info = await VideoCompress.getMediaInfo(path);
        final ms = info.duration;
        if (ms != null) duration = Duration(milliseconds: ms.round());
      } catch (_) {
        // If duration can't be read, let it through rather than
        // blocking a valid upload over a probing failure.
      }
      if (duration != null && duration.inSeconds > _maxVideoSeconds) {
        rejectedCount++;
        continue;
      }
      await _addPicked(File(path), 'video', f.name);
    }
    if (rejectedCount > 0 && mounted) {
      setState(() => _error = rejectedCount == 1
          ? 'That video is longer than 30 seconds — trim it and try again.'
          : '$rejectedCount videos were longer than 30 seconds and were skipped.');
    }
  }

  // Document attachments are coming in a future version — the picker
  // entry point for them has been removed from the UI below, but the
  // model/backend still understand `mediaType == 'document'` so any
  // drops created before this change keep working.

  void _removeMedia(int index) {
    setState(() => _mediaList.removeAt(index));
  }

  Future<void> _searchUsers(String query) async {
    if (query.length < 2) {
      setState(() => _userSuggestions = []);
      return;
    }
    setState(() => _searchingUsers = true);
    try {
      final results = await SupabaseService.instance.searchUsers(query);
      setState(() {
        _userSuggestions = results
            .where((u) => !_allowedUsers.contains(u['username']))
            .toList();
      });
    } finally {
      if (mounted) setState(() => _searchingUsers = false);
    }
  }

  void _addUser(String username) {
    setState(() {
      if (!_allowedUsers.contains(username)) _allowedUsers.add(username);
      _userSearchCtrl.clear();
      _userSuggestions = [];
    });
  }

  Future<void> _save() async {
    if (_captionCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Add a caption before dropping.');
      return;
    }
    if (_visibility == 'custom' && _allowedUsers.isEmpty) {
      setState(() => _error =
          'Add at least one person to see this, or choose Public/Private instead.');
      return;
    }
    setState(() { _saving = true; _error = null; });

    UploadProgressToast? toast;
    try {
      final mediaItems = <Map<String, dynamic>>[];

      if (_mediaList.isNotEmpty) {
        toast = UploadProgressToast(context);
        toast.show(
          fileName: _mediaList.first.fileName,
          fileCount: _mediaList.length,
        );

        for (var i = 0; i < _mediaList.length; i++) {
          final item = _mediaList[i];
          Uint8List bytes;
          String extension = item.extension;
          String? thumbUrl;

          if (item.mediaType == 'photo') {
            toast?.update(
              fileName: 'Compressing ${item.fileName}…',
              fileIndex: i + 1,
              fileCount: _mediaList.length,
              progress: 0,
            );
            final original = await item.file.readAsBytes();
            bytes = await _compressPhoto(original);
            extension = 'jpg';
          } else if (item.mediaType == 'video') {
            toast?.update(
              fileName: 'Compressing ${item.fileName}…',
              fileIndex: i + 1,
              fileCount: _mediaList.length,
              progress: 0,
            );
            final result = await _compressVideo(item.file);
            bytes = result.bytes;
            if (result.extension != null) extension = result.extension!;
            if (result.thumbBytes != null) {
              thumbUrl = await SupabaseService.instance.uploadDropMedia(
                bytes: result.thumbBytes!,
                mediaType: 'photo',
                extension: 'jpg',
              );
            }
          } else {
            bytes = await item.file.readAsBytes();
          }

          final url = await SupabaseService.instance.uploadDropMedia(
            bytes: bytes,
            mediaType: item.mediaType,
            extension: extension,
            onProgress: (p) => toast?.update(
              fileName: item.fileName,
              fileIndex: i + 1,
              fileCount: _mediaList.length,
              progress: p,
            ),
          );
          mediaItems.add({
            'url': url,
            'type': item.mediaType,
            'size_bytes': bytes.length,
            'name': item.fileName,
            if (thumbUrl != null) 'thumb_url': thumbUrl,
          });
        }

        await toast.finish();
      }

      final primary = mediaItems.isNotEmpty ? mediaItems.first : null;

      String? musicUrl;
      final clip = _musicClip;
      if (clip != null) {
        final bytes = await clip.file.readAsBytes();
        // The crop service only ever produces mp3/wav clips (or leaves
        // the original file untouched if it was already short) — the
        // extension on disk already reflects which.
        final extension =
            clip.file.path.split('.').last.toLowerCase();
        musicUrl = await SupabaseService.instance.uploadDropMedia(
          bytes: bytes,
          mediaType: 'audio',
          extension: extension.isEmpty ? 'mp3' : extension,
        );
      }

      await SupabaseService.instance.createDrop(
        lat: widget.lat,
        lng: widget.lng,
        caption: _captionCtrl.text.trim(),
        mediaUrl: primary?['url'] as String?,
        mediaType: primary?['type'] as String?,
        mediaSizeBytes: primary?['size_bytes'] as int?,
        allowDownload: _allowDownload,
        mediaItems: mediaItems,
        musicUrl: musicUrl,
        musicTitle: clip?.displayTitle,
        musicArtist: clip?.displayArtist,
        musicDurationMs: clip?.duration.inMilliseconds,
        unlockRadiusM: _radius,
        visibility: _visibility,
      );

      // Grant access to allowlist users
      if (_visibility == 'custom' && _allowedUsers.isNotEmpty) {
        final dropId = await SupabaseService.instance
            .fetchLatestDropId(SupabaseService.instance.currentUser!.id);
        if (dropId != null) {
          for (final username in _allowedUsers) {
            await SupabaseService.instance.grantDropAccess(
              dropId: dropId,
              username: username,
            );
          }
        }
      }

      DropEvents.instance.notifyDropCreated();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      await toast?.fail(e.toString());
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          backgroundColor: RMColors.background,
          appBar: AppBar(
            title: Text('Leave a Drop'),
            backgroundColor: RMColors.background,
          ),
          body: FadeTransition(
            opacity: _enterFade,
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Media picker row
                  Row(
                    children: [
                      _MediaPicker(
                        icon: Icons.photo_camera_rounded,
                        label: 'Photo',
                        selected: _mediaList.any((m) => m.mediaType == 'photo'),
                        onTap: _pickPhotos,
                        onCameraTap: _capturePhoto,
                      ),
                      SizedBox(width: 10),
                      _MediaPicker(
                        icon: Icons.videocam_rounded,
                        label: 'Video',
                        selected: _mediaList.any((m) => m.mediaType == 'video'),
                        onTap: _pickVideos,
                      ),
                      SizedBox(width: 10),
                      _MediaPicker(
                        icon: Icons.music_note_rounded,
                        label: 'Music',
                        selected: _musicClip != null,
                        onTap: _pickMusic,
                      ),
                    ],
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Tap to pick multiple. Long-press Photo to use the camera. Videos and music up to 30s.',
                    style: TextStyle(color: RMColors.textHint, fontSize: 11),
                  ),
                  SizedBox(height: 14),
                  if (_musicClip != null) ...[
                    _AttachedMusicChip(
                      clip: _musicClip!,
                      onEdit: _pickMusic,
                      onRemove: () => setState(() => _musicClip = null),
                    ),
                    SizedBox(height: 14),
                  ],

                  // Media preview list
                  AnimatedSwitcher(
                    duration: Duration(milliseconds: 250),
                    child: _mediaList.isEmpty
                        ? SizedBox.shrink()
                        : _buildMediaPreviewList(),
                  ),
                  if (_mediaList.isNotEmpty) SizedBox(height: 14),

                  // Caption
                  TextField(
                    controller: _captionCtrl,
                    maxLength: 500,
                    maxLines: 4,
                    style: TextStyle(color: RMColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: 'What do you want to leave here?',
                      counterStyle: TextStyle(color: RMColors.textHint),
                      suffixIcon: Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: EmojiSheetButton(
                          controller: _captionCtrl,
                          color: RMColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: 16),

                  // Unlock radius — only meaningful for private/custom
                  // drops. A public drop is visible to everyone the
                  // moment it's posted, no proximity required, so
                  // there's nothing here to configure for it (see
                  // v22-migration.sql).
                  if (_visibility != 'public') ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Unlock radius',
                            style: TextStyle(
                                color: RMColors.textSecondary, fontSize: 13)),
                        Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: RMColors.primaryDim,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${_radius}m',
                            style: TextStyle(
                                color: RMColors.primary,
                                fontWeight: FontWeight.w700,
                                fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: RMColors.primary,
                        inactiveTrackColor: RMColors.border,
                        thumbColor: RMColors.primary,
                        overlayColor: RMColors.primary.withOpacity(0.1),
                      ),
                      child: Slider(
                        value: _radius.toDouble(),
                        min: 10,
                        max: 200,
                        divisions: 19,
                        onChanged: (v) => setState(() => _radius = v.round()),
                      ),
                    ),
                    SizedBox(height: 16),
                  ],

                  // Visibility
                  Text('Who can see this?',
                      style: TextStyle(
                          color: RMColors.textSecondary, fontSize: 13)),
                  SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _VisibilityChip(
                        label: 'Public',
                        icon: Icons.public_rounded,
                        selected: _visibility == 'public',
                        onTap: () => setState(() {
                          _visibility = 'public';
                          _allowedUsers.clear();
                        }),
                      ),
                      _VisibilityChip(
                        label: 'Private',
                        icon: Icons.lock_rounded,
                        selected: _visibility == 'private',
                        onTap: () => setState(() {
                          _visibility = 'private';
                          _allowedUsers.clear();
                        }),
                      ),
                      _VisibilityChip(
                        label: 'Specific people',
                        icon: Icons.group_rounded,
                        selected: _visibility == 'custom',
                        onTap: () => setState(() => _visibility = 'custom'),
                      ),
                    ],
                  ),
                  if (_visibility == 'private') ...[
                    SizedBox(height: 8),
                    Text(
                      'Only you will be able to see and unlock this.',
                      style: TextStyle(color: RMColors.textHint, fontSize: 12),
                    ),
                  ],

                  // Allow download
                  if (_mediaList.isNotEmpty) ...[
                    SizedBox(height: 20),
                    _DownloadToggle(
                      value: _allowDownload,
                      onChanged: (v) => setState(() => _allowDownload = v),
                    ),
                  ],

                  // Allowlist
                  if (_visibility == 'custom') ...[
                    SizedBox(height: 20),
                    Text('Who can unlock this?',
                        style: TextStyle(
                            color: RMColors.textSecondary, fontSize: 13)),
                    SizedBox(height: 10),
                    if (_allowedUsers.isNotEmpty)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _allowedUsers
                            .map((u) => Chip(
                                  label: Text('@$u'),
                                  onDeleted: () => setState(
                                      () => _allowedUsers.remove(u)),
                                  deleteIconColor: RMColors.textSecondary,
                                ))
                            .toList(),
                      ),
                    SizedBox(height: 10),
                    TextField(
                      controller: _userSearchCtrl,
                      style: TextStyle(color: RMColors.textPrimary),
                      decoration: InputDecoration(
                        labelText: 'Search by username',
                        suffixIcon: _searchingUsers
                            ? Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: RMColors.primary),
                                ),
                              )
                            : null,
                      ),
                      onChanged: _searchUsers,
                    ),
                    if (_userSuggestions.isNotEmpty)
                      Container(
                        margin: EdgeInsets.only(top: 4),
                        decoration: BoxDecoration(
                          color: RMColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: RMColors.border),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          physics: NeverScrollableScrollPhysics(),
                          itemCount: _userSuggestions.length,
                          separatorBuilder: (_, __) => Divider(
                              height: 1, color: RMColors.border),
                          itemBuilder: (context, i) {
                            final u = _userSuggestions[i];
                            return ListTile(
                              dense: true,
                              leading: PresenceAvatar(
                                radius: 16,
                                backgroundColor: RMColors.primaryDim,
                                avatarUrl: u['avatar_url'] as String?,
                                lastActiveAt: DateTime.tryParse(
                                    u['last_active_at'] as String? ?? ''),
                                placeholder: Icon(Icons.person_rounded,
                                    size: 16, color: RMColors.primary),
                              ),
                              title: Text('@${u['username']}',
                                  style: TextStyle(
                                      color: RMColors.textPrimary,
                                      fontSize: 14)),
                              subtitle: Text(u['display_name'] ?? '',
                                  style: TextStyle(
                                      color: RMColors.textSecondary,
                                      fontSize: 12)),
                              onTap: () =>
                                  _addUser(u['username'] as String),
                            );
                          },
                        ),
                      ),
                  ],

                  SizedBox(height: 24),
                  if (_error != null)
                    Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(_error!,
                          style: TextStyle(
                              color: RMColors.danger, fontSize: 13)),
                    ),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text('Drop it here'),
                  ),
                ],
              ),
            ),
          ),
        ),

        if (_showTutorial)
          TutorialOverlay(
            steps: [
              TutorialStep(
                icon: Icons.add_location_alt_rounded,
                title: 'Create a Drop',
                body: 'You\'re pinning content to your exact GPS location. Anyone who walks here can discover it.',
              ),
              TutorialStep(
                icon: Icons.perm_media_rounded,
                title: 'Add any media',
                body: 'Attach a photo or a short video (up to 30 seconds). The content stays hidden until someone physically unlocks it.',
              ),
              TutorialStep(
                icon: Icons.lock_rounded,
                title: 'Set visibility',
                body: 'Public drops are discoverable by everyone. Private keeps it just for you, or share it with specific people you pick by username.',
              ),
            ],
            onDone: () async {
              await OnboardingService.instance.markDropTutorialSeen();
              if (mounted) setState(() => _showTutorial = false);
            },
          ),
      ],
    );
  }

  Widget _buildMediaPreviewList() {
    return Column(
      key: ValueKey('media-list'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _mediaList.length; i++) ...[
          if (i > 0) SizedBox(height: 8),
          _MediaPreviewTile(
            media: _mediaList[i],
            onRemove: () => _removeMedia(i),
          ),
        ],
      ],
    );
  }
}

class _MediaPreviewTile extends StatelessWidget {
  final _PickedMedia media;
  final VoidCallback onRemove;

  _MediaPreviewTile({required this.media, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final sizeLabel = formatFileSize(media.sizeBytes);
    if (media.mediaType == 'photo') {
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: RMColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Image.file(media.file, height: 140, width: double.infinity, fit: BoxFit.cover),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: _PreviewCaptionBar(
                fileName: media.fileName,
                sizeLabel: sizeLabel,
                onRemove: onRemove,
                dark: true,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: RMColors.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RMColors.border),
      ),
      padding: EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(
            media.mediaType == 'video'
                ? Icons.videocam_rounded
                : Icons.insert_drive_file_rounded,
            color: RMColors.primary,
            size: 24,
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  media.fileName,
                  style: TextStyle(
                      color: RMColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
                if (sizeLabel != null)
                  Text(sizeLabel,
                      style: TextStyle(
                          color: RMColors.textSecondary, fontSize: 11)),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close_rounded,
                color: RMColors.textSecondary, size: 18),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _PreviewCaptionBar extends StatelessWidget {
  final String fileName;
  final String? sizeLabel;
  final VoidCallback onRemove;
  final bool dark;

  _PreviewCaptionBar({
    required this.fileName,
    required this.sizeLabel,
    required this.onRemove,
    this.dark = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fileName,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (sizeLabel != null)
                  Text(sizeLabel!,
                      style: TextStyle(
                          color: Colors.white70, fontSize: 10)),
              ],
            ),
          ),
          GestureDetector(
            onTap: onRemove,
            child: Icon(Icons.close_rounded, color: Colors.white, size: 16),
          ),
        ],
      ),
    );
  }
}

class _DownloadToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  _DownloadToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: RMColors.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RMColors.border),
      ),
      child: Row(
        children: [
          Icon(
            value ? Icons.download_rounded : Icons.download_for_offline_outlined,
            size: 18,
            color: value ? RMColors.primary : RMColors.textSecondary,
          ),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Allow downloads',
                    style: TextStyle(
                        color: RMColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                Text('Let people save the attached files to their device',
                    style: TextStyle(
                        color: RMColors.textSecondary, fontSize: 11)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: RMColors.primary,
          ),
        ],
      ),
    );
  }
}

class _MediaPicker extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onCameraTap;

  _MediaPicker({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.onCameraTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onCameraTap,
        child: AnimatedContainer(
          duration: Duration(milliseconds: 200),
          padding: EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: selected ? RMColors.primaryDim : RMColors.surfaceAlt,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? RMColors.primary : RMColors.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            children: [
              Icon(icon,
                  color: selected ? RMColors.primary : RMColors.textHint,
                  size: 22),
              SizedBox(height: 5),
              Text(label,
                  style: TextStyle(
                      color: selected
                          ? RMColors.primary
                          : RMColors.textHint,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows the currently-attached (already-cropped) track, in place of a
/// raw filename — once AudD identifies a clip, its title/artist takes
/// over here (with a small sparkle badge) instead of the device's own
/// (often missing or wrong) file tag.
class _AttachedMusicChip extends StatelessWidget {
  final CroppedMusicClip clip;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  const _AttachedMusicChip({
    required this.clip,
    required this.onEdit,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: RMColors.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RMColors.border),
      ),
      child: Row(
        children: [
          Icon(Icons.music_note_rounded, size: 18, color: RMColors.primary),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              clip.displayLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: RMColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600),
            ),
          ),
          if (clip.isIdentified) ...[
            SizedBox(width: 6),
            Icon(Icons.auto_awesome_rounded, size: 14, color: RMColors.primary),
            SizedBox(width: 8),
          ],
          GestureDetector(
            onTap: onEdit,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.content_cut_rounded, size: 18, color: RMColors.textHint),
            ),
          ),
          GestureDetector(
            onTap: onRemove,
            child: Icon(Icons.close_rounded, size: 18, color: RMColors.textHint),
          ),
        ],
      ),
    );
  }
}

class _VisibilityChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  _VisibilityChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? RMColors.primaryDim : RMColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? RMColors.primary : RMColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 16,
                color:
                    selected ? RMColors.primary : RMColors.textSecondary),
            SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    color: selected
                        ? RMColors.primary
                        : RMColors.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
