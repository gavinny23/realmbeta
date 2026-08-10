-- ================================================================
-- REALITY MERGE v23 — Attached music on drops
-- Run this in the Supabase SQL editor after v22-migration.sql
-- ================================================================
--
-- The composer (create_drop_screen.dart) already lets someone pick and
-- trim a track before posting (MusicPickerSheet / MusicCropScreen),
-- but the clip was never actually saved anywhere — this adds the
-- columns to carry it through, and updates nearby_drops/user_drops to
-- return them so drop_card.dart can play it back.
--
-- Same reveal rule as caption/media_url/media_items: music is only
-- returned once the drop is actually unlocked for the viewer.

ALTER TABLE public.drops
  ADD COLUMN IF NOT EXISTS music_url text,
  ADD COLUMN IF NOT EXISTS music_title text,
  ADD COLUMN IF NOT EXISTS music_artist text,
  ADD COLUMN IF NOT EXISTS music_duration_ms integer;

DROP FUNCTION IF EXISTS public.nearby_drops(double precision, double precision, integer);

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
  music_url text,
  music_title text,
  music_artist text,
  music_duration_ms integer,
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
    CASE WHEN d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.caption ELSE NULL END AS caption,
    CASE WHEN d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.media_url ELSE NULL END AS media_url,
    d.media_type,
    CASE WHEN d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.media_size_bytes ELSE NULL END AS media_size_bytes,
    d.allow_download,
    CASE WHEN d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.media_items ELSE '[]'::jsonb END AS media_items,
    CASE WHEN d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.music_url ELSE NULL END AS music_url,
    CASE WHEN d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.music_title ELSE NULL END AS music_title,
    CASE WHEN d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.music_artist ELSE NULL END AS music_artist,
    CASE WHEN d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.music_duration_ms ELSE NULL END AS music_duration_ms,
    d.visibility,
    d.unlock_radius_m,
    ST_Distance(d.location, ST_SetSRID(ST_MakePoint(user_lng, user_lat), 4326)::geography) AS distance_m,
    ST_Y(d.location::geometry) AS drop_lat,
    ST_X(d.location::geometry) AS drop_lng,
    (d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()) AS is_unlocked,
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

DROP FUNCTION IF EXISTS public.user_drops(uuid, double precision, double precision);

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
  music_url text,
  music_title text,
  music_artist text,
  music_duration_ms integer,
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
    CASE WHEN d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.caption ELSE NULL END AS caption,
    CASE WHEN d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.media_url ELSE NULL END AS media_url,
    d.media_type,
    CASE WHEN d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.media_size_bytes ELSE NULL END AS media_size_bytes,
    d.allow_download,
    CASE WHEN d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.media_items ELSE '[]'::jsonb END AS media_items,
    CASE WHEN d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.music_url ELSE NULL END AS music_url,
    CASE WHEN d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.music_title ELSE NULL END AS music_title,
    CASE WHEN d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.music_artist ELSE NULL END AS music_artist,
    CASE WHEN d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.music_duration_ms ELSE NULL END AS music_duration_ms,
    d.visibility,
    d.unlock_radius_m,
    ST_Distance(d.location, ST_SetSRID(ST_MakePoint(user_lng, user_lat), 4326)::geography) AS distance_m,
    ST_Y(d.location::geometry) AS drop_lat,
    ST_X(d.location::geometry) AS drop_lng,
    (d.visibility = 'public' OR du.id IS NOT NULL OR d.creator_id = auth.uid()) AS is_unlocked,
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
