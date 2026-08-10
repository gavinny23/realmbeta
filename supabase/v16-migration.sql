-- ================================================================
-- REALITY MERGE v16 — News redrops (Updates tab)
-- Run this in the Supabase SQL editor after v15-migration.sql
-- ================================================================
--
-- Mirrors news_comments (v15) in every way that matters: syndicated
-- stories aren't stored here, so a redrop is keyed by the article's
-- own link rather than a foreign key into a local "articles" table.
--
-- A redrop is Realm's version of a retweet/repost — recording that a
-- user pushed a story back out to their own audience, with an
-- optional "requote" (their own take, shown above the original
-- headline). It's a distinct action from sharing the story to your
-- 12h status (see `statuses`, v11-migration.sql) — that flow renders
-- the card into an actual image and posts it as ephemeral status
-- media; a redrop is a permanent, lightweight record of the repost
-- itself, closer in spirit to news_comments than to a status post.
--
-- One redrop per (user, article) — redropping again just updates the
-- requote text rather than stacking duplicate rows, same idea as a
-- retweet button that toggles rather than multiplies.

create table if not exists public.news_redrops (
  id uuid primary key default gen_random_uuid(),
  article_link text not null check (char_length(article_link) <= 2048),
  article_title text not null check (char_length(article_title) <= 500),
  user_id uuid not null references public.profiles(id) on delete cascade,
  quote text check (char_length(quote) <= 280),
  created_at timestamptz not null default now(),
  unique (user_id, article_link)
);

create index if not exists news_redrops_article_idx
  on public.news_redrops (article_link, created_at desc);

alter table public.news_redrops enable row level security;

create policy "News redrops are viewable by everyone"
  on public.news_redrops for select
  using (true);

create policy "Users can create their own redrops"
  on public.news_redrops for insert
  with check (auth.uid() = user_id);

create policy "Users can update their own redrops"
  on public.news_redrops for update
  using (auth.uid() = user_id);

create policy "Users can delete their own redrops"
  on public.news_redrops for delete
  using (auth.uid() = user_id);

-- Redrop count per article, used on the card/detail screen next to
-- the comment count without pulling every redrop row down first.
create or replace function public.news_redrop_count(target_article_link text)
returns bigint
language sql
stable
as $$
  select count(*) from public.news_redrops where article_link = target_article_link;
$$;

alter publication supabase_realtime add table public.news_redrops;
