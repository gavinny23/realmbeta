-- ================================================================
-- REALITY MERGE v17 — Online presence (last-active heartbeat)
-- Run this in the Supabase SQL editor after v16-migration.sql
-- ================================================================
--
-- Adds a single `last_active_at` timestamp on `profiles`, kept fresh
-- by the app calling `touch_presence()` on launch/resume and every
-- ~60s while in the foreground (see PresenceService in the app).
-- Deliberately NOT a boolean `is_online` flag — a boolean needs
-- something to flip it back to false when a session ends uncleanly
-- (app killed, phone dies, network drops), which means either a
-- server-side job or a realtime disconnect hook. A timestamp needs
-- none of that: the client just treats "active within the last couple
-- of minutes" as online and anything older as a "last seen Xm/h/d
-- ago" label, so a stale value naturally ages out into "offline"
-- on its own.
--
-- Every SELECT below follows the same "append last_active_at at the
-- very end of the column list" convention already established for
-- avatar_url (v5) and other columns since — see the comments on
-- v10/v12's profile_stats and list_conversations updates for why:
-- CREATE OR REPLACE FUNCTION/VIEW can only add trailing columns.

-- 1. The column itself -------------------------------------------------------
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS last_active_at timestamptz;

-- Index for anything that ever wants to query "who's online right now"
-- in bulk rather than per-profile (not used yet, but cheap to have).
CREATE INDEX IF NOT EXISTS profiles_last_active_at_idx
  ON public.profiles (last_active_at);

-- 2. RPC: heartbeat ----------------------------------------------------------
CREATE OR REPLACE FUNCTION public.touch_presence()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  UPDATE public.profiles SET last_active_at = now() WHERE id = auth.uid();
$$;

-- 3. profile_stats view -------------------------------------------------------
CREATE OR REPLACE VIEW public.profile_stats AS
SELECT
  p.id AS user_id,
  p.username,
  count(DISTINCT d.id) AS drops_created,
  count(DISTINCT du.drop_id) AS drops_unlocked,
  p.avatar_url,
  count(DISTINCT f.id) AS follower_count,
  p.last_active_at
FROM public.profiles p
LEFT JOIN public.drops d ON d.creator_id = p.id
LEFT JOIN public.drop_unlocks du ON du.user_id = p.id
LEFT JOIN public.follows f ON f.following_id = p.id
GROUP BY p.id, p.username, p.avatar_url, p.last_active_at;

-- 4. get_public_profile RPC ---------------------------------------------------
DROP FUNCTION IF EXISTS public.get_public_profile(uuid);
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
  is_self boolean,
  last_active_at timestamptz
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
    (p.id = auth.uid()) AS is_self,
    p.last_active_at
  FROM public.profiles p
  WHERE p.id = target_user_id;
$$;

-- 5. list_conversations RPC ---------------------------------------------------
DROP FUNCTION IF EXISTS public.list_conversations();
CREATE OR REPLACE FUNCTION public.list_conversations()
RETURNS TABLE (
  other_user_id uuid,
  other_username text,
  other_avatar_url text,
  last_message text,
  last_message_at timestamptz,
  last_sender_id uuid,
  unread_count bigint,
  last_message_read_at timestamptz,
  other_last_active_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  WITH mine AS (
    SELECT
      CASE WHEN sender_id = auth.uid() THEN recipient_id ELSE sender_id END AS other_user_id,
      sender_id,
      content,
      created_at,
      read_at
    FROM public.messages
    WHERE sender_id = auth.uid() OR recipient_id = auth.uid()
  ),
  ranked AS (
    SELECT
      other_user_id,
      sender_id,
      content,
      created_at,
      read_at,
      row_number() OVER (PARTITION BY other_user_id ORDER BY created_at DESC) AS rn
    FROM mine
  )
  SELECT
    r.other_user_id,
    p.username AS other_username,
    p.avatar_url AS other_avatar_url,
    r.content AS last_message,
    r.created_at AS last_message_at,
    r.sender_id AS last_sender_id,
    (
      SELECT count(*) FROM mine m
      WHERE m.other_user_id = r.other_user_id
        AND m.sender_id = r.other_user_id
        AND m.read_at IS NULL
    ) AS unread_count,
    r.read_at AS last_message_read_at,
    p.last_active_at AS other_last_active_at
  FROM ranked r
  JOIN public.profiles p ON p.id = r.other_user_id
  WHERE r.rn = 1
  ORDER BY r.created_at DESC;
$$;

-- 6. get_followers RPC ---------------------------------------------------------
-- Signature changed from v10 (adds last_active_at), so CREATE OR REPLACE
-- can't be used as-is; drop the old one first.
DROP FUNCTION IF EXISTS public.get_followers();
CREATE OR REPLACE FUNCTION public.get_followers()
RETURNS TABLE (
  id uuid,
  username text,
  display_name text,
  avatar_url text,
  last_active_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT p.id, p.username, p.display_name, p.avatar_url, p.last_active_at
  FROM public.profiles p
  WHERE EXISTS (
    SELECT 1 FROM public.follows f
    WHERE f.follower_id = p.id AND f.following_id = auth.uid()
  )
  ORDER BY p.username;
$$;

-- 7. get_mutual_follows RPC -----------------------------------------------------
-- Signature changed from v9 (adds last_active_at), same drop-first fix as above.
DROP FUNCTION IF EXISTS public.get_mutual_follows();
CREATE OR REPLACE FUNCTION public.get_mutual_follows()
RETURNS TABLE (
  id uuid,
  username text,
  display_name text,
  avatar_url text,
  last_active_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT p.id, p.username, p.display_name, p.avatar_url, p.last_active_at
  FROM public.profiles p
  WHERE EXISTS (
    SELECT 1 FROM public.follows f
    WHERE f.follower_id = auth.uid() AND f.following_id = p.id
  )
  AND EXISTS (
    SELECT 1 FROM public.follows f
    WHERE f.follower_id = p.id AND f.following_id = auth.uid()
  )
  ORDER BY p.username;
$$;

-- 8. fetch_status_feed RPC -------------------------------------------------------
DROP FUNCTION IF EXISTS public.fetch_status_feed();
CREATE OR REPLACE FUNCTION public.fetch_status_feed()
RETURNS TABLE (
  creator_id uuid,
  creator_username text,
  creator_avatar_url text,
  status_count bigint,
  all_viewed boolean,
  latest_created_at timestamptz,
  creator_last_active_at timestamptz
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
    max(s.created_at) AS latest_created_at,
    p.last_active_at AS creator_last_active_at
  FROM public.statuses s
  JOIN public.profiles p ON p.id = s.creator_id
  WHERE s.expires_at > now()
  GROUP BY s.creator_id, p.username, p.avatar_url, p.last_active_at
  ORDER BY
    (s.creator_id = auth.uid()) DESC,
    bool_and(EXISTS (
      SELECT 1 FROM public.status_views v
      WHERE v.status_id = s.id AND v.viewer_id = auth.uid()
    )) ASC,
    max(s.created_at) DESC;
$$;

-- 9. get_user_statuses RPC --------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_user_statuses(uuid);
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
  created_at timestamptz,
  creator_last_active_at timestamptz
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
    s.created_at,
    p.last_active_at AS creator_last_active_at
  FROM public.statuses s
  JOIN public.profiles p ON p.id = s.creator_id
  WHERE s.creator_id = target_user_id AND s.expires_at > now()
  ORDER BY s.created_at ASC;
$$;

-- 10. get_status_viewers RPC --------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_status_viewers(uuid);
CREATE OR REPLACE FUNCTION public.get_status_viewers(target_status_id uuid)
RETURNS TABLE (
  viewer_id uuid,
  username text,
  avatar_url text,
  viewed_at timestamptz,
  last_active_at timestamptz
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
    SELECT v.viewer_id, p.username, p.avatar_url, v.viewed_at, p.last_active_at
    FROM public.status_views v
    JOIN public.profiles p ON p.id = v.viewer_id
    WHERE v.status_id = target_status_id
    ORDER BY v.viewed_at DESC;
END;
$$;

-- 11. fetch_flicks RPC -----------------------------------------------------------
DROP FUNCTION IF EXISTS public.fetch_flicks(integer, timestamptz);
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
  created_at timestamptz,
  creator_last_active_at timestamptz
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
    f.created_at,
    p.last_active_at AS creator_last_active_at
  FROM public.flicks f
  JOIN public.profiles p ON p.id = f.creator_id
  WHERE before_created_at IS NULL OR f.created_at < before_created_at
  ORDER BY f.created_at DESC
  LIMIT limit_count;
$$;

-- 12. fetch_flick_comments RPC -----------------------------------------------------
DROP FUNCTION IF EXISTS public.fetch_flick_comments(uuid);
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
  created_at timestamptz,
  last_active_at timestamptz
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
    c.created_at,
    p.last_active_at
  FROM public.flick_comments c
  JOIN public.profiles p ON p.id = c.user_id
  WHERE c.flick_id = target_flick_id AND c.parent_comment_id IS NULL
  ORDER BY c.created_at DESC;
$$;

-- 13. fetch_comment_replies RPC -----------------------------------------------------
DROP FUNCTION IF EXISTS public.fetch_comment_replies(uuid);
CREATE OR REPLACE FUNCTION public.fetch_comment_replies(target_comment_id uuid)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  username text,
  avatar_url text,
  content text,
  like_count bigint,
  is_liked boolean,
  created_at timestamptz,
  last_active_at timestamptz
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
    c.created_at,
    p.last_active_at
  FROM public.flick_comments c
  JOIN public.profiles p ON p.id = c.user_id
  WHERE c.parent_comment_id = target_comment_id
  ORDER BY c.created_at ASC;
$$;
