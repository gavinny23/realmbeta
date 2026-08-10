-- ================================================================
-- REALITY MERGE v32 — Push notifications for chat messages, with
-- proper multi-account support on a single device
-- Run this in the Supabase SQL editor after v31-migration.sql
-- ================================================================
--
-- Background: device_tokens (v19-migration.sql) currently has
-- `fcm_token text unique`. That means one FCM registration token —
-- i.e. one physical device — can only ever be linked to ONE user_id
-- at a time. AccountManagerService lets several accounts live on the
-- same device and switch between them without signing out, so the
-- old schema silently broke notifications for every account except
-- whichever one last called registerDeviceToken: switching accounts
-- re-upserted the same token row onto the new user_id, which is
-- exactly the "old account stops receiving notifications" bug.
--
-- Fix: a device token can belong to more than one account at once
-- (Instagram/X-style). The uniqueness constraint moves from
-- `fcm_token` alone to the pair `(user_id, fcm_token)`, so both
-- accounts signed in on the same phone get their own row pointing at
-- the same token. An `active` flag lets a specific account stop
-- getting pushed to (explicit sign-out, or a notification toggle)
-- without touching the row for any other account sharing that token.

-- 1. Loosen device_tokens' uniqueness to (user_id, fcm_token) --------------
alter table public.device_tokens
  drop constraint if exists device_tokens_fcm_token_key;

alter table public.device_tokens
  add column if not exists active boolean not null default true;

alter table public.device_tokens
  add constraint device_tokens_user_fcm_token_key unique (user_id, fcm_token);

-- Kept for the fan-out lookup ("who does this content belong to") and
-- for pruning every row that shares a token once FCM reports it dead.
create index if not exists device_tokens_fcm_token_idx
  on public.device_tokens (fcm_token);
create index if not exists device_tokens_active_idx
  on public.device_tokens (user_id) where active;

-- 2. Event-driven push on every new message ---------------------------------
-- Unlike check-new-news (polled on a cron schedule), a chat message
-- should notify near-instantly, so this fires straight off the
-- messages table's own insert instead of waiting on a timer.
--
-- Same Vault prerequisite as v19: a secret literally named
-- `service_role_key` under Database → Vault, and pg_net enabled.
-- Deploy the function first: `supabase functions deploy send-chat-notification`
-- (see supabase/functions/send-chat-notification/index.ts), then
-- replace <YOUR_PROJECT_REF> below with your project's actual ref.
create or replace function public.notify_new_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform net.http_post(
    url := 'https://oevwdmmtjxpgpjzsaddu.supabase.co/functions/v1/send-chat-notification',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (
        select decrypted_secret from vault.decrypted_secrets
        where name = 'service_role_key'
      ),
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object(
      'message_id', new.id,
      'sender_id', new.sender_id,
      'recipient_id', new.recipient_id,
      'content', new.content,
      'created_at', new.created_at
    )
  );
  return new;
end;
$$;

drop trigger if exists messages_notify_after_insert on public.messages;
create trigger messages_notify_after_insert
  after insert on public.messages
  for each row execute function public.notify_new_message();
