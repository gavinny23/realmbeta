-- ================================================================
-- REALITY MERGE v11 — Status sharing (WhatsApp/IG-style disappearing
-- posts, 12h lifespan)
-- Run this in the Supabase SQL editor after v10-migration.sql
-- ================================================================

-- 1. Statuses ---------------------------------------------------------------
-- A status is a single photo or short video that's only ever visible
-- for STATUS_LIFESPAN after it's posted. `expires_at` is set by its
-- own DEFAULT (evaluated at insert time, same as `created_at`) rather
-- than as a GENERATED column — Postgres requires generated-column
-- expressions to be IMMUTABLE, and the timestamptz + interval operator
-- is only STABLE, so `GENERATED ALWAYS AS (created_at + interval ...)`
-- fails with "42P17: generation expression is not immutable" even
-- though the interval itself is a fixed duration. A same-transaction
-- DEFAULT has no such restriction and lands within the same instant.
--
-- NOTE: the "12 hours" lifespan appears in exactly one place below
-- (the expires_at default). Change it there if it ever needs to move
-- — nowhere else in this migration hardcodes it.
CREATE TABLE IF NOT EXISTS public.statuses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  media_url text NOT NULL,
  media_type text NOT NULL CHECK (media_type IN ('photo', 'video')),
  caption text CHECK (char_length(caption) <= 280),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '12 hours')
);

CREATE INDEX IF NOT EXISTS statuses_creator_idx ON public.statuses (creator_id);
-- Powers "only ever fetch what hasn't expired yet" efficiently instead
-- of a full-table scan re-checking every row's timestamp.
CREATE INDEX IF NOT EXISTS statuses_expires_idx ON public.statuses (expires_at);

ALTER TABLE public.statuses ENABLE ROW LEVEL SECURITY;

-- The expiry check lives in the policy itself, not just in the RPCs
-- below — so even a direct PostgREST select can never return an
-- expired status.
CREATE POLICY "Active statuses are viewable by everyone"
  ON public.statuses FOR SELECT
  USING (expires_at > now());

CREATE POLICY "Users can post their own status"
  ON public.statuses FOR INSERT
  WITH CHECK (auth.uid() = creator_id);

CREATE POLICY "Users can delete their own status early"
  ON public.statuses FOR DELETE
  USING (auth.uid() = creator_id);

-- 2. Status views -------------------------------------------------------------
-- One row per (status, viewer) — powers both the "seen"/unviewed ring
-- in the strip and the "N viewers" list a creator sees on their own
-- status.
CREATE TABLE IF NOT EXISTS public.status_views (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  status_id uuid NOT NULL REFERENCES public.statuses(id) ON DELETE CASCADE,
  viewer_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  viewed_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (status_id, viewer_id)
);

CREATE INDEX IF NOT EXISTS status_views_status_idx ON public.status_views (status_id);
CREATE INDEX IF NOT EXISTS status_views_viewer_idx ON public.status_views (viewer_id);

ALTER TABLE public.status_views ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Status views are viewable by everyone"
  ON public.status_views FOR SELECT
  USING (true);

CREATE POLICY "Users can record their own view"
  ON public.status_views FOR INSERT
  WITH CHECK (auth.uid() = viewer_id);

-- 3. RPC: the strip feed — one row per creator with an active status --------
-- Ordered so the current user's own entry always leads, then whoever
-- has something you haven't seen yet, then everyone else by most
-- recent post — same "your stuff first, unseen next" convention as
-- most story strips.
CREATE OR REPLACE FUNCTION public.fetch_status_feed()
RETURNS TABLE (
  creator_id uuid,
  creator_username text,
  creator_avatar_url text,
  status_count bigint,
  all_viewed boolean,
  latest_created_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    s.creator_id,
    p.username AS creator_username,
    p.avatar_url AS creator_avatar_url,
    count(*) AS status_count,
    bool_and(EXISTS (
      SELECT 1 FROM public.status_views v
      WHERE v.status_id = s.id AND v.viewer_id = auth.uid()
    )) AS all_viewed,
    max(s.created_at) AS latest_created_at
  FROM public.statuses s
  JOIN public.profiles p ON p.id = s.creator_id
  WHERE s.expires_at > now()
  GROUP BY s.creator_id, p.username, p.avatar_url
  ORDER BY
    (s.creator_id = auth.uid()) DESC,
    bool_and(EXISTS (
      SELECT 1 FROM public.status_views v
      WHERE v.status_id = s.id AND v.viewer_id = auth.uid()
    )) ASC,
    max(s.created_at) DESC;
$$;

-- 4. RPC: one creator's active statuses, oldest first (story order) ---------
CREATE OR REPLACE FUNCTION public.get_user_statuses(target_user_id uuid)
RETURNS TABLE (
  id uuid,
  creator_id uuid,
  creator_username text,
  creator_avatar_url text,
  media_url text,
  media_type text,
  caption text,
  view_count bigint,
  is_viewed_by_me boolean,
  created_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    s.id,
    s.creator_id,
    p.username AS creator_username,
    p.avatar_url AS creator_avatar_url,
    s.media_url,
    s.media_type,
    s.caption,
    (SELECT count(*) FROM public.status_views v WHERE v.status_id = s.id) AS view_count,
    EXISTS (
      SELECT 1 FROM public.status_views v
      WHERE v.status_id = s.id AND v.viewer_id = auth.uid()
    ) AS is_viewed_by_me,
    s.created_at
  FROM public.statuses s
  JOIN public.profiles p ON p.id = s.creator_id
  WHERE s.creator_id = target_user_id AND s.expires_at > now()
  ORDER BY s.created_at ASC;
$$;

-- 5. RPC: mark a status viewed by the current user ---------------------------
CREATE OR REPLACE FUNCTION public.mark_status_viewed(target_status_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  INSERT INTO public.status_views (status_id, viewer_id)
  VALUES (target_status_id, auth.uid())
  ON CONFLICT (status_id, viewer_id) DO NOTHING;
$$;

-- 6. RPC: who has viewed one of *my* statuses --------------------------------
-- Scoped to the creator themselves — nobody else needs (or gets) the
-- list of who watched somebody else's status.
CREATE OR REPLACE FUNCTION public.get_status_viewers(target_status_id uuid)
RETURNS TABLE (
  viewer_id uuid,
  username text,
  avatar_url text,
  viewed_at timestamptz
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.statuses
    WHERE id = target_status_id AND creator_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not authorized to view this status''s viewers';
  END IF;

  RETURN QUERY
    SELECT v.viewer_id, p.username, p.avatar_url, v.viewed_at
    FROM public.status_views v
    JOIN public.profiles p ON p.id = v.viewer_id
    WHERE v.status_id = target_status_id
    ORDER BY v.viewed_at DESC;
END;
$$;
