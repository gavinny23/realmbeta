-- ================================================================
-- REALITY MERGE v20 — Dev Hub: repo browsing, in-app commit, and the
-- cross-user "what everyone's building" feed
-- Run this in the Supabase SQL editor after v19-migration.sql
-- ================================================================

-- 1. dev_hub_builds ----------------------------------------------------------
-- One row per commit made through the Dev Hub's in-app editor. This is
-- purely a feed record — the actual commit already happened against
-- GitHub itself via the Contents API before this row is written; this
-- table just lets other Realm users see "what you're building" without
-- everyone needing to follow each other on GitHub too.
CREATE TABLE IF NOT EXISTS public.dev_hub_builds (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  repo_full_name text NOT NULL,
  repo_html_url text NOT NULL,
  file_path text NOT NULL,
  commit_message text NOT NULL CHECK (char_length(commit_message) <= 280),
  commit_url text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS dev_hub_builds_creator_idx ON public.dev_hub_builds (creator_id);
-- Powers the feed's newest-first, keyset-paginated read below.
CREATE INDEX IF NOT EXISTS dev_hub_builds_created_idx ON public.dev_hub_builds (created_at DESC);

ALTER TABLE public.dev_hub_builds ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Builds are viewable by everyone"
  ON public.dev_hub_builds FOR SELECT
  USING (true);

CREATE POLICY "Users can share their own builds"
  ON public.dev_hub_builds FOR INSERT
  WITH CHECK (auth.uid() = creator_id);

CREATE POLICY "Users can delete their own build posts"
  ON public.dev_hub_builds FOR DELETE
  USING (auth.uid() = creator_id);

-- 2. fetch_dev_hub_feed RPC ---------------------------------------------------
-- Same shape/pagination convention as fetch_flicks (v6/v17): newest
-- first, keyset-paginated on created_at.
CREATE OR REPLACE FUNCTION public.fetch_dev_hub_feed(
  limit_count integer DEFAULT 30,
  before_created_at timestamptz DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  creator_id uuid,
  creator_username text,
  creator_avatar_url text,
  repo_full_name text,
  repo_html_url text,
  file_path text,
  commit_message text,
  commit_url text,
  created_at timestamptz,
  creator_last_active_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    b.id,
    b.creator_id,
    p.username AS creator_username,
    p.avatar_url AS creator_avatar_url,
    b.repo_full_name,
    b.repo_html_url,
    b.file_path,
    b.commit_message,
    b.commit_url,
    b.created_at,
    p.last_active_at AS creator_last_active_at
  FROM public.dev_hub_builds b
  JOIN public.profiles p ON p.id = b.creator_id
  WHERE before_created_at IS NULL OR b.created_at < before_created_at
  ORDER BY b.created_at DESC
  LIMIT limit_count;
$$;
