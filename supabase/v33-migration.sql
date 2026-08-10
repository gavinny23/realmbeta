-- ================================================================
-- REALITY MERGE v33 — Push notifications when someone you follow
-- posts a new status
-- Run this in the Supabase SQL editor after v32-migration.sql
-- ================================================================
--
-- Same event-driven shape as v32's chat trigger: a status should
-- notify near-instantly, so this fires straight off the statuses
-- table's own insert instead of waiting on a timer (unlike
-- check-new-news, which is polled on a cron schedule).
--
-- Fan-out is the real difference from v32 — one status insert can
-- mean pushing to every one of the creator's followers, each of
-- whom may have several active devices/accounts. That entire lookup
-- (public.follows → public.device_tokens) lives in the edge function
-- (see supabase/functions/send-status-notification/index.ts) rather
-- than here, so this trigger body only ever needs to hand over which
-- status/creator this is — same "keep the trigger a thin dispatcher"
-- shape as notify_new_message.
--
-- Same Vault prerequisite as v32: a secret literally named
-- `service_role_key` under Database → Vault, and pg_net enabled.
-- Deploy the function first: `supabase functions deploy send-status-notification`
-- then replace <YOUR_PROJECT_REF> below with your project's actual ref
-- if it differs from the one already baked into v32's trigger.

create or replace function public.notify_new_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform net.http_post(
    url := 'https://oevwdmmtjxpgpjzsaddu.supabase.co/functions/v1/send-status-notification',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (
        select decrypted_secret from vault.decrypted_secrets
        where name = 'service_role_key'
      ),
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object(
      'status_id', new.id,
      'creator_id', new.creator_id,
      'media_type', new.media_type,
      'caption', new.caption,
      'created_at', new.created_at
    )
  );
  return new;
end;
$$;

drop trigger if exists statuses_notify_after_insert on public.statuses;
create trigger statuses_notify_after_insert
  after insert on public.statuses
  for each row execute function public.notify_new_status();
