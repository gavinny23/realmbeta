// supabase/functions/check-new-news/index.ts
//
// Runs on a schedule (see v19-migration.sql's pg_cron job). Each run:
//  1. Fetches the same RSS feeds NewsService.dart shows in the app.
//  2. Diffs against news_seen_articles to find genuinely new links.
//  3. On the very first-ever run (empty ledger), backfills silently —
//     otherwise the first run would blast a notification for every
//     article every feed currently has, which is exactly the kind of
//     notification-storm first impression that gets an app uninstalled.
//  4. Otherwise, sends a data-only FCM v1 push per (new article ×
//     registered device) for a curated subset of sources — every RSS
//     item across all 11 feeds would be far too noisy; see
//     NOTIFY_SOURCE_NAMES below to widen this later.
//
// Required secrets (set with `supabase secrets set`, not committed):
//   FIREBASE_SERVICE_ACCOUNT_JSON — the full JSON key of a Firebase
//     service account with the "Firebase Cloud Messaging API" role,
//     downloaded from Firebase console → Project settings → Service
//     accounts → Generate new private key.
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY — already present by
//     default in every Supabase Edge Function's environment.
//
// This intentionally signs its own Google OAuth2 JWT and calls FCM's
// HTTP v1 REST API directly with plain `fetch`, rather than pulling in
// the full firebase-admin SDK — that package's dependency tree doesn't
// always behave well under Deno's npm compatibility layer, and this
// function only ever needs the one `messages:send` call.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { XMLParser } from 'npm:fast-xml-parser@4';

// Only these source names trigger a push, even though every feed below
// still gets crawled into news_seen_articles (so switching a source on
// later doesn't suddenly "discover" a backlog of old stories as new).
const NOTIFY_SOURCE_NAMES = new Set(['Kenyans.co.ke', 'The Standard', 'Nation']);

// Hard cap per run, regardless of how many genuinely-new articles
// were found — a burst of 20 stories becoming 20 separate
// notifications is its own kind of spam.
const MAX_NOTIFICATIONS_PER_RUN = 5;

interface Feed {
  url: string;
  sourceName: string;
}

// Mirrors NewsService.dart's _feeds list — categories/tiers aren't
// needed here since this function only cares about "is this link
// new", not how the Updates tab sorts/filters it. Keep this in sync
// by hand if the Dart list changes; there's no single shared source
// of truth between the app and this function.
const FEEDS: Feed[] = [
  { url: 'https://www.kenyans.co.ke/feeds/news', sourceName: 'Kenyans.co.ke' },
  { url: 'https://www.standardmedia.co.ke/rss/headlines.php', sourceName: 'The Standard' },
  { url: 'https://nation.africa/kenya/rss.xml', sourceName: 'Nation' },
  { url: 'https://www.standardmedia.co.ke/rss/entertainment.php', sourceName: 'The Standard' },
  { url: 'https://www.standardmedia.co.ke/rss/sports.php', sourceName: 'The Standard' },
  { url: 'https://www.standardmedia.co.ke/rss/business.php', sourceName: 'The Standard' },
  { url: 'https://feeds.bbci.co.uk/news/world/africa/rss.xml', sourceName: 'BBC Africa' },
  { url: 'https://feeds.bbci.co.uk/sport/africa/rss.xml', sourceName: 'BBC Sport' },
  { url: 'https://feeds.bbci.co.uk/news/world/rss.xml', sourceName: 'BBC News' },
  { url: 'https://feeds.bbci.co.uk/news/business/rss.xml', sourceName: 'BBC News' },
  { url: 'https://feeds.bbci.co.uk/news/technology/rss.xml', sourceName: 'BBC News' },
];

interface ParsedArticle {
  link: string;
  title: string;
  sourceName: string;
  imageUrl: string | null;
}

const xmlParser = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '@_' });

function firstImageFromItem(item: Record<string, unknown>): string | null {
  // Different feeds put an image in different places — mirrors
  // NewsService.dart's _extractImage fallback order exactly, since
  // that's the method already proven to find an image for these same
  // sources in-app. Missing the last (description-scrape) tier here
  // was why push notifications lost their image for any feed that
  // only embeds it inside the <description> HTML rather than a
  // dedicated enclosure/media tag.
  const media = item['media:content'] as { '@_url'?: string } | undefined;
  if (media?.['@_url']) return media['@_url']!;
  const thumb = item['media:thumbnail'] as { '@_url'?: string } | undefined;
  if (thumb?.['@_url']) return thumb['@_url']!;
  const enclosure = item['enclosure'] as { '@_url'?: string; '@_type'?: string } | undefined;
  const enclosureType = enclosure?.['@_type'] ?? '';
  if (enclosure?.['@_url'] && (enclosureType === '' || enclosureType.startsWith('image'))) {
    return enclosure['@_url']!;
  }
  const description = item['description'];
  if (typeof description === 'string') {
    const match = description.match(/<img[^>]+src="([^"]+)"/);
    if (match) return match[1];
  }
  return null;
}

async function fetchFeed(feed: Feed): Promise<ParsedArticle[]> {
  try {
    const res = await fetch(feed.url, { signal: AbortSignal.timeout(10_000) });
    if (!res.ok) return [];
    const xml = await res.text();
    const parsed = xmlParser.parse(xml);
    const rawItems = parsed?.rss?.channel?.item ?? [];
    const items = Array.isArray(rawItems) ? rawItems : [rawItems];
    return items
      .filter((item) => item && typeof item === 'object' && item.link && item.title)
      .map((item) => ({
        link: String(item.link).trim(),
        title: String(item.title).trim(),
        sourceName: feed.sourceName,
        imageUrl: firstImageFromItem(item),
      }));
  } catch (_) {
    // One dead/slow feed shouldn't fail the whole run — same
    // "best-effort per source" contract as NewsService.dart's client
    // side fetch.
    return [];
  }
}

// ---- Google OAuth2 / FCM v1 -------------------------------------------------

function base64url(input: ArrayBuffer | string): string {
  const bytes = typeof input === 'string' ? new TextEncoder().encode(input) : new Uint8Array(input);
  let str = '';
  for (const b of bytes) str += String.fromCharCode(b);
  return btoa(str).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function getAccessToken(serviceAccount: {
  client_email: string;
  private_key: string;
}): Promise<string> {
  const header = { alg: 'RS256', typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    iss: serviceAccount.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claims))}`;

  const pemBody = serviceAccount.private_key
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replace(/\s/g, '');
  const keyData = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));
  const cryptoKey = await crypto.subtle.importKey(
    'pkcs8',
    keyData,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', cryptoKey, new TextEncoder().encode(unsigned));
  const jwt = `${unsigned}.${base64url(signature)}`;

  const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });
  if (!tokenRes.ok) {
    throw new Error(`OAuth token exchange failed: ${tokenRes.status} ${await tokenRes.text()}`);
  }
  const { access_token } = await tokenRes.json();
  return access_token as string;
}

/// Sends one data-only FCM message. Returns false if the token is
/// no longer valid (unregistered/invalid) so the caller can prune it.
async function sendPush(
  projectId: string,
  accessToken: string,
  fcmToken: string,
  article: ParsedArticle,
): Promise<boolean> {
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        message: {
          token: fcmToken,
          // Data-only (no top-level "notification" block) so the
          // client is always the one deciding how to display it —
          // that's what makes the Redrop/Comment action buttons
          // possible at all; a plain FCM-rendered notification
          // can't carry custom actions back into the Flutter side.
          data: {
            type: 'new_article',
            link: article.link,
            title: article.title,
            source_name: article.sourceName,
            image_url: article.imageUrl ?? '',
          },
          android: { priority: 'high' },
        },
      }),
    },
  );
  if (res.ok) return true;
  const body = await res.text();
  console.error(`FCM send failed for token ${fcmToken.slice(0, 12)}…: ${res.status} ${body}`);
  return !(res.status === 404 || body.includes('UNREGISTERED') || body.includes('INVALID_ARGUMENT'));
}

// ---- Entry point -------------------------------------------------------------

Deno.serve(async () => {
  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const serviceAccountRaw = Deno.env.get('FIREBASE_SERVICE_ACCOUNT_JSON');
    if (!serviceAccountRaw) {
      return new Response('Missing FIREBASE_SERVICE_ACCOUNT_JSON secret', { status: 500 });
    }
    const serviceAccount = JSON.parse(serviceAccountRaw);
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    // 1. Crawl every feed concurrently.
    const results = await Promise.all(FEEDS.map(fetchFeed));
    const articles = results.flat();
    // De-dupe by link — several feeds can surface the same story.
    const byLink = new Map<string, ParsedArticle>();
    for (const a of articles) if (!byLink.has(a.link)) byLink.set(a.link, a);

    // 2. Is this the very first run? An empty ledger means yes —
    // backfill every link as "seen" without notifying about any of
    // them, so the first real push is for the next actually-new story.
    const { count: seenCount } = await supabase
      .from('news_seen_articles')
      .select('article_link', { count: 'exact', head: true });
    const isFirstRun = (seenCount ?? 0) === 0;

    // 3. Insert everything, letting the unique constraint tell us
    // which ones were genuinely new (on conflict do nothing + only
    // the actually-inserted rows come back).
    const rows = [...byLink.values()].map((a) => ({
      article_link: a.link,
      article_title: a.title,
    }));
    if (rows.length === 0) {
      return new Response(JSON.stringify({ crawled: 0, notified: 0 }), { status: 200 });
    }
    const { data: inserted, error: insertError } = await supabase
      .from('news_seen_articles')
      .upsert(rows, { onConflict: 'article_link', ignoreDuplicates: true })
      .select('article_link');
    if (insertError) throw insertError;

    const newLinks = new Set((inserted ?? []).map((r) => r.article_link as string));
    const newArticles = [...byLink.values()]
      .filter((a) => newLinks.has(a.link) && NOTIFY_SOURCE_NAMES.has(a.sourceName))
      .slice(0, MAX_NOTIFICATIONS_PER_RUN);

    if (isFirstRun || newArticles.length === 0) {
      return new Response(
        JSON.stringify({ crawled: byLink.size, notified: 0, firstRun: isFirstRun }),
        { status: 200 },
      );
    }

    // 4. Push to every registered device.
    const { data: tokens } = await supabase.from('device_tokens').select('fcm_token');
    const fcmTokens = (tokens ?? []).map((t) => t.fcm_token as string);
    if (fcmTokens.length === 0) {
      return new Response(
        JSON.stringify({ crawled: byLink.size, notified: 0, reason: 'no registered devices' }),
        { status: 200 },
      );
    }

    const accessToken = await getAccessToken(serviceAccount);
    const deadTokens: string[] = [];
    for (const article of newArticles) {
      for (const token of fcmTokens) {
        const ok = await sendPush(serviceAccount.project_id, accessToken, token, article);
        if (!ok) deadTokens.push(token);
      }
    }
    if (deadTokens.length > 0) {
      await supabase.from('device_tokens').delete().in('fcm_token', deadTokens);
    }

    return new Response(
      JSON.stringify({
        crawled: byLink.size,
        notified: newArticles.length,
        devices: fcmTokens.length,
        prunedTokens: deadTokens.length,
      }),
      { status: 200 },
    );
  } catch (error) {
    console.error(error);
    return new Response(JSON.stringify({ error: String(error) }), { status: 500 });
  }
});
