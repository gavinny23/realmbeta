-- ================================================================
-- REALITY MERGE v13 — Fix is_unlocked for a drop's own creator
-- Run this in the Supabase SQL editor after v12-migration.sql
-- ================================================================
--
-- Bug: nearby_drops() and user_drops() already reveal a drop's
-- caption/media to its own creator (`OR d.creator_id = auth.uid()`
-- in the CASE expressions), but the separate `is_unlocked` column
-- was only ever `du.id IS NOT NULL` — true if a drop_unlocks row
-- exists, which nothing ever inserts for the creator (attempt_unlock
-- is only called by someone physically walking up to a drop). Two
-- visible symptoms:
--
--   1. A brand-new PUBLIC drop didn't show up in its own creator's
--      Explore feed, because the feed only lists is_unlocked drops
--      (see feed_screen.dart _visibleDrops) — you had to go re-walk
--      up to your own drop to make it "unlock" before it appeared.
--   2. A PRIVATE drop (visible only ever to its creator) always
--      rendered as a blurred "Locked drop" on the Compass tab, even
--      though the payload already carried its real caption/media.
--
-- Fix: is_unlocked is true whenever you're the creator too, matching
-- the reveal rule already used for caption/media. Function bodies
-- only — return signatures are unchanged, so no DROP FUNCTION needed.

CREATE OR REPLACE FUNCTION public.nearby_drops(
  user_lat double precision,
  user_lng double precision,
  radius_m integer DEFAULT 2000
)
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
    CASE WHEN du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.caption ELSE NULL END AS caption,
    CASE WHEN du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.media_url ELSE NULL END AS media_url,
    d.media_type,
    CASE WHEN du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.media_size_bytes ELSE NULL END AS media_size_bytes,
    d.allow_download,
    CASE WHEN du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.media_items ELSE '[]'::jsonb END AS media_items,
    d.visibility,
    d.unlock_radius_m,
    ST_Distance(d.location, ST_SetSRID(ST_MakePoint(user_lng, user_lat), 4326)::geography) AS distance_m,
    ST_Y(d.location::geometry) AS drop_lat,
    ST_X(d.location::geometry) AS drop_lng,
    (du.id IS NOT NULL OR d.creator_id = auth.uid()) AS is_unlocked,
    d.created_at
  FROM public.drops d
  LEFT JOIN public.profiles p ON p.id = d.creator_id
  LEFT JOIN public.drop_unlocks du
    ON du.drop_id = d.id AND du.user_id = auth.uid()
  WHERE
    ST_DWithin(
      d.location,
      ST_SetSRID(ST_MakePoint(user_lng, user_lat), 4326)::geography,
      radius_m
    )
    AND (
      d.visibility = 'public'
      OR d.creator_id = auth.uid()
      OR (
        d.visibility = 'custom'
        AND EXISTS (
          SELECT 1 FROM public.drop_access da
          WHERE da.drop_id = d.id AND da.granted_to = auth.uid()
        )
      )
    )
  ORDER BY distance_m ASC;
$$;

CREATE OR REPLACE FUNCTION public.user_drops(
  target_user_id uuid,
  user_lat double precision,
  user_lng double precision
)
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
    CASE WHEN du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.caption ELSE NULL END AS caption,
    CASE WHEN du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.media_url ELSE NULL END AS media_url,
    d.media_type,
    CASE WHEN du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.media_size_bytes ELSE NULL END AS media_size_bytes,
    d.allow_download,
    CASE WHEN du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.media_items ELSE '[]'::jsonb END AS media_items,
    d.visibility,
    d.unlock_radius_m,
    ST_Distance(d.location, ST_SetSRID(ST_MakePoint(user_lng, user_lat), 4326)::geography) AS distance_m,
    ST_Y(d.location::geometry) AS drop_lat,
    ST_X(d.location::geometry) AS drop_lng,
    (du.id IS NOT NULL OR d.creator_id = auth.uid()) AS is_unlocked,
    d.created_at
  FROM public.drops d
  LEFT JOIN public.profiles p ON p.id = d.creator_id
  LEFT JOIN public.drop_unlocks du
    ON du.drop_id = d.id AND du.user_id = auth.uid()
  WHERE
    d.creator_id = target_user_id
    AND (
      d.visibility = 'public'
      OR d.creator_id = auth.uid()
      OR (
        d.visibility = 'custom'
        AND EXISTS (
          SELECT 1 FROM public.drop_access da
          WHERE da.drop_id = d.id AND da.granted_to = auth.uid()
        )
      )
    )
  ORDER BY distance_m ASC;
$$;
