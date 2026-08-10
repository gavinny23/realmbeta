-- ================================================================
-- REALITY MERGE v22 — Public drops skip the proximity gate; redrops
-- for Drops (not just News)
-- Run this in the Supabase SQL editor after v21-migration.sql
-- ================================================================
--
-- 1. Public drops no longer require a proximity unlock.
-- --------------------------------------------------------------
-- Until now, `visibility` only ever controlled *who was allowed to
-- attempt* an unlock (public = anyone, private = only the creator,
-- custom = the allowlist) — everyone still had to walk into
-- unlock_radius_m and call attempt_unlock() before caption/media
-- revealed, regardless of visibility. That's the right model for
-- private/custom drops (the whole point is "you have to actually be
-- here"), but it no longer makes sense for public ones — a public
-- drop is meant to be visible to everyone immediately, no padlock,
-- no walking required. The unlock radius stays meaningful only for
-- private/custom drops now (see the client's create_drop_screen.dart
-- change alongside this migration, which only shows the radius
-- slider for those two).
--
-- is_unlocked (and the caption/media/media_items reveal) is now true
-- unconditionally for `visibility = 'public'`, in addition to the
-- existing "you unlocked it" / "you created it" cases.

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

-- 2. Drop redrops (Explore feed) ---------------------------------
-- --------------------------------------------------------------
-- Same shape and rules as news_redrops (v16) — a redrop is a
-- lightweight, permanent record that a user reposted a Drop to their
-- own audience, with an optional short requote. One redrop per
-- (user, drop); redropping again just updates the requote rather
-- than stacking duplicate rows. Only ever created against a drop the
-- redropper can currently see (enforced client-side by only showing
-- the button on an unlocked card — RLS below doesn't re-derive
-- visibility, same as how news_redrops doesn't re-check story access
-- since syndicated stories have no access control of their own).

CREATE TABLE IF NOT EXISTS public.drop_redrops (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  drop_id uuid NOT NULL REFERENCES public.drops(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  quote text CHECK (char_length(quote) <= 280),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, drop_id)
);

CREATE INDEX IF NOT EXISTS drop_redrops_drop_idx
  ON public.drop_redrops (drop_id, created_at DESC);

ALTER TABLE public.drop_redrops ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Drop redrops are viewable by everyone"
  ON public.drop_redrops FOR SELECT
  USING (true);

CREATE POLICY "Users can create their own drop redrops"
  ON public.drop_redrops FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own drop redrops"
  ON public.drop_redrops FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Users can delete their own drop redrops"
  ON public.drop_redrops FOR DELETE
  USING (auth.uid() = user_id);

-- Redrop count per drop, used next to the like/comment counts on the
-- card without pulling every redrop row down first.
CREATE OR REPLACE FUNCTION public.drop_redrop_count(target_drop_id uuid)
RETURNS bigint
LANGUAGE sql
STABLE
AS $$
  SELECT count(*) FROM public.drop_redrops WHERE drop_id = target_drop_id;
$$;

ALTER PUBLICATION supabase_realtime ADD TABLE public.drop_redrops;
