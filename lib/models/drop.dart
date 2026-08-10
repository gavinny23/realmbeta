enum DropVisibility { public, private, custom }
enum DropMediaType { photo, video, document }

DropMediaType? parseDropMediaType(String? raw) {
  switch (raw) {
    case 'photo': return DropMediaType.photo;
    case 'video': return DropMediaType.video;
    case 'document': return DropMediaType.document;
    default: return null;
  }
}

/// A single attachment on a drop. A drop can carry more than one file
/// (e.g. a couple of photos plus a document) — [Drop.mediaItems] holds
/// the full list, while [Drop.mediaUrl]/[Drop.mediaType]/[Drop.mediaSizeBytes]
/// mirror the first item for anything that only cares about "the" media.
class DropMediaItem {
  final String url;
  final DropMediaType type;
  final int? sizeBytes;
  final String? name;
  /// For videos only: a small pre-generated JPEG frame, uploaded
  /// alongside the video, so feed/grid views can show a lightweight
  /// static image instead of spinning up a real video player per card.
  final String? thumbUrl;

  DropMediaItem({
    required this.url,
    required this.type,
    this.sizeBytes,
    this.name,
    this.thumbUrl,
  });

  factory DropMediaItem.fromMap(Map<String, dynamic> map) {
    return DropMediaItem(
      url: map['url'] as String,
      type: parseDropMediaType(map['type'] as String?) ?? DropMediaType.photo,
      sizeBytes: (map['size_bytes'] as num?)?.toInt(),
      name: map['name'] as String?,
      thumbUrl: map['thumb_url'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
        'url': url,
        'type': switch (type) {
          DropMediaType.photo => 'photo',
          DropMediaType.video => 'video',
          DropMediaType.document => 'document',
        },
        'size_bytes': sizeBytes,
        'name': name,
        'thumb_url': thumbUrl,
      };

  /// Human-readable size, e.g. "1.4 MB". Returns null if unknown.
  String? get sizeLabel => formatFileSize(sizeBytes);
}

/// Formats a byte count as a short human-readable label ("482 KB",
/// "3.1 MB"). Returns null for an unknown/zero-or-negative size.
String? formatFileSize(int? bytes) {
  if (bytes == null || bytes <= 0) return null;
  const units = ['B', 'KB', 'MB', 'GB'];
  double size = bytes.toDouble();
  var unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex++;
  }
  final decimals = unitIndex == 0 ? 0 : 1;
  return '${size.toStringAsFixed(decimals)} ${units[unitIndex]}';
}

class Drop {
  final String id;
  final String creatorId;
  final String creatorUsername;
  final String? caption;
  final String? mediaUrl;
  final DropMediaType? mediaType;
  final int? mediaSizeBytes;
  final bool allowDownload;
  final List<DropMediaItem> mediaItems;
  final String? musicUrl;
  final String? musicTitle;
  final String? musicArtist;
  final int? musicDurationMs;
  final DropVisibility visibility;
  final int unlockRadiusM;
  final double distanceM;
  final double? dropLat;
  final double? dropLng;
  final bool isUnlocked;
  final DateTime createdAt;

  Drop({
    required this.id,
    required this.creatorId,
    required this.creatorUsername,
    required this.caption,
    required this.mediaUrl,
    required this.mediaType,
    this.mediaSizeBytes,
    this.allowDownload = true,
    this.mediaItems = const [],
    this.musicUrl,
    this.musicTitle,
    this.musicArtist,
    this.musicDurationMs,
    required this.visibility,
    required this.unlockRadiusM,
    required this.distanceM,
    this.dropLat,
    this.dropLng,
    required this.isUnlocked,
    required this.createdAt,
  });

  factory Drop.fromMap(Map<String, dynamic> map) {
    final rawItems = map['media_items'];
    final items = <DropMediaItem>[];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is Map<String, dynamic>) {
          items.add(DropMediaItem.fromMap(raw));
        } else if (raw is Map) {
          items.add(DropMediaItem.fromMap(Map<String, dynamic>.from(raw)));
        }
      }
    }

    return Drop(
      id: map['id'] as String,
      creatorId: map['creator_id'] as String,
      creatorUsername: map['creator_username'] as String? ?? 'unknown',
      caption: map['caption'] as String?,
      mediaUrl: map['media_url'] as String?,
      mediaType: parseDropMediaType(map['media_type'] as String?),
      mediaSizeBytes: (map['media_size_bytes'] as num?)?.toInt(),
      allowDownload: map['allow_download'] as bool? ?? true,
      mediaItems: items,
      musicUrl: map['music_url'] as String?,
      musicTitle: map['music_title'] as String?,
      musicArtist: map['music_artist'] as String?,
      musicDurationMs: (map['music_duration_ms'] as num?)?.toInt(),
      visibility: switch (map['visibility'] as String?) {
        'private' => DropVisibility.private,
        'custom' => DropVisibility.custom,
        _ => DropVisibility.public,
      },
      unlockRadiusM: (map['unlock_radius_m'] as num).toInt(),
      distanceM: (map['distance_m'] as num).toDouble(),
      dropLat: (map['drop_lat'] as num?)?.toDouble(),
      dropLng: (map['drop_lng'] as num?)?.toDouble(),
      isUnlocked: map['is_unlocked'] as bool,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  String get distanceLabel {
    if (distanceM < 1000) return '${distanceM.round()}m away';
    return '${(distanceM / 1000).toStringAsFixed(1)}km away';
  }

  bool get isWithinUnlockRange => distanceM <= unlockRadiusM;
  /// True when this drop has a playable music clip attached.
  bool get hasMusic => musicUrl != null && musicUrl!.isNotEmpty;
  /// "Song — Artist" for the attached clip, or just the title if no
  /// artist tag was available. Null when there's no music.
  String? get musicLabel {
    if (!hasMusic) return null;
    final title = musicTitle ?? 'Unknown track';
    return (musicArtist != null && musicArtist!.isNotEmpty)
        ? '$title — $musicArtist'
        : title;
  }
  /// True only for "just me" private drops.
  bool get isPrivate => visibility == DropVisibility.private;
  /// True only for drops shared with a hand-picked list of people.
  bool get isCustom => visibility == DropVisibility.custom;
  /// True for anything that isn't fully public — used to decide whether
  /// to show a restricted-access badge.
  bool get isRestricted => visibility != DropVisibility.public;
  String get visibilityLabel => switch (visibility) {
        DropVisibility.private => 'PRIVATE',
        DropVisibility.custom => 'SPECIFIC PEOPLE',
        DropVisibility.public => 'PUBLIC',
      };

  /// Mirrors [Drop.fromMap]'s field names so a cached drop can be
  /// written to disk (see LocalCacheService) and read back later with
  /// no special-casing.
  Map<String, dynamic> toMap() => {
        'id': id,
        'creator_id': creatorId,
        'creator_username': creatorUsername,
        'caption': caption,
        'media_url': mediaUrl,
        'media_type': switch (mediaType) {
          DropMediaType.photo => 'photo',
          DropMediaType.video => 'video',
          DropMediaType.document => 'document',
          null => null,
        },
        'media_size_bytes': mediaSizeBytes,
        'allow_download': allowDownload,
        'media_items': mediaItems.map((m) => m.toMap()).toList(),
        'music_url': musicUrl,
        'music_title': musicTitle,
        'music_artist': musicArtist,
        'music_duration_ms': musicDurationMs,
        'visibility': switch (visibility) {
          DropVisibility.private => 'private',
          DropVisibility.custom => 'custom',
          DropVisibility.public => 'public',
        },
        'unlock_radius_m': unlockRadiusM,
        'distance_m': distanceM,
        'drop_lat': dropLat,
        'drop_lng': dropLng,
        'is_unlocked': isUnlocked,
        'created_at': createdAt.toIso8601String(),
      };

  /// Total size across every attachment, or null if none are known.
  int? get totalSizeBytes {
    if (mediaItems.isEmpty) return mediaSizeBytes;
    final known = mediaItems.where((m) => m.sizeBytes != null);
    if (known.isEmpty) return mediaSizeBytes;
    return known.fold<int>(0, (sum, m) => sum + m.sizeBytes!);
  }

  String? get totalSizeLabel => formatFileSize(totalSizeBytes);
}
