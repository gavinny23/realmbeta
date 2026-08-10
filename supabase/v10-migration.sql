-- ================================================================
-- REALITY MERGE v10 — Followers list + "my drops" gallery for profile
-- Run this in the Supabase SQL editor after v9-migration.sql
-- ================================================================

-- 1. follower_count on profile_stats -----------------------------------------
-- Appended at the END of the column list (not inserted next to
-- drops_unlocked) because CREATE OR REPLACE VIEW can only add trailing
-- columns — it errors if a replacement changes the position of an
-- existing column, since Postgres reads that as an implicit rename.
CREATE OR REPLACE VIEW public.profile_stats AS
SELECT
  p.id AS user_id,
  p.username,
  count(DISTINCT d.id) AS drops_created,
  count(DISTINCT du.drop_id) AS drops_unlocked,
  p.avatar_url,
  count(DISTINCT f.id) AS follower_count
FROM public.profiles p
LEFT JOIN public.drops d ON d.creator_id = p.id
LEFT JOIN public.drop_unlocks du ON du.user_id = p.id
LEFT JOIN public.follows f ON f.following_id = p.id
GROUP BY p.id, p.username, p.avatar_url;

-- 2. RPC: who follows the current user ---------------------------------------
-- Distinct from get_mutual_follows (v9) — this is every follower
-- regardless of whether the current user follows them back, for the
-- "Followers" list on the current user's own profile.
CREATE OR REPLACE FUNCTION public.get_followers()
RETURNS TABLE (
  id uuid,
  username text,
  display_name text,
  avatar_url text
)
LANGUAGE sql
STABLE
AS $$
  SELECT p.id, p.username, p.display_name, p.avatar_url
  FROM public.profiles p
  WHERE EXISTS (
    SELECT 1 FROM public.follows f
    WHERE f.follower_id = p.id AND f.following_id = auth.uid()
  )
  ORDER BY p.username;
$$;

-- 3. RPC: the current user's own drops, gallery-ready -------------------------
-- Same shape as user_drops (v7) so it plugs straight into the existing
-- Drop.fromMap parsing, but scoped to "me" only, no lat/lng needed (no
-- distance calculation — just a chronological gallery), and always
-- reports is_unlocked = true since you never need to "unlock" your own
-- drop to see it.
CREATE OR REPLACE FUNCTION public.get_my_drops()
RETURNS TABLE (
  id uuid,
  creator_id uuid,
  creator_username text,
  caption text,
  media_url text,
  media_type text,
  media_size_bytes bigint,
  allow_download boolean,
  media_items jsonb,
  visibility text,
  unlock_radius_m integer,
  distance_m double precision,
  drop_lat double precision,
  drop_lng double precision,
  is_unlocked boolean,
  created_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    d.id,
    d.creator_id,
    p.username AS creator_username,
    d.caption,
    d.media_url,
    d.media_type,
    d.media_size_bytes,
    d.allow_download,
    d.media_items,
    d.visibility,
    d.unlock_radius_m,
    0::double precision AS distance_m,
    ST_Y(d.location::geometry) AS drop_lat,
    ST_X(d.location::geometry) AS drop_lng,
    true AS is_unlocked,
    d.created_at
  FROM public.drops d
  LEFT JOIN public.profiles p ON p.id = d.creator_id
  WHERE d.creator_id = auth.uid()
  ORDER BY d.created_at DESC;
$$;
