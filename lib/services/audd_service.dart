import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import '../config/env_config.dart';
import 'package:http/http.dart' as http;

/// A song match returned by AudD — just the two fields the rest of the
/// app ever shows (see [CroppedMusicClip.displayLabel] / [Drop.musicLabel]).
class AuddMatch {
  final String title;
  final String? artist;
  const AuddMatch({required this.title, this.artist});
}

/// Identifies a song from a short audio clip via AudD.io's audio
/// fingerprinting API — used to fill in title/artist for a clip picked
/// from the phone's local library, since on-device tags are often
/// missing, wrong, or just "Track 04".
///
/// Entirely opt-in, same pattern as [GeneratedImageService]: without an
/// AUDD_API_KEY in .env, [identify] returns null immediately and the
/// composer falls back to whatever tag the library already had — this
/// never blocks attaching music, it only makes the label better when
/// it's available.
class AuddService {
  AuddService._();
  static final AuddService instance = AuddService._();

  static const _endpoint = 'https://api.audd.io/';

  final _client = http.Client();

  bool get isEnabled {
    final key = EnvConfig.auddApiKey;
    return key.trim().isNotEmpty;
  }

  /// Uploads [clipFile] — the already-trimmed clip is plenty for a
  /// fingerprint match and keeps the request small/fast — and returns
  /// the matched title/artist, or null if there's no key configured,
  /// the request fails/times out, or AudD simply doesn't recognize the
  /// clip. Never throws.
  Future<AuddMatch?> identify(File clipFile) async {
    // A key pasted into a GitHub secret (or a local .env) sometimes
    // picks up a trailing newline or space — trim it the same way
    // GeneratedImageService does for OPENAI_API_KEY, so that doesn't
    // turn into a silent 401 that looks identical to "no key set".
    final rawKey = EnvConfig.auddApiKey;
    if (rawKey.trim().isEmpty) return null;
    final key = rawKey.trim();

    try {
      final request = http.MultipartRequest('POST', Uri.parse(_endpoint))
        ..fields['api_token'] = key
        ..files.add(await http.MultipartFile.fromPath('file', clipFile.path));

      final streamed = await _client.send(request).timeout(
            const Duration(seconds: 12),
            onTimeout: () => throw TimeoutException('AudD request timed out'),
          );
      final body = await streamed.stream.bytesToString();

      if (streamed.statusCode != 200) {
        debugPrint('[AuddService] HTTP ${streamed.statusCode}: $body');
        return null;
      }

      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['status'] != 'success') {
        debugPrint('[AuddService] API error: ${json['error']}');
        return null;
      }

      final result = json['result'];
      if (result is! Map<String, dynamic>) return null; // no match found

      final title = (result['title'] as String?)?.trim();
      if (title == null || title.isEmpty) return null;
      final artist = (result['artist'] as String?)?.trim();

      return AuddMatch(title: title, artist: (artist?.isEmpty ?? true) ? null : artist);
    } catch (e) {
      debugPrint('[AuddService] Unexpected error identifying clip: $e');
      return null;
    }
  }
}
