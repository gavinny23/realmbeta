import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../config/env_config.dart';
import 'package:http/http.dart' as http;
import '../models/news_article.dart';

/// Last-resort visual for Updates-tab stories that have no image
/// anywhere — not in the RSS feed, not on the publisher's own page
/// (see [ArticleImageService]). Generates a purely decorative,
/// editorial-style illustration of the story's general topic.
///
/// This is opt-in and off by default: it only runs if the person
/// building this app supplies their own OPENAI_API_KEY in .env, and
/// it's capped per session so a bad news day (lots of small stories
/// with no press photo) can't run up an unbounded bill.
///
/// Two things this deliberately does NOT try to do, because getting
/// them wrong on real news is a real harm, not a cosmetic one:
///  - Depict the specific event photorealistically. A generated
///    image that reads as a photo of something that didn't happen
///    that way is a misinformation risk, especially at a glance in a
///    scrolling feed. The prompt asks for a flat, abstract editorial
///    style specifically so it never reads as a photograph.
///  - Depict real, named people. The prompt explicitly excludes
///    rendering any specific individual's likeness — it illustrates
///    the *topic* (elections, sports, markets, weather...), not the
///    people in the story.
/// On top of the prompt, [shouldGenerate] skips generation entirely
/// for stories that read as covering death, violence, disaster, or
/// other tragedy — an illustration for those is more likely to feel
/// tone-deaf or misleading than helpful, so those cards simply show
/// no image, same as before this feature existed.
class GeneratedImageService {
  GeneratedImageService._();
  static final GeneratedImageService instance = GeneratedImageService._();

  /// Hard cap on how many images this will generate in one app
  /// session, independent of how many uncovered stories are in the
  /// feed. Keeps a slow news day from silently generating dozens of
  /// images on someone's API key.
  static const int _maxPerSession = 25;

  static const _sensitiveKeywords = [
    'dead', 'death', 'died', 'dies', 'killed', 'kills', 'killing',
    'murder', 'homicide', 'massacre', 'genocide',
    'terror', 'terrorist', 'bombing', 'bomb blast', 'explosion',
    'war', 'airstrike', 'invasion', 'conflict', 'militants',
    'rape', 'sexual assault', 'molest',
    'suicide', 'self-harm',
    'shooting', 'gunman', 'gunmen', 'shot dead',
    'crash', 'collision', 'derail', 'plane crash',
    'disaster', 'earthquake', 'flood', 'famine', 'drought',
    'riot', 'unrest', 'violence', 'clashes',
    'abuse', 'kidnap', 'hostage', 'coup', 'accident',
  ];

  final _client = http.Client();
  final Map<String, Uint8List?> _cache = {};
  final Map<String, Future<Uint8List?>> _inFlight = {};
  int _generatedThisSession = 0;

  bool get isEnabled {
    final key = EnvConfig.openaiApiKey;
    return key.trim().isNotEmpty;
  }

  /// Best-effort topic check over the title/summary/category — errs
  /// toward skipping generation when unsure, since "no image" is
  /// always a safe fallback and a wrong illustration isn't.
  bool shouldGenerate(NewsArticle article) {
    if (!isEnabled) return false;
    if (_generatedThisSession >= _maxPerSession) return false;
    final haystack =
        '${article.title} ${article.summary ?? ''} ${article.category ?? ''}'
            .toLowerCase();
    return !_sensitiveKeywords.any(haystack.contains);
  }

  Future<Uint8List?> generate(NewsArticle article) {
    if (_cache.containsKey(article.id)) {
      return Future.value(_cache[article.id]);
    }
    final existing = _inFlight[article.id];
    if (existing != null) return existing;

    final future = _requestImage(article).then((bytes) {
      _cache[article.id] = bytes;
      _inFlight.remove(article.id);
      if (bytes != null) _generatedThisSession++;
      return bytes;
    }).catchError((e) {
      debugPrint('[GeneratedImageService] Unexpected error generating '
          'image for "${article.title}": $e');
      _cache[article.id] = null;
      _inFlight.remove(article.id);
      return null;
    });
    _inFlight[article.id] = future;
    return future;
  }

  Future<Uint8List?> _requestImage(NewsArticle article) async {
    final rawKey = EnvConfig.openaiApiKey;
    if (rawKey.trim().isEmpty) return null;
    // A key pasted into a GitHub secret (or a local .env) sometimes
    // picks up a trailing newline or space, which turns into an
    // invisible-but-invalid Authorization header and a 401 that looks
    // identical to "no key configured" from the outside. Trimming
    // here means that class of mistake fails loudly in the log below
    // instead of just silently producing no image.
    final apiKey = rawKey.trim();

    final prompt = _buildPrompt(article);

    late final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('https://api.openai.com/v1/images/generations'),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': 'gpt-image-1',
              'prompt': prompt,
              'size': '1536x1024',
              'quality': 'low',
              'n': 1,
            }),
          )
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      debugPrint('[GeneratedImageService] Request failed for '
          '"${article.title}": $e');
      return null;
    }

    if (response.statusCode != 200) {
      // Swallowing this without a trace is exactly what made a bad
      // key/model-access/rate-limit problem indistinguishable from
      // "feature just isn't generating images" — log enough of the
      // body to tell those apart. OpenAI's most common non-200s here:
      //  - 401: key is missing/invalid/mistyped (check the GitHub
      //    secret name is exactly OPENAI_API_KEY and has no stray
      //    whitespace — see the trim above).
      //  - 403: key is valid but this org hasn't completed the
      //    identity verification OpenAI requires for gpt-image-1
      //    access — this is a project-dashboard step, not a code fix.
      //  - 429: rate limited or out of quota/billing.
      final snippet = response.body.length > 400
          ? '${response.body.substring(0, 400)}…'
          : response.body;
      debugPrint('[GeneratedImageService] OpenAI returned '
          '${response.statusCode} for "${article.title}": $snippet');
      return null;
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final data = decoded['data'] as List?;
    if (data == null || data.isEmpty) {
      debugPrint('[GeneratedImageService] 200 response had no image data '
          'for "${article.title}": ${response.body}');
      return null;
    }

    final first = data.first as Map<String, dynamic>;
    final b64 = first['b64_json'] as String?;
    if (b64 == null || b64.isEmpty) {
      debugPrint('[GeneratedImageService] Response image entry had no '
          'b64_json for "${article.title}"');
      return null;
    }

    return base64Decode(b64);
  }

  /// Builds a prompt aimed squarely at a flat, non-photographic
  /// editorial illustration of the story's general subject — not a
  /// recreation of the event, and not any specific person.
  String _buildPrompt(NewsArticle article) {
    final topic = article.category ?? _guessTopic(article);
    return 'Flat, minimal editorial illustration representing the general '
        'topic of a news story about: "${article.title}". '
        'Style: abstract vector-style editorial illustration, muted '
        'color palette, magazine-op-ed style — clearly a graphic '
        'illustration, not a photograph. '
        'Depict the general theme ($topic) only: no readable text, no '
        'signage, no specific real person\'s face or likeness, no '
        'identifiable individuals, no violence, no gore, no disturbing '
        'imagery. Keep it generic and non-literal.';
  }

  String _guessTopic(NewsArticle article) {
    switch (article.tier) {
      case NewsTier.kenya:
        return 'Kenyan current affairs';
      case NewsTier.africa:
        return 'African current affairs';
      case NewsTier.world:
        return 'world news';
    }
  }
}
