import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Result of a fallback-image lookup: the image itself, plus an
/// honest attribution line for it.
class ArticleImageResult {
  final String imageUrl;
  final String? credit;
  const ArticleImageResult({required this.imageUrl, this.credit});
}

/// Best-effort fallback image resolver for Updates-tab stories whose
/// RSS entry didn't include a usable image.
///
/// Deliberately *not* a general "search the web for a picture of
/// this" — a generic image search can easily surface a photo of the
/// wrong person/place, or one with no verifiable source, and putting
/// a made-up-looking credit under the wrong photo is worse than no
/// image at all. Instead this fetches the actual story page (the
/// same [NewsArticle.link] the card already opens) and reads the
/// same Open Graph / Twitter Card / schema.org metadata the publisher
/// put there themselves for link previews — so the image is
/// guaranteed to be the one the story's own publisher attached to it,
/// and the credit line is either their explicit photo-credit metadata
/// or, failing that, an honest "Photo: <site>" rather than a guess.
class ArticleImageService {
  ArticleImageService._();
  static final ArticleImageService instance = ArticleImageService._();

  final _client = http.Client();

  // Session-only cache — cheap enough to re-resolve on next app
  // launch, avoids a second cache table just for this, and means a
  // failed lookup doesn't get retried every time the list rebuilds.
  final Map<String, ArticleImageResult?> _cache = {};
  final Map<String, Future<ArticleImageResult?>> _inFlight = {};

  Future<ArticleImageResult?> resolve(String articleUrl) {
    if (_cache.containsKey(articleUrl)) {
      return Future.value(_cache[articleUrl]);
    }
    final existing = _inFlight[articleUrl];
    if (existing != null) return existing;

    final future = _fetch(articleUrl).then((result) {
      _cache[articleUrl] = result;
      _inFlight.remove(articleUrl);
      return result;
    }).catchError((_) {
      _cache[articleUrl] = null;
      _inFlight.remove(articleUrl);
      return null;
    });
    _inFlight[articleUrl] = future;
    return future;
  }

  Future<ArticleImageResult?> _fetch(String articleUrl) async {
    final uri = Uri.tryParse(articleUrl);
    if (uri == null) return null;

    final response = await _client.get(uri, headers: {
      'User-Agent':
          'Mozilla/5.0 (Android; Mobile) RealmApp/1.0 (+news-reader)',
    }).timeout(const Duration(seconds: 8));

    if (response.statusCode != 200) return null;

    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    // Only the <head> (or the first chunk, if a page has no clean
    // </head>) is worth scanning — no need to decode a whole article
    // body looking for meta tags.
    final headEnd = body.indexOf('</head>');
    final scanLimit = headEnd == -1
        ? (body.length < 80000 ? body.length : 80000)
        : headEnd;
    final head = body.substring(0, scanLimit);

    final jsonLd = _scanJsonLd(head);

    final rawImageUrl = _metaContent(head, 'og:image:secure_url') ??
        _metaContent(head, 'og:image') ??
        _metaContent(head, 'twitter:image') ??
        _metaContent(head, 'twitter:image:src') ??
        jsonLd?.imageUrl;

    if (rawImageUrl == null || rawImageUrl.isEmpty) return null;

    final resolvedImageUrl = _resolveRelative(rawImageUrl, uri);
    if (resolvedImageUrl == null) return null;

    final credit = jsonLd?.credit ?? _hostLabel(uri);

    return ArticleImageResult(
      imageUrl: resolvedImageUrl,
      credit: credit == null ? null : 'Photo: $credit',
    );
  }

  // ── Meta tag scanning ────────────────────────────────────────────

  String? _metaContent(String head, String property) {
    final escaped = RegExp.escape(property);
    // <meta property="og:image" content="...">
    final propertyFirst = RegExp(
      '<meta[^>]+(?:property|name)=["\']$escaped["\'][^>]*content=["\']([^"\']*)["\']',
      caseSensitive: false,
    );
    final m1 = propertyFirst.firstMatch(head);
    if (m1 != null && m1.group(1)!.isNotEmpty) return m1.group(1);

    // <meta content="..." property="og:image">
    final contentFirst = RegExp(
      '<meta[^>]+content=["\']([^"\']*)["\'][^>]*(?:property|name)=["\']$escaped["\']',
      caseSensitive: false,
    );
    final m2 = contentFirst.firstMatch(head);
    if (m2 != null && m2.group(1)!.isNotEmpty) return m2.group(1);

    return null;
  }

  // ── schema.org JSON-LD scanning ──────────────────────────────────

  _JsonLdImage? _scanJsonLd(String head) {
    final scriptPattern = RegExp(
      "<script[^>]+type=[\"']application/ld\\+json[\"'][^>]*>(.*?)</script>",
      caseSensitive: false,
      dotAll: true,
    );
    for (final match in scriptPattern.allMatches(head)) {
      final raw = match.group(1)?.trim();
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        final found = _searchJsonLdNode(decoded);
        if (found != null) return found;
      } catch (_) {
        // Malformed/truncated JSON-LD is common enough in the wild —
        // just move on to the next script block.
        continue;
      }
    }
    return null;
  }

  _JsonLdImage? _searchJsonLdNode(dynamic node) {
    if (node is List) {
      for (final item in node) {
        final found = _searchJsonLdNode(item);
        if (found != null) return found;
      }
      return null;
    }
    if (node is! Map) return null;

    final map = node.cast<String, dynamic>();
    if (map.containsKey('@graph')) {
      final found = _searchJsonLdNode(map['@graph']);
      if (found != null) return found;
    }

    final image = map['image'];
    if (image != null) {
      final imageUrl = _extractImageUrl(image);
      if (imageUrl != null) {
        final credit = _extractImageCredit(image) ??
            _extractCreditFromNode(map);
        return _JsonLdImage(imageUrl: imageUrl, credit: credit);
      }
    }

    return null;
  }

  String? _extractImageUrl(dynamic image) {
    if (image is String) return image;
    if (image is List && image.isNotEmpty) return _extractImageUrl(image.first);
    if (image is Map) {
      final url = image['url'] ?? image['contentUrl'];
      if (url is String) return url;
    }
    return null;
  }

  String? _extractImageCredit(dynamic image) {
    if (image is! Map) return null;
    final credit = image['creditText'] ??
        image['copyrightNotice'] ??
        (image['author'] is Map ? image['author']['name'] : image['author']);
    return credit is String && credit.trim().isNotEmpty
        ? credit.trim()
        : null;
  }

  String? _extractCreditFromNode(Map<String, dynamic> map) {
    final author = map['author'];
    if (author is Map && author['name'] is String) {
      return (author['name'] as String).trim();
    }
    if (author is String && author.trim().isNotEmpty) return author.trim();
    return null;
  }

  // ── URL / host helpers ───────────────────────────────────────────

  String? _resolveRelative(String rawUrl, Uri base) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('//')) return 'https:$trimmed';
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null) return null;
    if (parsed.hasScheme) return parsed.toString();
    return base.resolveUri(parsed).toString();
  }

  String? _hostLabel(Uri uri) {
    var host = uri.host;
    if (host.isEmpty) return null;
    if (host.startsWith('www.')) host = host.substring(4);
    return host;
  }
}

class _JsonLdImage {
  final String imageUrl;
  final String? credit;
  const _JsonLdImage({required this.imageUrl, this.credit});
}
