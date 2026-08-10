-- ================================================================
-- REALM v25 — @mention tagging with a per-user "allow tagging" toggle
-- Run this in the Supabase SQL editor after v24-migration.sql
-- ================================================================

-- 1. Tagging preference on profiles ------------------------------------------
-- Defaults to true so existing accounts keep working the way they always
-- have; anyone who doesn't want to be @mentioned can flip this off in
-- Privacy settings, same pattern as allow_discovery below it.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS allow_tagging boolean NOT NULL DEFAULT true;

-- 2. Mentionable-user search ---------------------------------------------------
-- Backs the @mention autocomplete dropdown. Deliberately narrower than
-- a plain username search: it excludes anyone who has turned off
-- "Allow tagging", so a name never even appears as a suggestion (and
-- therefore never resolves into a highlighted, valid mention) unless
-- that person has opted in. Also respects allow_discovery, same as the
-- existing username search, so a user who's hidden from search
-- entirely can't be found through mentions either.
CREATE OR REPLACE FUNCTION public.search_mentionable_users(search_query text)
RETURNS TABLE (
  id uuid,
  username text,
  display_name text,
  avatar_url text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p.id, p.username, p.display_name, p.avatar_url
  FROM public.profiles p
  WHERE p.username ILIKE search_query || '%'
    AND p.allow_discovery = true
    AND p.allow_tagging = true
    AND p.id <> auth.uid()
  ORDER BY p.username ASC
  LIMIT 6;
$$;

GRANT EXECUTE ON FUNCTION public.search_mentionable_users(text) TO authenticated;
