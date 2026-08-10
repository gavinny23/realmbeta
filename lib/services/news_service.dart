import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import '../models/news_article.dart';

class _NewsFeed {
  final String url;
  final String sourceName;
  final NewsTier tier;
  final String? category;
  const _NewsFeed(this.url, this.sourceName, this.tier, {this.category});
}

/// Pulls, parses, and merges Kenyan/African/global news RSS feeds for
/// the "Updates" section of the feed tab.
///
/// Kenyan outlets are fetched first and always sort ahead of Africa
/// and world stories (see [_tierRank] in [latest]) — that's the whole
/// point of the tab: what's happening at home, before what's
/// happening everywhere else. Every story links back to the original
/// publisher; nothing here is a copy of the article, just a headline,
/// a short summary, and a "View full story" link out.
class NewsService {
  NewsService._();
  static final NewsService instance = NewsService._();

  // Sports/Business/Technology feeds below follow the same URL pattern
  // The Standard already uses for headlines/entertainment, and BBC's
  // long-stable topic-feed convention. Like every feed here, a stale
  // or renamed URL just yields zero stories for that topic (see
  // _fetchFeed's catchError below) rather than breaking the tab —
  // worth spot-checking these specific ones after adding them, since
  // they haven't been hit from this codebase before.
  static final List<_NewsFeed> _feeds = [
    // Kenya — general news
    _NewsFeed('https://www.kenyans.co.ke/feeds/news', 'Kenyans.co.ke',
        NewsTier.kenya),
    _NewsFeed('https://www.standardmedia.co.ke/rss/headlines.php',
        'The Standard', NewsTier.kenya),
    _NewsFeed('https://nation.africa/kenya/rss.xml', 'Nation', NewsTier.kenya),
    // Kenya — entertainment
    _NewsFeed('https://www.standardmedia.co.ke/rss/entertainment.php',
        'The Standard', NewsTier.kenya,
        category: 'Entertainment'),
    // Kenya — sports
    _NewsFeed('https://www.standardmedia.co.ke/rss/sports.php',
        'The Standard', NewsTier.kenya,
        category: 'Sports'),
    // Kenya — business
    _NewsFeed('https://www.standardmedia.co.ke/rss/business.php',
        'The Standard', NewsTier.kenya,
        category: 'Business'),
    // Africa
    _NewsFeed('https://feeds.bbci.co.uk/news/world/africa/rss.xml',
        'BBC Africa', NewsTier.africa),
    // Africa — sports
    _NewsFeed('https://feeds.bbci.co.uk/sport/africa/rss.xml', 'BBC Sport',
        NewsTier.africa,
        category: 'Sports'),
    // World
    _NewsFeed(
        'https://feeds.bbci.co.uk/news/world/rss.xml', 'BBC News', NewsTier.world),
    // World — business
    _NewsFeed('https://feeds.bbci.co.uk/news/business/rss.xml', 'BBC News',
        NewsTier.world,
        category: 'Business'),
    // World — technology
    _NewsFeed('https://feeds.bbci.co.uk/news/technology/rss.xml', 'BBC News',
        NewsTier.world,
        category: 'Technology'),
    // World — sports transfers. Separate from the general Sports
    // category above (which stays match reports/results) so the
    // Transfers filter is just window/deadline-day transfer chatter,
    // not results mixed in with it.
    _NewsFeed(
        'https://feeds.bbci.co.uk/sport/football/transfers/rss.xml',
        'BBC Sport',
        NewsTier.world,
        category: 'Transfers'),
    // Kenya — celebrity gossip. Deliberately kept as its own category
    // (never folded into plain "News") and flagged as unverified in
    // both NewsCard and the Gossip filter's disclaimer banner in
    // UpdatesView — these are entertainment blogs running on rumor,
    // reader tips, and unconfirmed screenshots, not outlets with the
    // editorial fact-checking the rest of this feed list has. Same
    // "stale URL just yields zero stories" contract as every feed
    // above.
    //
    // The site's own "Nairobi Gossip Club" bucket at
    // /feed/nairobi-gossip-club 404s (its RSS index page lists it,
    // but the endpoint itself doesn't resolve) — that 404 was why the
    // Gossip filter always rendered empty, since _fetchFeed's
    // catchError swallows it into zero stories rather than surfacing
    // an error. /feed/entertainment is the bucket that actually
    // carries the celebrity-gossip stories (confirmed serving real
    // XML), so that's what's wired up here instead.
    _NewsFeed('https://nairobigossipclub.co.ke/feed/entertainment',
        'Nairobi Gossip Club', NewsTier.kenya,
        category: 'Gossip'),
    _NewsFeed('https://www.mpasho.co.ke/feed', 'Mpasho', NewsTier.kenya,
        category: 'Gossip'),
    // Mpasho and Nairobi Gossip Club alone meant the whole Gossip
    // filter lived or died on two sources' posting cadence — when
    // both went quiet the newest available story could be weeks old,
    // which reads as broken even though every individual feed was
    // technically "working". Same WordPress /feed/ convention as
    // above, same "stale/dead URL just yields zero stories for that
    // one outlet" contract — worth spot-checking after adding, since
    // none of these three have been hit from this codebase before.
    _NewsFeed('https://www.ghafla.co.ke/ke/feed/', 'Ghafla!', NewsTier.kenya,
        category: 'Gossip'),
    _NewsFeed('https://sauce.co.ke/feed/', 'Sauce', NewsTier.kenya,
        category: 'Gossip'),
    _NewsFeed('https://nairobiwire.com/feed', 'Nairobi Wire', NewsTier.kenya,
        category: 'Gossip'),
  ];

  final _client = http.Client();

  /// Fetches every feed concurrently, parses whatever comes back
  /// (silently skipping any feed that fails or times out — one dead
  /// RSS endpoint shouldn't blank out the whole tab), de-duplicates by
  /// link, and returns everything sorted with Kenya first, then
  /// Africa, then world — newest within each tier.
  ///
  /// Throws if *every* feed failed rather than returning an empty
  /// list — that distinction matters a lot to the caller. A feed that
  /// comes back genuinely empty is a normal (if rare) success; total
  /// failure almost always means "no connection right now", and the
  /// caller (UpdatesView) needs to see that as a thrown error so it
  /// falls back to whatever's cached instead of overwriting a good
  /// cached list — and the on-screen articles — with nothing.
  Future<List<NewsArticle>> latest() async {
    var anySucceeded = false;
    final results = await Future.wait(
      _feeds.map((f) => _fetchFeed(f).then((r) {
            anySucceeded = true;
            return r;
          }).catchError((_) => <NewsArticle>[])),
    );

    if (!anySucceeded) {
      throw Exception('Could not reach any news source.');
    }

    final seen = <String>{};
    final merged = <NewsArticle>[];
    for (final list in results) {
      for (final article in list) {
        if (seen.add(article.id)) merged.add(article);
      }
    }

    final deGenericized = _stripGenericImages(merged);

    deGenericized.sort((a, b) {
      final tierCompare = _tierRank(a.tier).compareTo(_tierRank(b.tier));
      if (tierCompare != 0) return tierCompare;
      return b.publishedAt.compareTo(a.publishedAt);
    });

    return deGenericized;
  }

  /// Filename fragments outlets commonly reuse for a placeholder
  /// rather than a photo specific to the story: a bare masthead/og
  /// image, an explicit "no image"/"default" graphic, or a generic
  /// globe/world-map stock shot. Matched against the path only, not
  /// the query string, since cache-busting params vary per request.
  static final _genericImageHints = RegExp(
    r'(default[-_]?image|placeholder|no[-_]?image|no[-_]?photo|'
    r'fallback|generic|og[-_]?image|site[-_]?logo|masthead|'
    r'globe|world[-_]?map)',
    caseSensitive: false,
  );

  /// Strips [NewsArticle.imageUrl] from any story whose image looks
  /// like wire-service filler rather than something specific to that
  /// story, so [UpdatesView] treats it the same as "the feed gave us
  /// no image" and falls through to a real per-story lookup or,
  /// failing that, a generated illustration.
  ///
  /// Two independent signals, either one is enough:
  ///  - Reuse: the exact same image URL shows up on more than one
  ///    story in this fetch. A photo specific to one headline
  ///    doesn't also illustrate a different one — if it's on two,
  ///    it's filler, regardless of what outlet it came from. This is
  ///    the primary signal since it needs no site-specific knowledge
  ///    and catches whatever a given outlet's stock image happens to
  ///    be, even one we've never seen before.
  ///  - Filename: the URL's path matches a known placeholder-naming
  ///    convention (see [_genericImageHints]). Catches a generic
  ///    image on its first-ever appearance, before reuse could be
  ///    observed, at the cost of being source-specific and never
  ///    fully complete.
  List<NewsArticle> _stripGenericImages(List<NewsArticle> articles) {
    final urlCounts = <String, int>{};
    for (final a in articles) {
      final url = a.imageUrl;
      if (url != null) urlCounts[url] = (urlCounts[url] ?? 0) + 1;
    }

    return articles.map((a) {
      final url = a.imageUrl;
      if (url == null) return a;
      final reused = (urlCounts[url] ?? 0) > 1;
      final looksGeneric = _genericImageHints.hasMatch(Uri.parse(url).path);
      return (reused || looksGeneric) ? a.withoutImage() : a;
    }).toList();
  }

  int _tierRank(NewsTier tier) {
    switch (tier) {
      case NewsTier.kenya:
        return 0;
      case NewsTier.africa:
        return 1;
      case NewsTier.world:
        return 2;
    }
  }

  Future<List<NewsArticle>> _fetchFeed(_NewsFeed feed) async {
    final response = await _client
        .get(Uri.parse(feed.url), headers: {
          // A handful of these feeds reject requests with no UA set.
          'User-Agent':
              'Mozilla/5.0 (Android; Mobile) RealmApp/1.0 (+news-reader)',
        })
        .timeout(const Duration(seconds: 12));

    if (response.statusCode != 200) return [];

    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    final document = XmlDocument.parse(body);
    final items = document.findAllElements('item');

    return items
        .map((item) => _parseItem(item, feed))
        .whereType<NewsArticle>()
        .toList();
  }

  NewsArticle? _parseItem(XmlElement item, _NewsFeed feed) {
    final title = _text(item, 'title');
    final link = _text(item, 'link') ?? _guid(item);
    if (title == null || link == null) return null;

    final rawDescription = _text(item, 'description');
    final summary = _cleanSummary(rawDescription);
    final pubDateRaw = _text(item, 'pubDate') ?? _text(item, 'pubdate');
    final publishedAt = _parseDate(pubDateRaw);
    final imageUrl = _extractImage(item, rawDescription);

    return NewsArticle(
      id: link,
      title: _decodeEntities(title).trim(),
      summary: summary,
      link: link,
      imageUrl: imageUrl,
      sourceName: feed.sourceName,
      tier: feed.tier,
      category: feed.category,
      publishedAt: publishedAt,
    );
  }

  String? _text(XmlElement item, String tag) {
    final el = item.findElements(tag).firstOrNull;
    final value = el?.innerText.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  String? _guid(XmlElement item) {
    final el = item.findElements('guid').firstOrNull;
    final value = el?.innerText.trim();
    if (value == null || value.isEmpty) return null;
    // Only usable as a link if it actually looks like a URL — some
    // feeds put a non-URL id in <guid>.
    return value.startsWith('http') ? value : null;
  }

  /// Looks for an image in the usual RSS/Media-RSS spots, in order of
  /// how reliable they tend to be: media:content, media:thumbnail,
  /// enclosure, then finally scraping the first <img> out of the raw
  /// HTML description as a last resort.
  String? _extractImage(XmlElement item, String? rawDescription) {
    for (final tag in ['media:content', 'media:thumbnail']) {
      final el = item.findElements(tag).firstOrNull;
      final url = el?.getAttribute('url');
      if (url != null && url.isNotEmpty) return url;
    }
    final enclosure = item.findElements('enclosure').firstOrNull;
    final enclosureType = enclosure?.getAttribute('type') ?? '';
    final enclosureUrl = enclosure?.getAttribute('url');
    if (enclosureUrl != null &&
        (enclosureType.startsWith('image') || enclosureType.isEmpty)) {
      return enclosureUrl;
    }
    if (rawDescription != null) {
      final match = RegExp(r'<img[^>]+src="([^"]+)"').firstMatch(rawDescription);
      if (match != null) return match.group(1);
    }
    return null;
  }

  /// Strips HTML tags/entities from an RSS <description> and trims it
  /// to a snippet-length summary — feeds routinely embed a full HTML
  /// blob (links, spans, sometimes an <img>) in there.
  String? _cleanSummary(String? raw) {
    if (raw == null) return null;
    final withoutTags = raw.replaceAll(RegExp(r'<[^>]*>'), ' ');
    final decoded = _decodeEntities(withoutTags);
    final collapsed = decoded.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.isEmpty) return null;
    return collapsed.length > 220
        ? '${collapsed.substring(0, 220).trim()}…'
        : collapsed;
  }

  String _decodeEntities(String input) {
    return input
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ');
  }

  DateTime _parseDate(String? raw) {
    if (raw == null) return DateTime.now();
    try {
      // RFC-822 style, e.g. "Fri, 24 Jul 2026 01:53:36 +0300" — the
      // format basically every RSS <pubDate> uses.
      return _RssDate.parse(raw);
    } catch (_) {
      return DateTime.tryParse(raw) ?? DateTime.now();
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// Minimal RFC-822/HTTP-date parser — avoids pulling in `dart:io`
/// (unavailable cleanly alongside some of this app's web-adjacent
/// tooling) just for `_RssDate.parse`.
class _RssDate {
  static final _months = {
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
    'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
  };

  static DateTime parse(String input) {
    // e.g. "Fri, 24 Jul 2026 01:53:36 +0300" or "...GMT"
    final cleaned = input.trim();
    final match = RegExp(
            r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s*([+-]\d{4}|GMT|UTC)?')
        .firstMatch(cleaned);
    if (match == null) throw FormatException('Not an RFC-822 date: $input');
    final day = int.parse(match.group(1)!);
    final month = _months[match.group(2)!] ?? 1;
    final year = int.parse(match.group(3)!);
    final hour = int.parse(match.group(4)!);
    final minute = int.parse(match.group(5)!);
    final second = int.parse(match.group(6)!);
    final tz = match.group(7);

    var dt = DateTime.utc(year, month, day, hour, minute, second);
    if (tz != null && tz != 'GMT' && tz != 'UTC') {
      final sign = tz.startsWith('-') ? -1 : 1;
      final offsetHours = int.parse(tz.substring(1, 3));
      final offsetMinutes = int.parse(tz.substring(3, 5));
      dt = dt.subtract(
          Duration(hours: sign * offsetHours, minutes: sign * offsetMinutes));
    }
    return dt.toLocal();
  }
}
