// supabase/functions/github-oauth-exchange/index.ts
//
// One step of the Dev Hub's "Connect GitHub" flow (see
// GithubService.dart): the client opens GitHub's OAuth consent
// screen in an external browser, GitHub redirects back into the app
// with a one-time authorization `code`, and the app POSTs that code
// here. This function is the only place the GitHub OAuth App's
// client secret is ever used — trading a `code` for an access_token
// requires the secret, and a secret can't safely live in a
// distributed app binary, so this one exchange step has to happen
// server-side.
//
// Deliberately decoupled from Supabase Auth identity linking
// (auth.linkIdentity): the resulting GitHub access token is handed
// straight back to the client, which stores it in its own secure
// storage. Nothing here writes it to any table or associates it with
// the calling Realm account — so it works for ANY GitHub account,
// regardless of which Realm user happens to be signed in.
//
// Required secrets (set with `supabase secrets set`, not committed):
//   GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET — from the GitHub OAuth
//     App at https://github.com/settings/developers. Its
//     "Authorization callback URL" must be set to
//     realm://github-callback (see AndroidManifest.xml's
//     intent-filter). GITHUB_CLIENT_ID is not itself secret — the
//     same value also lives in the app's own .env — but it's kept as
//     a secret here too rather than hardcoded, so rotating the OAuth
//     App later is a one-place change.
//
// This function keeps Supabase's default JWT verification on, so it
// only runs for a signed-in Realm user — not because the GitHub
// token ends up tied to that identity (it doesn't), just so this
// isn't an open proxy for spending calls against our OAuth App's
// rate limits.

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), { status: 405 });
  }

  try {
    const clientId = Deno.env.get('GITHUB_CLIENT_ID');
    const clientSecret = Deno.env.get('GITHUB_CLIENT_SECRET');
    if (!clientId || !clientSecret) {
      return new Response(
        JSON.stringify({ error: 'Server is missing GITHUB_CLIENT_ID/GITHUB_CLIENT_SECRET' }),
        { status: 500 },
      );
    }

    const { code, redirect_uri } = await req.json();
    if (!code || typeof code !== 'string') {
      return new Response(JSON.stringify({ error: 'Missing "code"' }), { status: 400 });
    }

    const tokenRes = await fetch('https://github.com/login/oauth/access_token', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: JSON.stringify({
        client_id: clientId,
        client_secret: clientSecret,
        code,
        redirect_uri: typeof redirect_uri === 'string' ? redirect_uri : 'realm://github-callback',
      }),
    });

    const body = await tokenRes.json();
    if (!tokenRes.ok || body.error) {
      return new Response(
        JSON.stringify({
          error: body.error_description ?? body.error ?? `GitHub returned ${tokenRes.status}`,
        }),
        { status: 400 },
      );
    }
    if (!body.access_token) {
      return new Response(
        JSON.stringify({ error: 'GitHub did not return an access token' }),
        { status: 400 },
      );
    }

    return new Response(
      JSON.stringify({ access_token: body.access_token, scope: body.scope ?? null }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  } catch (error) {
    console.error(error);
    return new Response(JSON.stringify({ error: String(error) }), { status: 500 });
  }
});
