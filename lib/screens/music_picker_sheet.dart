import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/music_library_service.dart';
import '../theme/rm_theme.dart';

/// Grid or list layout for [MusicPickerSheet]'s track results.
/// Persisted device-wide (see [_viewModePrefsKey]) so the choice
/// sticks across sheets rather than resetting every time someone
/// opens the picker — same "remember what they last picked" contract
/// as [DataSaverService].
enum _TrackViewMode { grid, list }

const _viewModePrefsKey = 'rm_music_picker_view_mode';

/// "Add Music" bottom sheet — lists every song on the device (via
/// [MusicLibraryService]) with a live search field, and returns the
/// [LibraryTrack] the person taps.
///
/// This is deliberately just the picking step. What happens after
/// (cropping to a 30s window, running AI title/artist detection,
/// uploading) lives in the caller — this sheet's only job is "find
/// the song".
class MusicPickerSheet extends StatefulWidget {
  const MusicPickerSheet({super.key});

  /// Convenience launcher matching the `showModalBottomSheet<String>`
  /// pattern already used elsewhere in the app (e.g. the gallery
  /// picker in CreateStatusScreen).
  static Future<LibraryTrack?> show(BuildContext context) {
    return showModalBottomSheet<LibraryTrack>(
      context: context,
      isScrollControlled: true,
      backgroundColor: RMColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const MusicPickerSheet(),
    );
  }

  @override
  State<MusicPickerSheet> createState() => _MusicPickerSheetState();
}

class _MusicPickerSheetState extends State<MusicPickerSheet> {
  final _searchCtrl = TextEditingController();
  bool _loading = true;
  bool _permissionDenied = false;
  String? _error;
  List<LibraryTrack> _results = [];

  // Grid is the default the first time anyone opens this sheet; after
  // that, whichever way they last left it (see _loadViewMode/_toggleViewMode).
  _TrackViewMode _viewMode = _TrackViewMode.grid;

  @override
  void initState() {
    super.initState();
    _load();
    _loadViewMode();
  }

  Future<void> _loadViewMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_viewModePrefsKey);
      if (saved == _TrackViewMode.list.name && mounted) {
        setState(() => _viewMode = _TrackViewMode.list);
      }
    } catch (_) {
      // Prefs unavailable — just stays on the grid default.
    }
  }

  Future<void> _toggleViewMode() async {
    final next = _viewMode == _TrackViewMode.grid
        ? _TrackViewMode.list
        : _TrackViewMode.grid;
    setState(() => _viewMode = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_viewModePrefsKey, next.name);
    } catch (_) {
      // Best-effort — worst case it just defaults to grid next time.
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _permissionDenied = false;
    });
    try {
      final granted = await MusicLibraryService.instance.requestPermission();
      if (!granted) {
        if (mounted) setState(() {
          _loading = false;
          _permissionDenied = true;
        });
        return;
      }
      final tracks = await MusicLibraryService.instance.fetchAllTracks();
      if (!mounted) return;
      setState(() {
        _results = tracks;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _error = "Couldn't read your music library.";
        _loading = false;
      });
    }
  }

  Future<void> _onSearchChanged(String query) async {
    final results = await MusicLibraryService.instance.search(query);
    if (!mounted) return;
    setState(() => _results = results);
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.85;
    return SafeArea(
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: RMColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.music_note_rounded, color: RMColors.primary, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Add music',
                    style: TextStyle(
                      color: RMColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                    ),
                  ),
                  const Spacer(),
                  if (!_loading && !_permissionDenied && _error == null)
                    IconButton(
                      onPressed: _toggleViewMode,
                      tooltip: _viewMode == _TrackViewMode.grid
                          ? 'Switch to list view'
                          : 'Switch to grid view',
                      icon: Icon(
                        _viewMode == _TrackViewMode.grid
                            ? Icons.view_list_rounded
                            : Icons.grid_view_rounded,
                        color: RMColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            if (!_loading && !_permissionDenied)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: _onSearchChanged,
                  style: TextStyle(color: RMColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Search songs or artists',
                    hintStyle: TextStyle(color: RMColors.textHint),
                    prefixIcon: Icon(Icons.search, color: RMColors.textSecondary),
                    suffixIcon: _searchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: Icon(Icons.clear, color: RMColors.textSecondary),
                            onPressed: () {
                              _searchCtrl.clear();
                              _onSearchChanged('');
                            },
                          ),
                    filled: true,
                    fillColor: RMColors.surfaceAlt,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: RMColors.primary),
      );
    }
    if (_permissionDenied) {
      return _MessageState(
        icon: Icons.lock_outline,
        title: "Can't access your music",
        subtitle:
            'Realm needs permission to read your music library to attach a song.',
        actionLabel: 'Grant access',
        onAction: _load,
      );
    }
    if (_error != null) {
      return _MessageState(
        icon: Icons.error_outline,
        title: 'Something went wrong',
        subtitle: _error!,
        actionLabel: 'Retry',
        onAction: _load,
      );
    }
    if (_results.isEmpty) {
      return _MessageState(
        icon: Icons.music_off_rounded,
        title: _searchCtrl.text.isEmpty ? 'No music found' : 'No matches',
        subtitle: _searchCtrl.text.isEmpty
            ? "There's no music on this device yet."
            : 'Try a different search.',
      );
    }
    if (_viewMode == _TrackViewMode.list) {
      return ListView.builder(
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: _results.length,
        itemBuilder: (context, i) {
          final track = _results[i];
          return _TrackTile(
            track: track,
            onTap: () => Navigator.of(context).pop(track),
          );
        },
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: _results.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 14,
        crossAxisSpacing: 12,
        childAspectRatio: 0.72,
      ),
      itemBuilder: (context, i) {
        final track = _results[i];
        return _TrackGridTile(
          track: track,
          onTap: () => Navigator.of(context).pop(track),
        );
      },
    );
  }
}

class _TrackTile extends StatelessWidget {
  final LibraryTrack track;
  final VoidCallback onTap;
  const _TrackTile({required this.track, required this.onTap});

  String _durationLabel(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 44,
          height: 44,
          child: FutureBuilder<Uint8List?>(
            future: MusicLibraryService.instance.artworkFor(track.id),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.done &&
                  snapshot.data != null) {
                return Image.memory(snapshot.data!, fit: BoxFit.cover);
              }
              return Container(
                color: RMColors.surfaceAlt,
                child: Icon(Icons.music_note_rounded,
                    color: RMColors.textHint, size: 20),
              );
            },
          ),
        ),
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: RMColors.textPrimary, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        track.artist == null || track.artist!.trim().isEmpty || track.artist == '<unknown>'
            ? 'Unknown artist'
            : track.artist!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: RMColors.textSecondary, fontSize: 13),
      ),
      trailing: Text(
        _durationLabel(track.duration),
        style: TextStyle(color: RMColors.textHint, fontSize: 12),
      ),
    );
  }
}

class _TrackGridTile extends StatelessWidget {
  final LibraryTrack track;
  final VoidCallback onTap;
  const _TrackGridTile({required this.track, required this.onTap});

  String _durationLabel(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final artistLabel =
        track.artist == null || track.artist!.trim().isEmpty || track.artist == '<unknown>'
            ? 'Unknown artist'
            : track.artist!;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FutureBuilder<Uint8List?>(
                    future: MusicLibraryService.instance.artworkFor(track.id),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.done &&
                          snapshot.data != null) {
                        return Image.memory(snapshot.data!, fit: BoxFit.cover);
                      }
                      return Container(
                        color: RMColors.surfaceAlt,
                        child: Icon(Icons.music_note_rounded,
                            color: RMColors.textHint, size: 28),
                      );
                    },
                  ),
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _durationLabel(track.duration),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: RMColors.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 12.5),
          ),
          Text(
            artistLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: RMColors.textSecondary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _MessageState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _MessageState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: RMColors.textHint, size: 40),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: RMColors.textPrimary, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: RMColors.textSecondary, fontSize: 13),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
