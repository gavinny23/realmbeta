import 'dart:convert';
import 'dart:io';

/// Lossless compression for the JSON blobs [LocalCacheService] and
/// [AppStorageService] persist to `SharedPreferences`.
///
/// `SharedPreferences` only stores strings, so a big cached feed or
/// chat history sits on disk as raw, uncompressed JSON today — plenty
/// of repeated keys ("caption", "media_url", "creator_id", …) that
/// gzip handles well. This wraps that JSON in gzip + base64 before
/// it's written, and reverses it on read, so every cached list/map
/// takes meaningfully less space on the device with **no** change to
/// the actual data — it decompresses back to byte-for-byte the same
/// JSON that went in.
///
/// Entries written before this existed were stored as plain JSON with
/// no marker prefix; [decompressJson] recognizes the `gz1:` prefix
/// this class writes and falls back to parsing plain JSON directly
/// for anything older, so upgrading the app doesn't throw away
/// whatever was already cached on a person's device.
class CompressionService {
  CompressionService._();

  static const _magic = 'gz1:';

  /// Encodes [value] (anything `jsonEncode` accepts — a `List`, a
  /// `Map`, …) to JSON, gzips it, and returns a `gz1:`-prefixed,
  /// base64 string ready to hand straight to
  /// `SharedPreferences.setString`.
  static String compressJson(dynamic value) {
    final rawBytes = utf8.encode(jsonEncode(value));
    final gzipped = gzip.encode(rawBytes);
    return '$_magic${base64.encode(gzipped)}';
  }

  /// Reverses [compressJson]. Also transparently reads plain
  /// (pre-compression) JSON strings that don't carry the `gz1:`
  /// marker, so older cached entries keep working after an upgrade.
  static dynamic decompressJson(String stored) {
    if (stored.startsWith(_magic)) {
      final gzipped = base64.decode(stored.substring(_magic.length));
      final rawBytes = gzip.decode(gzipped);
      return jsonDecode(utf8.decode(rawBytes));
    }
    return jsonDecode(stored);
  }
}
