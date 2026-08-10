-- ================================================================
-- REALITY MERGE v3 — Multi-file attachments + download permission
-- Run this in the Supabase SQL editor after v2.1-migration.sql
-- ================================================================

-- 1. New columns on drops -----------------------------------------------
-- media_size_bytes: size of the primary (first) attachment, used for
--   quick badges (AR chip / map sheet) without needing the full list.
-- allow_download: creator's choice of whether others may download the
--   attached media from the drop detail screen.
-- media_items: full list of attachments for this drop (photos, videos,
--   documents — a drop can now carry more than one file). Each element:
--   { "url": text, "type": "photo"|"video"|"document",
--     "size_bytes": bigint, "name": text, "thumb_url": text|null }
--   thumb_url (added later, client-side only — no migration needed since
--   this column is jsonb) holds a small static JPEG frame for videos, so
--   the feed can show a lightweight image instead of a real video player.
-- media_url/media_type stay in sync with media_items[0] for backward
-- compatibility with anything still reading the single-media fields.
ALTER TABLE public.drops
  ADD COLUMN IF NOT EXISTS media_size_bytes bigint,
  ADD COLUMN IF NOT EXISTS allow_download boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS media_items jsonb NOT NULL DEFAULT '[]'::jsonb;

-- 2. Update nearby_drops RPC to return the new fields --------------------
-- Same visibility rule as before: media is only revealed to the creator
-- or someone who has actually unlocked the drop.
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
    (du.id IS NOT NULL) AS is_unlocked,
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
      OR EXISTS (
        SELECT 1 FROM public.drop_access da
        WHERE da.drop_id = d.id AND da.granted_to = auth.uid()
      )
    )
  ORDER BY distance_m ASC;
$$;
