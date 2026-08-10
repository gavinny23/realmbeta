-- ================================================================
-- REALITY MERGE v34 — Chat profile sheet: block, report, hide status
-- Run this in the Supabase SQL editor after v33-migration.sql
--
-- Backs the new "tap the avatar in a DM" screen: View profile /
-- Hide your online status from this person / Block & report.
-- ================================================================

-- 1. user_blocks -----------------------------------------------------------
-- One-directional: blocker_id no longer wants blocked_id to be able to
-- message them, and doesn't want to see them in the chat list either.
create table if not exists public.user_blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint user_blocks_no_self check (blocker_id <> blocked_id)
);

alter table public.user_blocks enable row level security;

-- Only the blocker can see their own block list — the blocked person
-- isn't told who blocked them, same as most chat apps.
create policy "Users manage their own blocks"
  on public.user_blocks for all
  using (auth.uid() = blocker_id)
  with check (auth.uid() = blocker_id);

-- 2. hidden_presence ---------------------------------------------------------
-- user_id no longer wants hidden_from_id to see their online/last-active
-- status. Purely one-directional and independent of blocking — you can
-- hide your status from a friend without blocking them.
create table if not exists public.hidden_presence (
  user_id uuid not null references public.profiles(id) on delete cascade,
  hidden_from_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, hidden_from_id),
  constraint hidden_presence_no_self check (user_id <> hidden_from_id)
);

alter table public.hidden_presence enable row level security;

create policy "Users manage their own hidden-status list"
  on public.hidden_presence for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- 3. user_reports ------------------------------------------------------------
-- Write-only from the client's side: a report can be filed and later
-- read back by its author, but never edited or withdrawn once sent.
create table if not exists public.user_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reported_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null,
  details text,
  created_at timestamptz not null default now(),
  constraint user_reports_no_self check (reporter_id <> reported_id)
);

create index if not exists user_reports_reported_idx on public.user_reports (reported_id);

alter table public.user_reports enable row level security;

create policy "Users can file reports"
  on public.user_reports for insert
  with check (auth.uid() = reporter_id);

create policy "Users can see their own filed reports"
  on public.user_reports for select
  using (auth.uid() = reporter_id);

-- 4. Messages: a block in either direction stops new messages -------------
drop policy if exists "Users can send messages as themselves" on public.messages;
create policy "Users can send messages as themselves"
  on public.messages for insert
  with check (
    auth.uid() = sender_id
    and not exists (
      select 1 from public.user_blocks b
      where (b.blocker_id = sender_id and b.blocked_id = recipient_id)
         or (b.blocker_id = recipient_id and b.blocked_id = sender_id)
    )
  );

-- 5. toggle_block_user RPC ---------------------------------------------------
-- Blocking also removes any existing follow relationship in both
-- directions, mirroring what most apps do when you block someone.
CREATE OR REPLACE FUNCTION public.toggle_block_user(target_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF target_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Cannot block yourself';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.user_blocks
    WHERE blocker_id = auth.uid() AND blocked_id = target_user_id
  ) THEN
    DELETE FROM public.user_blocks
    WHERE blocker_id = auth.uid() AND blocked_id = target_user_id;
    RETURN false;
  ELSE
    INSERT INTO public.user_blocks (blocker_id, blocked_id)
    VALUES (auth.uid(), target_user_id)
    ON CONFLICT (blocker_id, blocked_id) DO NOTHING;
    DELETE FROM public.follows
    WHERE (follower_id = auth.uid() AND following_id = target_user_id)
       OR (follower_id = target_user_id AND following_id = auth.uid());
    RETURN true;
  END IF;
END;
$$;

-- 6. toggle_hide_status_from RPC ---------------------------------------------
CREATE OR REPLACE FUNCTION public.toggle_hide_status_from(target_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF target_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Cannot hide your status from yourself';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.hidden_presence
    WHERE user_id = auth.uid() AND hidden_from_id = target_user_id
  ) THEN
    DELETE FROM public.hidden_presence
    WHERE user_id = auth.uid() AND hidden_from_id = target_user_id;
    RETURN false;
  ELSE
    INSERT INTO public.hidden_presence (user_id, hidden_from_id)
    VALUES (auth.uid(), target_user_id)
    ON CONFLICT (user_id, hidden_from_id) DO NOTHING;
    RETURN true;
  END IF;
END;
$$;

-- 7. report_user RPC -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_user(
  target_user_id uuid,
  reason text,
  details text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF target_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Cannot report yourself';
  END IF;
  INSERT INTO public.user_reports (reporter_id, reported_id, reason, details)
  VALUES (auth.uid(), target_user_id, reason, details);
END;
$$;

-- 8. get_chat_relationship RPC ------------------------------------------
-- Everything the chat profile sheet needs about the *viewer's* side of
-- the relationship with target_user_id, in one round trip.
CREATE OR REPLACE FUNCTION public.get_chat_relationship(target_user_id uuid)
RETURNS TABLE (
  is_blocked_by_me boolean,
  hiding_status_from_them boolean
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    EXISTS (
      SELECT 1 FROM public.user_blocks
      WHERE blocker_id = auth.uid() AND blocked_id = target_user_id
    ) AS is_blocked_by_me,
    EXISTS (
      SELECT 1 FROM public.hidden_presence
      WHERE user_id = auth.uid() AND hidden_from_id = target_user_id
    ) AS hiding_status_from_them;
$$;

-- 9. get_public_profile: respect hidden-status + blocks --------------------
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
  last_active_at timestamptz,
  is_blocked_by_me boolean
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
    CASE WHEN p.id = auth.uid()
      OR EXISTS (
        SELECT 1 FROM public.hidden_presence hp
        WHERE hp.user_id = p.id AND hp.hidden_from_id = auth.uid()
      )
      OR EXISTS (
        SELECT 1 FROM public.user_blocks b
        WHERE (b.blocker_id = auth.uid() AND b.blocked_id = p.id)
           OR (b.blocker_id = p.id AND b.blocked_id = auth.uid())
      )
      THEN NULL ELSE p.last_active_at END AS last_active_at,
    EXISTS (
      SELECT 1 FROM public.user_blocks b
      WHERE b.blocker_id = auth.uid() AND b.blocked_id = p.id
    ) AS is_blocked_by_me
  FROM public.profiles p
  WHERE p.id = target_user_id;
$$;

-- 10. list_conversations: hide blocked threads + respect hidden status -----
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
  other_last_active_at timestamptz,
  is_blocked_by_me boolean
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
    CASE WHEN EXISTS (
      SELECT 1 FROM public.hidden_presence hp
      WHERE hp.user_id = r.other_user_id AND hp.hidden_from_id = auth.uid()
    ) THEN NULL ELSE p.last_active_at END AS other_last_active_at,
    ub.blocked_id IS NOT NULL AS is_blocked_by_me
  FROM ranked r
  JOIN public.profiles p ON p.id = r.other_user_id
  LEFT JOIN public.user_blocks ub
    ON ub.blocker_id = auth.uid() AND ub.blocked_id = r.other_user_id
  WHERE r.rn = 1
    -- A block in either direction drops the thread from the list —
    -- neither side can reach the other any more.
    AND NOT EXISTS (
      SELECT 1 FROM public.user_blocks b2
      WHERE b2.blocker_id = r.other_user_id AND b2.blocked_id = auth.uid()
    )
  ORDER BY r.created_at DESC;
$$;
