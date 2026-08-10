-- ================================================================
-- REALITY MERGE v1 — Supabase / Postgres schema
-- Run this in the Supabase SQL editor (or via `supabase db push`)
-- ================================================================

-- 1. Extensions -----------------------------------------------------
create extension if not exists postgis;

-- 2. Profiles ---------------------------------------------------------
-- Supabase Auth already gives us auth.users (id, email, ...).
-- We keep app-specific fields in a separate profiles table keyed
-- by the same id, which is the standard Supabase pattern.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  display_name text not null,
  home_city text,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "Profiles are viewable by everyone"
  on public.profiles for select
  using (true);

create policy "Users can insert their own profile"
  on public.profiles for insert
  with check (auth.uid() = id);

create policy "Users can update their own profile"
  on public.profiles for update
  using (auth.uid() = id);

-- 3. Drops --------------------------------------------------------------
create table public.drops (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.profiles(id) on delete cascade,
  location geography(Point, 4326) not null,
  caption text not null check (char_length(caption) <= 500),
  media_url text,
  unlock_radius_m integer not null default 50 check (unlock_radius_m > 0),
  created_at timestamptz not null default now()
);

-- Spatial index — this is what makes "what's near me" queries fast.
create index drops_location_idx on public.drops using gist (location);
create index drops_creator_idx on public.drops (creator_id);

alter table public.drops enable row level security;

create policy "Drops are viewable by everyone"
  on public.drops for select
  using (true);

create policy "Users can create their own drops"
  on public.drops for insert
  with check (auth.uid() = creator_id);

create policy "Users can delete their own drops"
  on public.drops for delete
  using (auth.uid() = creator_id);

-- 4. Drop unlocks ---------------------------------------------------------
-- Records that a user physically unlocked a drop. Powers "places visited"
-- and prevents a drop from being unlocked/counted twice by the same user.
create table public.drop_unlocks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  drop_id uuid not null references public.drops(id) on delete cascade,
  unlocked_at timestamptz not null default now(),
  unique (user_id, drop_id)
);

create index drop_unlocks_user_idx on public.drop_unlocks (user_id);
create index drop_unlocks_drop_idx on public.drop_unlocks (drop_id);

alter table public.drop_unlocks enable row level security;

create policy "Users can view their own unlocks"
  on public.drop_unlocks for select
  using (auth.uid() = user_id);

create policy "Users can create their own unlocks"
  on public.drop_unlocks for insert
  with check (auth.uid() = user_id);

-- 5. Interactions (likes + comments) ---------------------------------------
create table public.drop_interactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  drop_id uuid not null references public.drops(id) on delete cascade,
  type text not null check (type in ('like', 'comment')),
  content text check (
    (type = 'comment' and content is not null and char_length(content) <= 500)
    or (type = 'like' and content is null)
  ),
  created_at timestamptz not null default now()
);

-- A user can only like a drop once — enforced with a partial unique
-- index scoped to type = 'like' so it never limits how many comments
-- a user can leave on the same drop.
create unique index drop_interactions_one_like_per_user
  on public.drop_interactions (user_id, drop_id)
  where (type = 'like');

create index drop_interactions_drop_idx on public.drop_interactions (drop_id);

alter table public.drop_interactions enable row level security;

create policy "Interactions are viewable by everyone"
  on public.drop_interactions for select
  using (true);

create policy "Users can create their own interactions"
  on public.drop_interactions for insert
  with check (auth.uid() = user_id);

create policy "Users can delete their own interactions"
  on public.drop_interactions for delete
  using (auth.uid() = user_id);

-- 6. RPC: nearby drops ------------------------------------------------------
-- The core "what's near me" query. Returns drops within radius_m of a
-- point, plus whether the current user has unlocked each one, plus the
-- distance so the client can show "180m away" for locked drops.
create or replace function public.nearby_drops(
  user_lat double precision,
  user_lng double precision,
  radius_m integer default 2000
)
returns table (
  id uuid,
  creator_id uuid,
  creator_username text,
  caption text,
  media_url text,
  unlock_radius_m integer,
  distance_m double precision,
  drop_lat double precision,
  drop_lng double precision,
  is_unlocked boolean,
  created_at timestamptz
)
language sql
stable
as $$
  select
    d.id,
    d.creator_id,
    p.username as creator_username,
    case when du.id is not null or d.creator_id = auth.uid()
      then d.caption else null end as caption,
    case when du.id is not null or d.creator_id = auth.uid()
      then d.media_url else null end as media_url,
    d.unlock_radius_m,
    st_distance(d.location, st_setsrid(st_makepoint(user_lng, user_lat), 4326)::geography) as distance_m,
    st_y(d.location::geometry) as drop_lat,
    st_x(d.location::geometry) as drop_lng,
    (du.id is not null) as is_unlocked,
    d.created_at
  from public.drops d
  left join public.profiles p on p.id = d.creator_id
  left join public.drop_unlocks du
    on du.drop_id = d.id and du.user_id = auth.uid()
  where st_dwithin(
    d.location,
    st_setsrid(st_makepoint(user_lng, user_lat), 4326)::geography,
    radius_m
  )
  order by distance_m asc;
$$;

-- 7. RPC: attempt unlock -----------------------------------------------------
-- Server-side check that the user is actually within unlock_radius_m
-- before recording the unlock. Never trust the client's claim of proximity.
create or replace function public.attempt_unlock(
  target_drop_id uuid,
  user_lat double precision,
  user_lng double precision
)
returns boolean
language plpgsql
security definer
as $$
declare
  drop_record public.drops;
  distance_m double precision;
begin
  select * into drop_record from public.drops where id = target_drop_id;

  if not found then
    raise exception 'Drop not found';
  end if;

  distance_m := st_distance(
    drop_record.location,
    st_setsrid(st_makepoint(user_lng, user_lat), 4326)::geography
  );

  if distance_m > drop_record.unlock_radius_m then
    return false; -- too far, not unlocked
  end if;

  insert into public.drop_unlocks (user_id, drop_id)
  values (auth.uid(), target_drop_id)
  on conflict (user_id, drop_id) do nothing;

  return true;
end;
$$;

-- 8. Profile stats view -----------------------------------------------------
create or replace view public.profile_stats as
select
  p.id as user_id,
  p.username,
  count(distinct d.id) as drops_created,
  count(distinct du.drop_id) as drops_unlocked
from public.profiles p
left join public.drops d on d.creator_id = p.id
left join public.drop_unlocks du on du.user_id = p.id
group by p.id, p.username;
