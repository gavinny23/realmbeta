-- ================================================================
-- REALITY MERGE v7 — Discover a user's drops via profile search
-- Run this in the Supabase SQL editor after v6-migration.sql
-- ================================================================
--
-- The Explore feed now only shows already-unlocked drops (see the
-- client change alongside this migration) so new users aren't
-- greeted with a wall of blurred, locked cards. Locked drops are
-- still fully discoverable on purpose: search for the person who
-- left them and open their profile, which lists every drop they've
-- made (locked ones included, with distance) via this RPC.

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
  -- Same reveal rules as nearby_drops (caption/media only visible to
  -- the creator or someone who has actually unlocked the drop) and the
  -- same visibility rules (public everyone, custom only the allowlist,
  -- private only the creator) — this just swaps "within radius_m of
  -- me" for "made by this one person", with no distance cutoff, so a
  -- searched user's locked drops still show up however far away they are.
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
