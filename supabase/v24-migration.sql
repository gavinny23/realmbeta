-- ================================================================
-- REALITY MERGE v24 — "Show in feed" privacy toggle actually persists
-- Run this in the Supabase SQL editor after v23-migration.sql
-- ================================================================
--
-- The Privacy sheet's "Show in feed" switch (profile_screen.dart)
-- was UI-only from the start — it flipped local state on tap but was
-- never included in the load/save round-trip to `profiles`, and this
-- column never existed at all. So every time the sheet was reopened
-- (a fresh widget instance each time), it just reset to its
-- hardcoded `true` default, discarding whatever the person had set —
-- this is the "toggle it on, come back, it's off again" bug.
--
-- This adds the backing column and, since the switch's own label
-- promises "Allow others to see your public drops nearby", also
-- wires it into nearby_drops so turning it off actually hides the
-- person's public drops from *other* people's nearby feed — it never
-- hides your own drops from your own view.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS show_on_map boolean NOT NULL DEFAULT true;

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
    -- New: a drop never shows up in someone ELSE's nearby feed if its
    -- creator has "Show in feed" turned off. Always still visible to
    -- the creator themselves (d.creator_id = auth.uid()), same as
    -- every other privacy flag on this table.
    AND (d.creator_id = auth.uid() OR p.show_on_map)
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
