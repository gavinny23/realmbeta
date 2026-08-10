-- ================================================================
-- REALITY MERGE v2 — Migration SQL
-- Run this in the Supabase SQL editor (in addition to schema.sql)
-- ================================================================

-- 1. Add FCM token column to profiles for push notifications
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS fcm_token text;

-- 2. Fix drop_interactions unique constraint to allow multiple comments
--    The v1 constraint blocked more than one comment per user per drop.
--    Drop it and replace with a partial unique index for likes only.
ALTER TABLE public.drop_interactions
  DROP CONSTRAINT IF EXISTS drop_interactions_user_id_drop_id_type_key;

CREATE UNIQUE INDEX IF NOT EXISTS drop_interactions_one_like_per_user
  ON public.drop_interactions (user_id, drop_id)
  WHERE type = 'like';

-- 3. Re-run the updated nearby_drops RPC (now returns drop_lat, drop_lng)
--    Copy the full updated function from schema.sql and run it here,
--    or just run the CREATE OR REPLACE portion below:

CREATE OR REPLACE FUNCTION public.nearby_drops(
  user_lat double precision,
  user_lng double precision,
  radius_m integer default 2000
)
RETURNS TABLE (
  id uuid,
  creator_id uuid,
  creator_username text,
  caption text,
  media_url text,
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
    d.unlock_radius_m,
    ST_Distance(d.location, ST_SetSRID(ST_MakePoint(user_lng, user_lat), 4326)::geography) AS distance_m,
    ST_Y(d.location::geometry) AS drop_lat,
    ST_X(d.location::geometry) AS drop_lng,
    (du.id IS NOT NULL) AS is_unlocked,
    d.created_at
  FROM public.drops d
  LEFT JOIN public.profiles p ON p.id = d.creator_id
  LEFT JOIN public.drop_unlocks du
    ON du.drop_id = d.id AND du.user_id = auth.uid()
  WHERE ST_DWithin(
    d.location,
    ST_SetSRID(ST_MakePoint(user_lng, user_lat), 4326)::geography,
    radius_m
  )
  ORDER BY distance_m ASC;
$$;
