-- ================================================================
-- REALM v28 — AI-generated avatar detection (soft-flag, not a block)
-- Run this in the Supabase SQL editor after v27-migration.sql
-- ================================================================
--
-- Policy: this NEVER blocks or rejects an avatar upload. Detector
-- false-positive rates on real photos run 5-15% even on vendors'
-- own numbers (worse once an image has been resized/recompressed,
-- which every upload here already is) — hard-blocking on that error
-- rate means real people's real photos getting rejected with no
-- recourse. Instead, a flagged avatar just gets a quiet marker on
-- the owner's own profile (see get_my_avatar_flag below and
-- profile_screen.dart) — informational, not punitive, and there
-- solely so a human reviewing accounts later has a signal to work
-- from instead of nothing.
--
-- Required Edge Function secrets (set with `supabase secrets set`,
-- not committed): SIGHTENGINE_API_USER, SIGHTENGINE_API_SECRET —
-- see supabase/functions/check-ai-image/index.ts.

-- 1. Schema -----------------------------------------------------------------
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS avatar_ai_score numeric,
  ADD COLUMN IF NOT EXISTS avatar_ai_flagged boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS avatar_ai_checked_at timestamptz;

-- 2. profile_stats view — carries the flag through to the owner's own
-- profile screen. Same shape as v17's definition, with the three new
-- columns added; nothing else about the view changes.
CREATE OR REPLACE VIEW public.profile_stats AS
SELECT
  p.id AS user_id,
  p.username,
  count(DISTINCT d.id) AS drops_created,
  count(DISTINCT du.drop_id) AS drops_unlocked,
  p.avatar_url,
  count(DISTINCT f.id) AS follower_count,
  p.last_active_at,
  p.avatar_ai_score,
  p.avatar_ai_flagged,
  p.avatar_ai_checked_at
FROM public.profiles p
LEFT JOIN public.drops d ON d.creator_id = p.id
LEFT JOIN public.drop_unlocks du ON du.user_id = p.id
LEFT JOIN public.follows f ON f.following_id = p.id
GROUP BY p.id, p.username, p.avatar_url, p.last_active_at,
  p.avatar_ai_score, p.avatar_ai_flagged, p.avatar_ai_checked_at;

-- Note: profile_stats is queried with .eq('user_id', ...) from the
-- client (see fetchProfileStats in supabase_service.dart) — it was
-- never restricted to "your own row only" at the database level, so
-- these three new columns are just as visible to anyone looking up
-- anyone else's stats as avatar_url already was. That's fine today
-- because only ProfileScreen (the signed-in user's own profile, no
-- userId parameter) calls fetchProfileStats — but if a future screen
-- ever calls it for someone else's id, these columns would leak
-- there too. Worth revisiting with a real "is this the caller's own
-- row" check if that happens.
