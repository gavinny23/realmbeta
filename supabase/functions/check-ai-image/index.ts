// supabase/functions/check-ai-image/index.ts
//
// Called right after a successful avatar upload (see uploadAvatar in
// supabase_service.dart) — never blocks the upload itself, which has
// already completed and is already public by the time this runs.
// This only ever adds a quiet flag to the caller's own profile row
// for a human to act on later; see the policy note in
// v28-migration.sql for why this doesn't reject anything outright.
//
// Required secrets (set with `supabase secrets set`, not committed):
//   SIGHTENGINE_API_USER / SIGHTENGINE_API_SECRET — from
//     https://dashboard.sightengine.com (free tier available). The
//     "genai" model this calls is documented at
//     https://sightengine.com/docs/ai-generated-image-detection
//   SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY —
//     already present by default in every Edge Function's
//     environment.
//
// Keeps Supabase's default JWT verification on (see
// github-oauth-exchange for the same pattern) so this only runs for
// a signed-in Realm user — otherwise it's an open proxy for burning
// through the Sightengine quota.

import { createClient } from 'npm:@supabase/supabase-js@2';

// Deliberately conservative. Vendors' own published numbers put
// real-world false positives on genuine photos at roughly 5-15%,
// worse once an image has been resized/recompressed (every avatar
// here already has been, via uploadAvatar). A flag is a soft,
// informational marker on the owner's own profile, not a rejection —
// but it should still take a fairly confident score to earn one, so
// it stays a meaningful signal rather than noise.
const AI_FLAG_THRESHOLD = 0.85;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405);
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json({ error: 'Missing Authorization header' }, 401);

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      return json({ error: 'Server is missing SUPABASE_URL/SUPABASE_ANON_KEY/SUPABASE_SERVICE_ROLE_KEY' }, 500);
    }

    // Scoped to the caller's own JWT, purely to find out who's
    // calling — the actual write below always goes through the
    // service-role client instead, since flagging a profile has to
    // work regardless of whatever RLS ends up on these columns.
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: userError } = await callerClient.auth.getUser();
    if (userError || !user) return json({ error: 'Invalid session' }, 401);

    const body = await req.json().catch(() => ({}));
    const imageUrl = body?.image_url;
    if (!imageUrl || typeof imageUrl !== 'string') {
      return json({ error: 'Missing "image_url"' }, 400);
    }

    const apiUser = Deno.env.get('SIGHTENGINE_API_USER');
    const apiSecret = Deno.env.get('SIGHTENGINE_API_SECRET');
    if (!apiUser || !apiSecret) {
      return json({ error: 'Server is missing SIGHTENGINE_API_USER/SIGHTENGINE_API_SECRET' }, 500);
    }

    const params = new URLSearchParams({
      url: imageUrl,
      models: 'genai',
      api_user: apiUser,
      api_secret: apiSecret,
    });

    const sightengineRes = await fetch(`https://api.sightengine.com/1.0/check.json?${params}`);
    const result = await sightengineRes.json();

    if (result.status !== 'success') {
      // A vendor-side hiccup (bad fetch of the image, rate limit,
      // transient error) is not a verdict — leave the columns as
      // whatever they were (null the first time = "not yet checked")
      // rather than recording a false "clear" or "flagged".
      return json({
        checked: false,
        reason: result.error?.message ?? 'Sightengine did not return success',
      });
    }

    const score = typeof result.type?.ai_generated === 'number' ? result.type.ai_generated : null;
    const flagged = score !== null && score >= AI_FLAG_THRESHOLD;

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const { error: updateError } = await adminClient
      .from('profiles')
      .update({
        avatar_ai_score: score,
        avatar_ai_flagged: flagged,
        avatar_ai_checked_at: new Date().toISOString(),
      })
      .eq('id', user.id);

    if (updateError) {
      return json({ error: `Checked but failed to save: ${updateError.message}` }, 500);
    }

    return json({ checked: true, score, flagged });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
