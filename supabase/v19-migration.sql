-- ================================================================
-- REALITY MERGE v19 — Push notifications for new Updates stories
-- Run this in the Supabase SQL editor after v18-migration.sql
-- ================================================================
--
-- Two tables:
--
--  - device_tokens: one FCM registration token per signed-in device,
--    upserted by the client (see PushNotificationService) on launch
--    and whenever the token rotates. This is what the
--    check-new-news Edge Function reads to know who to push to.
--
--  - news_seen_articles: a dedup ledger of every article link the
--    Edge Function has already pushed once, so re-running the check
--    (every few minutes, via pg_cron) only ever notifies about
--    genuinely new stories, not the same RSS feed re-fetched.
--    Deliberately has NO policies at all below — this table is only
--    ever touched by the Edge Function using the service role key,
--    which bypasses RLS entirely; there's nothing here the app itself
--    should read or write.

create table if not exists public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  fcm_token text not null unique,
  platform text not null default 'android',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists device_tokens_user_idx on public.device_tokens (user_id);

alter table public.device_tokens enable row level security;

create policy "Users manage their own device tokens"
  on public.device_tokens for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create table if not exists public.news_seen_articles (
  article_link text primary key check (char_length(article_link) <= 2048),
  article_title text not null check (char_length(article_title) <= 500),
  first_seen_at timestamptz not null default now()
);

alter table public.news_seen_articles enable row level security;

-- ---------------------------------------------------------------
-- Scheduling: run check-new-news every 10 minutes via pg_cron + pg_net.
--
-- Prerequisites (one-time, in the dashboard, not this script):
--  1. Enable the pg_cron and pg_net extensions — Database → Extensions.
--  2. Deploy the function: `supabase functions deploy check-new-news`
--     (see supabase/functions/check-new-news/index.ts).
--  3. Store your service role key in Vault — Database → Vault → New
--     secret — named exactly `service_role_key`. Never paste the raw
--     key directly into a SQL script; Vault keeps it encrypted at
--     rest and this cron job just references it by name.
--  4. Replace <YOUR_PROJECT_REF> below with your actual project ref
--     (visible in your project's API settings) before running this
--     part of the file.
-- ---------------------------------------------------------------
select cron.schedule(
  'check-new-news-every-10-min',
  '*/10 * * * *',
  $$
  select net.http_post(
    url := 'https://<YOUR_PROJECT_REF>.supabase.co/functions/v1/check-new-news',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (
        select decrypted_secret from vault.decrypted_secrets
        where name = 'service_role_key'
      ),
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);
