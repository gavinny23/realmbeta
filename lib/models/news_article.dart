import 'dart:typed_data';

/// Which tier a source belongs to — drives both sort order and the
/// little badge on each card. Kenya stories always sort ahead of
/// Africa/world ones (see [NewsService]), which is the actual point
/// of this whole tab: local news is the priority, not an afterthought
/// buried under global headlines.
enum NewsTier { kenya, africa, world }

NewsTier _tierFromName(String raw) {
  switch (raw) {
    case 'africa':
      return NewsTier.africa;
    case 'world':
      return NewsTier.world;
    default:
      return NewsTier.kenya;
  }
}

/// One story pulled from an RSS feed. Deliberately thin — this is a
/// syndicated headline + short summary + link back to the publisher,
/// not a copy of the article itself.
class NewsArticle {
  /// Stable id derived from the article link — used as the primary
  /// key for comments and for de-duplicating the same story if it
  /// happens to show up in more than one feed.
  final String id;
  final String title;
  final String? summary;
  final String link;
  final String? imageUrl;
  final String sourceName;
  final NewsTier tier;
  final String? category; // e.g. "Entertainment", "Politics" — optional
  final DateTime publishedAt;

  /// Attribution line for [imageUrl], e.g. "Photo: BBC" or a named
  /// photo credit when the source page exposes one. Only ever set
  /// when the image came from [ArticleImageService]'s fallback
  /// lookup rather than the RSS feed itself — a feed-supplied image
  /// is already understood to belong to that story via the
  /// publisher, same as it would on their own site.
  final String? imageCredit;

  /// Set only when no real image could be found anywhere (not in the
  /// feed, not on the publisher's own page) and [GeneratedImageService]
  /// produced an illustrative stand-in instead. Deliberately kept
  /// separate from [imageUrl]/[imageCredit] — a generated image is a
  /// different kind of thing than a photo and the UI always has to
  /// label it as such, never blend it in as if it were real.
  final Uint8List? generatedImageBytes;

  NewsArticle({
    required this.id,
    required this.title,
    this.summary,
    required this.link,
    this.imageUrl,
    this.imageCredit,
    this.generatedImageBytes,
    required this.sourceName,
    required this.tier,
    this.category,
    required this.publishedAt,
  });

  /// Returns a copy with a resolved fallback image + credit applied.
  /// Used by the Updates tab once [ArticleImageService] finds an
  /// image for a story whose feed entry didn't include one.
  NewsArticle withResolvedImage({
    required String imageUrl,
    String? imageCredit,
  }) {
    return NewsArticle(
      id: id,
      title: title,
      summary: summary,
      link: link,
      imageUrl: imageUrl,
      imageCredit: imageCredit,
      sourceName: sourceName,
      tier: tier,
      category: category,
      publishedAt: publishedAt,
    );
  }

  /// Returns a copy carrying an AI-generated illustration, used only
  /// as a last resort when [withResolvedImage] found nothing real.
  NewsArticle withGeneratedImage(Uint8List bytes) {
    return NewsArticle(
      id: id,
      title: title,
      summary: summary,
      link: link,
      generatedImageBytes: bytes,
      sourceName: sourceName,
      tier: tier,
      category: category,
      publishedAt: publishedAt,
    );
  }

  /// Returns a copy with the feed-supplied image stripped, as if the
  /// feed had never given us one. Used by [NewsService] when an
  /// image turns out to be generic wire-service filler (a stock
  /// globe, a masthead, a "no photo available" graphic) rather than
  /// something specific to this story — that's treated the same as
  /// "no image", which lets [UpdatesView] fall through to
  /// [ArticleImageService] and then [GeneratedImageService] exactly
  /// as it already does for a feed entry with no image at all.
  NewsArticle withoutImage() {
    return NewsArticle(
      id: id,
      title: title,
      summary: summary,
      link: link,
      sourceName: sourceName,
      tier: tier,
      category: category,
      publishedAt: publishedAt,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'summary': summary,
        'link': link,
        'image_url': imageUrl,
        'image_credit': imageCredit,
        'source_name': sourceName,
        'tier': tier.name,
        'category': category,
        'published_at': publishedAt.toIso8601String(),
      };

  factory NewsArticle.fromMap(Map<String, dynamic> map) {
    return NewsArticle(
      id: map['id'] as String,
      title: map['title'] as String? ?? '',
      summary: map['summary'] as String?,
      link: map['link'] as String,
      imageUrl: map['image_url'] as String?,
      imageCredit: map['image_credit'] as String?,
      sourceName: map['source_name'] as String? ?? '',
      tier: _tierFromName(map['tier'] as String? ?? 'kenya'),
      category: map['category'] as String?,
      publishedAt:
          DateTime.tryParse(map['published_at'] as String? ?? '') ??
              DateTime.now(),
    );
  }

  /// Short "3h ago" / "2d ago" style label, matching the tone of
  /// [Drop.distanceLabel] elsewhere in the app.
  String get timeAgoLabel {
    final diff = DateTime.now().difference(publishedAt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${(diff.inDays / 7).floor()}w ago';
  }

  /// No feed exposes an actual "this is breaking" flag — outlets just
  /// prefix the headline itself, so this is a best-effort read of that
  /// same convention rather than anything structured. Deliberately
  /// only checks the very start of the title: "breaking" showing up
  /// mid-headline ("...after the breaking of talks...") shouldn't
  /// count, only an editor actually tagging the story as breaking.
  static final _breakingPrefixes = RegExp(
    r'^(breaking\s*news?|breaking|just\s*in|urgent|live\s*updates?|live)\s*[:\-–—]',
    caseSensitive: false,
  );

  bool get isBreaking => _breakingPrefixes.hasMatch(title.trim());
}
