// supabase/functions/send-status-notification/index.ts
//
// Invoked once per new row in public.statuses, by the
// statuses_notify_after_insert trigger (see v33-migration.sql) — not
// polled, so a push goes out within a request round-trip of the
// status actually being posted.
//
// Unlike send-chat-notification (one recipient) this fans out to
// *every follower* of the creator: public.follows rows where
// following_id = the creator, each of whose active device_tokens
// gets its own push. Same multi-account model as chat — a follower
// with two accounts signed in on one device only gets pushed to for
// the account(s) that actually follow this creator, since
// device_tokens rows are per-account, not per-device.
//
// The payload carries `recipientId` (which follower account this
// push is *for*) and `creatorId`/`creatorUsername` (whose status it
// is) — mirrors send-chat-notification's recipientId/chatId split,
// for the same reason: the client needs to know both who to badge
// this against and who to open.
//
// Same secrets as check-new-news / send-chat-notification:
//   FIREBASE_SERVICE_ACCOUNT_JSON, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

import { createClient } from 'npm:@supabase/supabase-js@2';

// Same "sign our own Google OAuth2 JWT, call FCM's v1 REST API with
// plain fetch" approach as the other two functions, for the same
// reason: firebase-admin's dependency tree doesn't always play
// nicely with Deno's npm compatibility layer.
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

interface StatusPayload {
  status_id: string;
  creator_id: string;
  media_type: string;
  caption: string | null;
  created_at: string;
}

// Same "recognizable, not a replacement for opening it" preview
// length as send-chat-notification's message preview.
const MAX_CAPTION_LENGTH = 120;
function preview(caption: string | null): string | null {
  if (!caption) return null;
  if (caption.length <= MAX_CAPTION_LENGTH) return caption;
  return caption.slice(0, MAX_CAPTION_LENGTH - 1).trimEnd() + '…';
}

/// Sends one data-only FCM message for a status notification. Returns
/// false if the token is no longer valid, so the caller can prune
/// every account's row for it.
async function sendPush(
  projectId: string,
  accessToken: string,
  fcmToken: string,
  payload: {
    recipientId: string;
    creatorId: string;
    creatorUsername: string;
    creatorAvatarUrl: string | null;
    mediaUrl: string;
    caption: string | null;
    statusId: string;
  },
): Promise<boolean> {
  const data: Record<string, string> = {
    type: 'status',
    recipientId: payload.recipientId,
    creatorId: payload.creatorId,
    creatorUsername: payload.creatorUsername,
    mediaUrl: payload.mediaUrl,
    statusId: payload.statusId,
  };
  if (payload.creatorAvatarUrl) data.creatorAvatarUrl = payload.creatorAvatarUrl;
  if (payload.caption) data.caption = payload.caption;

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
          // Data-only, same as the other two pushers — the client
          // always decides how to render it, which is what lets it
          // pick the right account's theme and know which signed-in
          // account this push is even for.
          data,
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

Deno.serve(async (req) => {
  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const serviceAccountRaw = Deno.env.get('FIREBASE_SERVICE_ACCOUNT_JSON');
    if (!serviceAccountRaw) {
      return new Response('Missing FIREBASE_SERVICE_ACCOUNT_JSON secret', { status: 500 });
    }
    const serviceAccount = JSON.parse(serviceAccountRaw);
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    const body = (await req.json()) as StatusPayload;
    const { status_id, creator_id, media_type } = body;
    if (!status_id || !creator_id) {
      return new Response('Missing status_id/creator_id', { status: 400 });
    }

    // Creator's profile, the status row itself (for media_url — not
    // guaranteed to have finished committing in a way pg_net's
    // trigger payload can see, so this is the source of truth rather
    // than trusting the trigger body for it), everyone who follows
    // this creator, and the Google OAuth access token don't depend on
    // each other — run them concurrently, same reasoning as
    // send-chat-notification's Promise.all.
    const [creatorResult, statusResult, followerResult, accessToken] = await Promise.all([
      supabase
        .from('profiles')
        .select('username, display_name, avatar_url')
        .eq('id', creator_id)
        .maybeSingle(),
      supabase
        .from('statuses')
        .select('media_url, caption')
        .eq('id', status_id)
        .maybeSingle(),
      supabase
        .from('follows')
        .select('follower_id')
        .eq('following_id', creator_id),
      getAccessToken(serviceAccount),
    ]);

    const creatorUsername =
      creatorResult.data?.display_name || creatorResult.data?.username || 'Someone';
    const creatorAvatarUrl = (creatorResult.data?.avatar_url as string | null) ?? null;
    const mediaUrl = (statusResult.data?.media_url as string | undefined) ?? '';
    const caption = preview((statusResult.data?.caption as string | null) ?? body.caption ?? null);

    const followerIds = [
      ...new Set((followerResult.data ?? []).map((f) => f.follower_id as string)),
    ];
    if (followerIds.length === 0) {
      return new Response(JSON.stringify({ notified: 0, reason: 'no followers' }), { status: 200 });
    }

    // One row per (follower account, device) — a follower with the
    // same physical device signed into two accounts, only one of
    // which follows this creator, correctly gets exactly one push,
    // not two.
    const tokenRowsResult = await supabase
      .from('device_tokens')
      .select('user_id, fcm_token')
      .in('user_id', followerIds)
      .eq('active', true);

    const tokenRows = tokenRowsResult.data ?? [];
    if (tokenRows.length === 0) {
      return new Response(JSON.stringify({ notified: 0, reason: 'no active devices for followers' }), { status: 200 });
    }

    // One push per (recipient, device) — fan every send out
    // concurrently, same as send-chat-notification, so one slow or
    // dead token never holds up the rest of the followers' pushes.
    const sendResults = await Promise.all(
      tokenRows.map((row) =>
        sendPush(serviceAccount.project_id, accessToken, row.fcm_token as string, {
          recipientId: row.user_id as string,
          creatorId: creator_id,
          creatorUsername,
          creatorAvatarUrl,
          mediaUrl,
          caption,
          statusId: status_id,
        }).then((ok) => ({ token: row.fcm_token as string, ok })),
      ),
    );
    const deadTokens = [...new Set(sendResults.filter((r) => !r.ok).map((r) => r.token))];

    if (deadTokens.length > 0) {
      // A dead token is dead for every account sharing it, not just
      // whichever follower we happened to be pushing to — remove the
      // whole set of rows so no future push (to any account) wastes
      // a call on it.
      await supabase.from('device_tokens').delete().in('fcm_token', deadTokens);
    }

    return new Response(
      JSON.stringify({
        followers: followerIds.length,
        notified: tokenRows.length,
        prunedTokens: deadTokens.length,
        mediaType: media_type ?? null,
      }),
      { status: 200 },
    );
  } catch (error) {
    console.error(error);
    return new Response(JSON.stringify({ error: String(error) }), { status: 500 });
  }
});
