-- ================================================================
-- REALITY MERGE v8 — Follow/unfollow + per-field profile privacy
-- Run this in the Supabase SQL editor after v7-migration.sql
-- ================================================================

-- 1. Per-field privacy flags on profiles ------------------------------------
-- Each defaults to visible (true) so existing accounts don't suddenly
-- lose profile info they never asked to hide.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS show_home_city boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS show_display_name boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS show_stats boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS allow_discovery boolean NOT NULL DEFAULT true;

-- 2. Follows -----------------------------------------------------------------
-- If a `follows` table already exists from an earlier partial run (or a
-- manually-created placeholder) with a different column layout, plain
-- CREATE TABLE IF NOT EXISTS silently no-ops and every statement below
-- that references follower_id/following_id then fails. Since this is a
-- brand-new feature (no migration before v8 ever created this table),
-- there's no real data to lose — drop and recreate cleanly.
DROP TABLE IF EXISTS public.follows CASCADE;

CREATE TABLE public.follows (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  follower_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  following_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (follower_id, following_id),
  CONSTRAINT follows_no_self_follow CHECK (follower_id <> following_id)
);

CREATE INDEX IF NOT EXISTS follows_follower_idx ON public.follows (follower_id);
CREATE INDEX IF NOT EXISTS follows_following_idx ON public.follows (following_id);

ALTER TABLE public.follows ENABLE ROW LEVEL SECURITY;

-- Follow counts/lists are public, same as everything else profile-shaped.
CREATE POLICY "Follows are viewable by everyone"
  ON public.follows FOR SELECT
  USING (true);

CREATE POLICY "Users can follow as themselves"
  ON public.follows FOR INSERT
  WITH CHECK (auth.uid() = follower_id);

CREATE POLICY "Users can unfollow as themselves"
  ON public.follows FOR DELETE
  USING (auth.uid() = follower_id);

-- 3. RPC: toggle a follow ------------------------------------------------
CREATE OR REPLACE FUNCTION public.toggle_follow(target_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF target_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Cannot follow yourself';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.follows
    WHERE follower_id = auth.uid() AND following_id = target_user_id
  ) THEN
    DELETE FROM public.follows
    WHERE follower_id = auth.uid() AND following_id = target_user_id;
    RETURN false;
  ELSE
    INSERT INTO public.follows (follower_id, following_id)
    VALUES (auth.uid(), target_user_id)
    ON CONFLICT (follower_id, following_id) DO NOTHING;
    RETURN true;
  END IF;
END;
$$;

-- 4. RPC: the public-facing view of a profile --------------------------------
-- Returns exactly what a visitor is allowed to see: display_name,
-- home_city, and the drop-count stats each collapse to NULL unless the
-- owner has that field's `show_*` flag on (or the caller IS the owner,
-- who always sees their own full profile). Enforcing this server-side
-- (rather than just hiding fields client-side) means a private field
-- never leaves the database for anyone but the owner.
CREATE OR REPLACE FUNCTION public.get_public_profile(target_user_id uuid)
RETURNS TABLE (
  user_id uuid,
  username text,
  display_name text,
  home_city text,
  avatar_url text,
  drops_created bigint,
  drops_unlocked bigint,
  follower_count bigint,
  following_count bigint,
  is_following boolean,
  is_self boolean
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    p.id AS user_id,
    p.username,
    CASE WHEN p.show_display_name OR p.id = auth.uid()
      THEN p.display_name ELSE NULL END AS display_name,
    CASE WHEN p.show_home_city OR p.id = auth.uid()
      THEN p.home_city ELSE NULL END AS home_city,
    p.avatar_url,
    CASE WHEN p.show_stats OR p.id = auth.uid()
      THEN (SELECT count(*) FROM public.drops d WHERE d.creator_id = p.id)
      ELSE NULL END AS drops_created,
    CASE WHEN p.show_stats OR p.id = auth.uid()
      THEN (SELECT count(*) FROM public.drop_unlocks du WHERE du.user_id = p.id)
      ELSE NULL END AS drops_unlocked,
    (SELECT count(*) FROM public.follows f WHERE f.following_id = p.id) AS follower_count,
    (SELECT count(*) FROM public.follows f WHERE f.follower_id = p.id) AS following_count,
    EXISTS (
      SELECT 1 FROM public.follows f
      WHERE f.follower_id = auth.uid() AND f.following_id = p.id
    ) AS is_following,
    (p.id = auth.uid()) AS is_self
  FROM public.profiles p
  WHERE p.id = target_user_id;
$$;
