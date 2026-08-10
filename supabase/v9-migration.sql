-- ================================================================
-- REALITY MERGE v9 — Mutual follows ("friends") for the new-chat sheet
-- Run this in the Supabase SQL editor after v8-migration.sql
-- ================================================================

-- Returns everyone the current user follows AND who follows the
-- current user back — i.e. a mutual follow, shown as "Friends" when
-- starting a new chat. Same shape as searchUsers() so both can feed
-- the same list UI.
CREATE OR REPLACE FUNCTION public.get_mutual_follows()
RETURNS TABLE (
  id uuid,
  username text,
  display_name text,
  avatar_url text
)
LANGUAGE sql
STABLE
AS $$
  SELECT p.id, p.username, p.display_name, p.avatar_url
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
