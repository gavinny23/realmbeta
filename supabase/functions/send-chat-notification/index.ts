// supabase/functions/send-chat-notification/index.ts
//
// Invoked once per new row in public.messages, by the
// messages_notify_after_insert trigger (see v32-migration.sql) —
// not polled, so a push goes out within a request round-trip of the
// message actually being sent.
//
// Multi-account model (this is the whole point of this function):
// device_tokens no longer maps one fcm_token to one user. The exact
// same physical device can have a row for User A *and* a row for
// User B against the same fcm_token, because AccountManagerService
// lets both stay signed in and just switches which one is "active"
// in the UI. So:
//
//  - Sending to User A looks up device_tokens where user_id = A,
//    finds that shared token, and pushes to it — regardless of
//    whether A or B is the account currently open on screen.
//  - The payload carries `recipientId` (who this message is *for*)
//    so the client can badge/display it against the right account,
//    and `chatId` (the other participant, i.e. who to open a
//    conversation with) so tapping it knows where to navigate.
//  - A token only stops getting pushed to for one account when that
//    account's `device_tokens.active` is set to false (explicit sign
//    out — see AccountManagerService.forgetAccount /
//    PushNotificationService.unregisterCurrentToken) — never merely
//    because a different account is the one currently active.
//
// If FCM reports a token as truly dead (unregistered/uninstalled),
// that's a property of the *token*, not of any one account, so every
// row sharing that fcm_token is pruned — across every account still
// pointing at it.
//
// Same secrets as check-new-news:
//   FIREBASE_SERVICE_ACCOUNT_JSON, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

import { createClient } from 'npm:@supabase/supabase-js@2';

// Same "sign our own Google OAuth2 JWT, call FCM's v1 REST API with
// plain fetch" approach as check-new-news, for the same reason:
// firebase-admin's dependency tree doesn't always play nicely with
// Deno's npm compatibility layer, and this function only ever needs
// one messages:send call per device.
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

interface MessagePayload {
  message_id: string;
  sender_id: string;
  recipient_id: string;
  content: string;
  created_at: string;
}

// A generous preview, not the full message — same reasoning as any
// chat app's lock-screen preview: enough to recognize what it's
// about, not a replacement for opening the thread.
const MAX_PREVIEW_LENGTH = 120;
function preview(content: string): string {
  if (content.length <= MAX_PREVIEW_LENGTH) return content;
  return content.slice(0, MAX_PREVIEW_LENGTH - 1).trimEnd() + '…';
}

/// Sends one data-only FCM message for a chat notification. Returns
/// false if the token is no longer valid, so the caller can prune
/// every account's row for it.
async function sendPush(
  projectId: string,
  accessToken: string,
  fcmToken: string,
  payload: {
    recipientId: string;
    chatId: string;
    senderName: string;
    message: string;
    messageId: string;
  },
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
          // Data-only, same as check-new-news: the client always
          // decides how to render it, which is what lets it pick the
          // right account's theme/avatar and — critically — know
          // which signed-in account this push is even for.
          data: {
            type: 'message',
            recipientId: payload.recipientId,
            chatId: payload.chatId,
            senderName: payload.senderName,
            message: payload.message,
            messageId: payload.messageId,
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

    const body = (await req.json()) as MessagePayload;
    const { sender_id, recipient_id, content, message_id } = body;
    if (!sender_id || !recipient_id || !content) {
      return new Response('Missing sender_id/recipient_id/content', { status: 400 });
    }

    // 1. Sender's display name, the recipient's active device tokens,
    // and the Google OAuth access token don't depend on each other —
    // running them concurrently rather than one after another is what
    // keeps this comfortably under pg_net's 5s default request
    // timeout (see v32.2-migration.sql, which also raises that
    // ceiling as a safety net, but this is the real fix: an Edge
    // Function cold start plus 3 sequential round trips to Postgres/
    // Google was routinely blowing past 5s on its own).
    const [senderResult, tokenRowsResult, accessToken] = await Promise.all([
      supabase
        .from('profiles')
        .select('username, display_name')
        .eq('id', sender_id)
        .maybeSingle(),
      supabase
        .from('device_tokens')
        .select('fcm_token')
        .eq('user_id', recipient_id)
        .eq('active', true),
      getAccessToken(serviceAccount),
    ]);
    const senderName =
      senderResult.data?.display_name || senderResult.data?.username || 'Someone';
    const fcmTokens = [
      ...new Set((tokenRowsResult.data ?? []).map((t) => t.fcm_token as string)),
    ];
    if (fcmTokens.length === 0) {
      return new Response(JSON.stringify({ notified: 0, reason: 'no active devices for recipient' }), { status: 200 });
    }

    // 2. One device's push failing (or being slow) shouldn't hold up
    // another's — fan every token out concurrently instead of
    // looping through them one at a time.
    const sendResults = await Promise.all(
      fcmTokens.map((token) =>
        sendPush(serviceAccount.project_id, accessToken, token, {
          recipientId: recipient_id,
          chatId: sender_id,
          senderName,
          message: preview(content),
          messageId: message_id ?? '',
        }).then((ok) => ({ token, ok })),
      ),
    );
    const deadTokens = sendResults.filter((r) => !r.ok).map((r) => r.token);

    if (deadTokens.length > 0) {
      // A dead token is dead for every account sharing it, not just
      // the recipient we happened to be pushing to here — remove the
      // whole set of rows so no future push (to any account) wastes
      // a call on it.
      await supabase.from('device_tokens').delete().in('fcm_token', deadTokens);
    }

    return new Response(
      JSON.stringify({ notified: fcmTokens.length, prunedTokens: deadTokens.length }),
      { status: 200 },
    );
  } catch (error) {
    console.error(error);
    return new Response(JSON.stringify({ error: String(error) }), { status: 500 });
  }
});