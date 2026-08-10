-- ================================================================
-- REALITY MERGE v6 — "Specific people" visibility + Flicks
-- Run this in the Supabase SQL editor after v5-migration.sql
-- ================================================================

-- 1. Allow a third visibility mode: 'custom' -----------------------------
-- Previously 'private' did double duty as both "just me" and "me + an
-- allowlist of specific people", which forced every private drop to
-- have at least one person added to it. Now:
--   public  -> anyone nearby
--   private -> only the creator, ever
--   custom  -> the creator + whoever is on the drop_access allowlist
ALTER TABLE public.drops
  DROP CONSTRAINT IF EXISTS drops_visibility_check;

ALTER TABLE public.drops
  ADD CONSTRAINT drops_visibility_check
    CHECK (visibility IN ('public', 'private', 'custom'));

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
      -- Public drops visible to everyone
      d.visibility = 'public'
      -- Creator always sees their own drops, of any visibility
      OR d.creator_id = auth.uid()
      -- 'custom' drops are visible to whoever is on the allowlist.
      -- 'private' drops are never visible to anyone but the creator.
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

CREATE OR REPLACE FUNCTION public.attempt_unlock(
  target_drop_id uuid,
  user_lat double precision,
  user_lng double precision
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  drop_record public.drops;
  distance_m double precision;
BEGIN
  SELECT * INTO drop_record FROM public.drops WHERE id = target_drop_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Drop not found';
  END IF;

  -- 'private' drops can only ever be unlocked by their creator.
  IF drop_record.visibility = 'private' AND drop_record.creator_id != auth.uid() THEN
    RETURN false;
  END IF;

  -- 'custom' drops need the caller to be on the allowlist.
  IF drop_record.visibility = 'custom' AND drop_record.creator_id != auth.uid() THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.drop_access
      WHERE drop_id = target_drop_id AND granted_to = auth.uid()
    ) THEN
      RETURN false; -- not on allowlist
    END IF;
  END IF;

  -- Check proximity
  distance_m := ST_Distance(
    drop_record.location,
    ST_SetSRID(ST_MakePoint(user_lng, user_lat), 4326)::geography
  );

  IF distance_m > drop_record.unlock_radius_m THEN
    RETURN false; -- too far
  END IF;

  INSERT INTO public.drop_unlocks (user_id, drop_id)
  VALUES (auth.uid(), target_drop_id)
  ON CONFLICT (user_id, drop_id) DO NOTHING;

  RETURN true;
END;
$$;

-- ================================================================
-- 2. Flicks — short, vertical, swipeable video clips (30s max),
--    independent of location. Videos reuse the existing `drop-media`
--    storage bucket (same per-user folder convention as drop
--    attachments), so no new bucket/storage policies are needed here.
-- ================================================================

CREATE TABLE IF NOT EXISTS public.flicks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  caption text CHECK (char_length(caption) <= 500),
  video_url text NOT NULL,
  thumb_url text,
  duration_seconds integer NOT NULL CHECK (duration_seconds > 0 AND duration_seconds <= 30),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS flicks_created_idx ON public.flicks (created_at DESC);
CREATE INDEX IF NOT EXISTS flicks_creator_idx ON public.flicks (creator_id);

ALTER TABLE public.flicks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Flicks are viewable by everyone"
  ON public.flicks FOR SELECT
  USING (true);

CREATE POLICY "Users can create their own flicks"
  ON public.flicks FOR INSERT
  WITH CHECK (auth.uid() = creator_id);

CREATE POLICY "Users can delete their own flicks"
  ON public.flicks FOR DELETE
  USING (auth.uid() = creator_id);

-- 2a. Likes on a flick itself -----------------------------------------------
CREATE TABLE IF NOT EXISTS public.flick_likes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flick_id uuid NOT NULL REFERENCES public.flicks(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (flick_id, user_id)
);

CREATE INDEX IF NOT EXISTS flick_likes_flick_idx ON public.flick_likes (flick_id);

ALTER TABLE public.flick_likes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Flick likes are viewable by everyone"
  ON public.flick_likes FOR SELECT
  USING (true);

CREATE POLICY "Users can like as themselves"
  ON public.flick_likes FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can remove their own flick like"
  ON public.flick_likes FOR DELETE
  USING (auth.uid() = user_id);

-- 2b. Comments (+ one level of replies via parent_comment_id) ---------------
CREATE TABLE IF NOT EXISTS public.flick_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flick_id uuid NOT NULL REFERENCES public.flicks(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  parent_comment_id uuid REFERENCES public.flick_comments(id) ON DELETE CASCADE,
  content text NOT NULL CHECK (char_length(content) <= 500),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS flick_comments_flick_idx
  ON public.flick_comments (flick_id, created_at DESC)
  WHERE parent_comment_id IS NULL;
CREATE INDEX IF NOT EXISTS flick_comments_parent_idx
  ON public.flick_comments (parent_comment_id);

ALTER TABLE public.flick_comments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Flick comments are viewable by everyone"
  ON public.flick_comments FOR SELECT
  USING (true);

CREATE POLICY "Users can comment as themselves"
  ON public.flick_comments FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete their own comment"
  ON public.flick_comments FOR DELETE
  USING (auth.uid() = user_id);

-- 2c. Likes on a comment -----------------------------------------------------
CREATE TABLE IF NOT EXISTS public.flick_comment_likes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  comment_id uuid NOT NULL REFERENCES public.flick_comments(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (comment_id, user_id)
);

CREATE INDEX IF NOT EXISTS flick_comment_likes_comment_idx
  ON public.flick_comment_likes (comment_id);

ALTER TABLE public.flick_comment_likes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Comment likes are viewable by everyone"
  ON public.flick_comment_likes FOR SELECT
  USING (true);

CREATE POLICY "Users can like a comment as themselves"
  ON public.flick_comment_likes FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can remove their own comment like"
  ON public.flick_comment_likes FOR DELETE
  USING (auth.uid() = user_id);

-- 2d. RPC: paginated flick feed, newest first --------------------------------
CREATE OR REPLACE FUNCTION public.fetch_flicks(
  limit_count integer DEFAULT 20,
  before_created_at timestamptz DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  creator_id uuid,
  creator_username text,
  creator_avatar_url text,
  caption text,
  video_url text,
  thumb_url text,
  duration_seconds integer,
  like_count bigint,
  comment_count bigint,
  is_liked boolean,
  created_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    f.id,
    f.creator_id,
    p.username AS creator_username,
    p.avatar_url AS creator_avatar_url,
    f.caption,
    f.video_url,
    f.thumb_url,
    f.duration_seconds,
    (SELECT count(*) FROM public.flick_likes fl WHERE fl.flick_id = f.id) AS like_count,
    (SELECT count(*) FROM public.flick_comments fc WHERE fc.flick_id = f.id) AS comment_count,
    EXISTS (
      SELECT 1 FROM public.flick_likes fl
      WHERE fl.flick_id = f.id AND fl.user_id = auth.uid()
    ) AS is_liked,
    f.created_at
  FROM public.flicks f
  JOIN public.profiles p ON p.id = f.creator_id
  WHERE before_created_at IS NULL OR f.created_at < before_created_at
  ORDER BY f.created_at DESC
  LIMIT limit_count;
$$;

-- 2e. RPC: toggle a like on a flick -------------------------------------------
CREATE OR REPLACE FUNCTION public.toggle_flick_like(target_flick_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.flick_likes
    WHERE flick_id = target_flick_id AND user_id = auth.uid()
  ) THEN
    DELETE FROM public.flick_likes
    WHERE flick_id = target_flick_id AND user_id = auth.uid();
    RETURN false;
  ELSE
    INSERT INTO public.flick_likes (flick_id, user_id)
    VALUES (target_flick_id, auth.uid())
    ON CONFLICT (flick_id, user_id) DO NOTHING;
    RETURN true;
  END IF;
END;
$$;

-- 2f. RPC: top-level comments for a flick, newest first ----------------------
CREATE OR REPLACE FUNCTION public.fetch_flick_comments(target_flick_id uuid)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  username text,
  avatar_url text,
  content text,
  like_count bigint,
  is_liked boolean,
  reply_count bigint,
  created_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    c.id,
    c.user_id,
    p.username,
    p.avatar_url,
    c.content,
    (SELECT count(*) FROM public.flick_comment_likes l WHERE l.comment_id = c.id) AS like_count,
    EXISTS (
      SELECT 1 FROM public.flick_comment_likes l
      WHERE l.comment_id = c.id AND l.user_id = auth.uid()
    ) AS is_liked,
    (SELECT count(*) FROM public.flick_comments r WHERE r.parent_comment_id = c.id) AS reply_count,
    c.created_at
  FROM public.flick_comments c
  JOIN public.profiles p ON p.id = c.user_id
  WHERE c.flick_id = target_flick_id AND c.parent_comment_id IS NULL
  ORDER BY c.created_at DESC;
$$;

-- 2g. RPC: replies to a single comment, oldest first --------------------------
CREATE OR REPLACE FUNCTION public.fetch_comment_replies(target_comment_id uuid)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  username text,
  avatar_url text,
  content text,
  like_count bigint,
  is_liked boolean,
  created_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    c.id,
    c.user_id,
    p.username,
    p.avatar_url,
    c.content,
    (SELECT count(*) FROM public.flick_comment_likes l WHERE l.comment_id = c.id) AS like_count,
    EXISTS (
      SELECT 1 FROM public.flick_comment_likes l
      WHERE l.comment_id = c.id AND l.user_id = auth.uid()
    ) AS is_liked,
    c.created_at
  FROM public.flick_comments c
  JOIN public.profiles p ON p.id = c.user_id
  WHERE c.parent_comment_id = target_comment_id
  ORDER BY c.created_at ASC;
$$;

-- 2h. RPC: add a comment or a reply (parent_comment_id NULL = top-level) -----
CREATE OR REPLACE FUNCTION public.add_flick_comment(
  target_flick_id uuid,
  comment_content text,
  parent_comment_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  new_id uuid;
BEGIN
  IF parent_comment_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.flick_comments
      WHERE id = parent_comment_id AND flick_id = target_flick_id
    ) THEN
      RAISE EXCEPTION 'Parent comment does not belong to this flick';
    END IF;
  END IF;

  INSERT INTO public.flick_comments (flick_id, user_id, parent_comment_id, content)
  VALUES (target_flick_id, auth.uid(), parent_comment_id, comment_content)
  RETURNING id INTO new_id;

  RETURN new_id;
END;
$$;

-- 2i. RPC: toggle a like on a comment or reply --------------------------------
CREATE OR REPLACE FUNCTION public.toggle_comment_like(target_comment_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.flick_comment_likes
    WHERE comment_id = target_comment_id AND user_id = auth.uid()
  ) THEN
    DELETE FROM public.flick_comment_likes
    WHERE comment_id = target_comment_id AND user_id = auth.uid();
    RETURN false;
  ELSE
    INSERT INTO public.flick_comment_likes (comment_id, user_id)
    VALUES (target_comment_id, auth.uid())
    ON CONFLICT (comment_id, user_id) DO NOTHING;
    RETURN true;
  END IF;
END;
$$;
