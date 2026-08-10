import 'dart:typed_data';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';

/// A single track from the device's local music library, trimmed down
/// to what the "attach music" picker actually needs. Kept separate
/// from [SongModel] so the rest of the app (picker UI, the eventual
/// crop step, the drop/status upload payload) doesn't have to depend
/// directly on the on_audio_query package.
class LibraryTrack {
  final int id;
  final String title;
  final String? artist;
  final String? album;
  final Duration duration;
  final String filePath;
  LibraryTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.filePath,
  });

  /// "Song — Artist" if an artist tag is present, else just the title —
  /// this is what replaces the raw filename in the drop/status card
  /// once a track is attached, ahead of the AI-detected label taking
  /// over for tracks pulled in some other way.
  String get displayLabel =>
      (artist != null && artist!.trim().isNotEmpty && artist != '<unknown>')
          ? '$title — $artist'
          : title;

  factory LibraryTrack.fromSong(SongModel song) => LibraryTrack(
        id: song.id,
        title: song.title,
        artist: song.artist,
        album: song.album,
        duration: Duration(milliseconds: song.duration ?? 0),
        filePath: song.data,
      );
}

/// Reads the on-device music library (MediaStore on Android) for the
/// "Add Music" picker on status/drop uploads. Read-only — this never
/// writes to the library, only lists and searches what's already there.
class MusicLibraryService {
  MusicLibraryService._();
  static final instance = MusicLibraryService._();

  final OnAudioQuery _query = OnAudioQuery();
  List<LibraryTrack>? _cache;

  /// Requests the runtime permission needed to enumerate audio files
  /// (READ_MEDIA_AUDIO on Android 13+, READ_EXTERNAL_STORAGE below
  /// that — the plugin/permission_handler resolve which one applies).
  /// Returns false if the person denies it, so the picker can show a
  /// clear "no access" state instead of a silently empty list.
  Future<bool> requestPermission() async {
    final status = await Permission.audio.status;
    if (status.isGranted) return true;
    final result = await Permission.audio.request();
    return result.isGranted;
  }

  Future<bool> hasPermission() async => (await Permission.audio.status).isGranted;

  /// All songs on the device, longest-untouched cache first — callers
  /// that just want to filter locally (the search box) can reuse this
  /// instead of re-querying MediaStore on every keystroke. Pass
  /// [forceRefresh] to bypass the cache (e.g. a pull-to-refresh).
  Future<List<LibraryTrack>> fetchAllTracks({bool forceRefresh = false}) async {
    if (_cache != null && !forceRefresh) return _cache!;
    final songs = await _query.querySongs(
      sortType: SongSortType.TITLE,
      orderType: OrderType.ASC_OR_SMALLER,
      uriType: UriType.EXTERNAL,
      ignoreCase: true,
    );
    // Skip anything under 3 seconds — these are almost always ringtone
    // fragments or voice-memo scraps MediaStore picks up, not songs
    // anyone would attach to a status.
    final tracks = songs
        .where((s) => (s.duration ?? 0) >= 3000)
        .map(LibraryTrack.fromSong)
        .toList();
    _cache = tracks;
    return tracks;
  }

  /// Client-side filter over the cached library by title/artist/album —
  /// the library sizes this deals with (hundreds, occasionally low
  /// thousands of tracks) make a full MediaStore round-trip per
  /// keystroke unnecessary.
  Future<List<LibraryTrack>> search(String query) async {
    final all = await fetchAllTracks();
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((t) {
      return t.title.toLowerCase().contains(q) ||
          (t.artist?.toLowerCase().contains(q) ?? false) ||
          (t.album?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  /// Embedded album artwork for a track, or null if it has none / it
  /// can't be read. Queried lazily per-row by the picker UI.
  Future<Uint8List?> artworkFor(int id) => _query.queryArtwork(
        id,
        ArtworkType.AUDIO,
        format: ArtworkFormat.JPEG,
        size: 200,
      );

  void clearCache() => _cache = null;
}
