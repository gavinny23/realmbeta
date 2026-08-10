-- ================================================================
-- REALITY MERGE v15 — News comments (Updates tab)
-- Run this in the Supabase SQL editor after v14-migration.sql
-- ================================================================
--
-- The Updates tab shows syndicated RSS headlines (Kenyan outlets
-- first, then Africa/world) — those stories live entirely client-side,
-- fetched fresh from each publisher's feed, never stored here. What
-- *is* stored is discussion on top of them: real user comments on a
-- given story, keyed by the article's own link rather than a foreign
-- key into some local "articles" table, since the article isn't ours
-- to own — the publisher's URL is the only stable id it has.
--
-- Flat comments only (no like/reply threading like flicks has) — a
-- news card's comment section is meant to be a quick reaction thread,
-- not a nested discussion.

create table if not exists public.news_comments (
  id uuid primary key default gen_random_uuid(),
  article_link text not null check (char_length(article_link) <= 2048),
  article_title text not null check (char_length(article_title) <= 500),
  user_id uuid not null references public.profiles(id) on delete cascade,
  content text not null check (char_length(content) <= 500),
  created_at timestamptz not null default now()
);

create index if not exists news_comments_article_idx
  on public.news_comments (article_link, created_at desc);

alter table public.news_comments enable row level security;

create policy "News comments are viewable by everyone"
  on public.news_comments for select
  using (true);

create policy "Users can post their own news comments"
  on public.news_comments for insert
  with check (auth.uid() = user_id);

create policy "Users can delete their own news comments"
  on public.news_comments for delete
  using (auth.uid() = user_id);

-- Comment count per article, used to show "12 comments" on a card
-- without pulling every comment down first.
create or replace function public.news_comment_count(target_article_link text)
returns bigint
language sql
stable
as $$
  select count(*) from public.news_comments where article_link = target_article_link;
$$;

alter publication supabase_realtime add table public.news_comments;
