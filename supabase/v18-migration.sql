-- ================================================================
-- REALITY MERGE v18 — Redrops on the Drops tab + likes on stories
-- Run this in the Supabase SQL editor after v17-migration.sql
-- ================================================================
--
-- Three additions so a redrop can stand on its own as a real feed
-- item at the top of the Drops side of the Drops/Updates toggle, not
-- just a count on a card back in Updates:
--
-- 1. news_redrops picks up a couple of snapshot columns (image +
--    source name), captured at redrop time. A card in the Updates
--    tab can afford to always render off the live RSS list, but the
--    Drops tab's redrop feed has to keep rendering a story long after
--    it's scrolled out of that RSS window — so the redrop row itself
--    needs to carry enough to stand alone.
--
-- 2. A new news_likes table. Liking the original story is a separate
--    action from redropping it (like vs. retweet) — nothing let you
--    do that before; this is what "like the original post" from a
--    redrop card actually hits.
--
-- 3. fetch_redrop_feed — newest redrops first, each row carrying
--    everything RedropFeedCard needs (redropper, quote, article
--    snapshot, and all three action counts) in one round trip
--    instead of N+1 queries per card.
--
-- "Comment on the redrop" deliberately reuses news_comments (v15)
-- keyed by the same article_link, rather than forking a second
-- comment thread per redrop — a redrop doesn't create a new piece of
-- content to discuss, it resurfaces the same story, so one shared
-- thread per story (same one the Updates tab card already has) is
-- what "comment" opens either way.

ALTER TABLE public.news_redrops
  ADD COLUMN IF NOT EXISTS article_image_url text,
  ADD COLUMN IF NOT EXISTS article_source_name text;

create table if not exists public.news_likes (
  id uuid primary key default gen_random_uuid(),
  article_link text not null check (char_length(article_link) <= 2048),
  article_title text not null check (char_length(article_title) <= 500),
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (user_id, article_link)
);

create index if not exists news_likes_article_idx
  on public.news_likes (article_link);

alter table public.news_likes enable row level security;

create policy "News likes are viewable by everyone"
  on public.news_likes for select
  using (true);

create policy "Users can like as themselves"
  on public.news_likes for insert
  with check (auth.uid() = user_id);

create policy "Users can unlike their own like"
  on public.news_likes for delete
  using (auth.uid() = user_id);

-- Like count per article, same "don't pull every row just to show a
-- number" contract as news_comment_count/news_redrop_count.
create or replace function public.news_like_count(target_article_link text)
returns bigint
language sql
stable
as $$
  select count(*) from public.news_likes where article_link = target_article_link;
$$;

-- Atomic toggle (check-then-flip in one round trip, same shape as
-- toggle_flick_like) rather than a client-side select-then-insert/delete,
-- which would race under a rapid double-tap.
create or replace function public.toggle_news_like(
  target_article_link text,
  target_article_title text
)
returns boolean
language plpgsql
security definer
as $$
declare
  already_liked boolean;
begin
  select exists(
    select 1 from public.news_likes
    where article_link = target_article_link and user_id = auth.uid()
  ) into already_liked;

  if already_liked then
    delete from public.news_likes
      where article_link = target_article_link and user_id = auth.uid();
    return false;
  else
    insert into public.news_likes (article_link, article_title, user_id)
    values (target_article_link, target_article_title, auth.uid());
    return true;
  end if;
end;
$$;

alter publication supabase_realtime add table public.news_likes;

-- Redrop feed for the Drops tab.
create or replace function public.fetch_redrop_feed(
  limit_count integer default 30,
  before_created_at timestamptz default null
)
returns table (
  id uuid,
  user_id uuid,
  redropper_username text,
  redropper_avatar_url text,
  article_link text,
  article_title text,
  article_image_url text,
  article_source_name text,
  quote text,
  like_count bigint,
  is_liked boolean,
  redrop_count bigint,
  comment_count bigint,
  created_at timestamptz,
  redropper_last_active_at timestamptz
)
language sql
stable
as $$
  select
    r.id,
    r.user_id,
    p.username as redropper_username,
    p.avatar_url as redropper_avatar_url,
    r.article_link,
    r.article_title,
    r.article_image_url,
    r.article_source_name,
    r.quote,
    (select count(*) from public.news_likes l
      where l.article_link = r.article_link) as like_count,
    exists (
      select 1 from public.news_likes l
      where l.article_link = r.article_link and l.user_id = auth.uid()
    ) as is_liked,
    (select count(*) from public.news_redrops rr
      where rr.article_link = r.article_link) as redrop_count,
    (select count(*) from public.news_comments c
      where c.article_link = r.article_link) as comment_count,
    r.created_at,
    p.last_active_at as redropper_last_active_at
  from public.news_redrops r
  join public.profiles p on p.id = r.user_id
  where before_created_at is null or r.created_at < before_created_at
  order by r.created_at desc
  limit limit_count;
$$;
