-- ================================================================
-- REALITY MERGE v14 — SMS Gateway Bridge
-- Run this in the Supabase SQL editor after v13-migration.sql
-- ================================================================
--
-- Lets one designated Android phone (running this app in "Gateway
-- mode", with a real SIM) relay SMS conversations into the app. An
-- internet-side user creates an sms_threads row pointing at a phone
-- number; messages they send get queued as 'outbound' rows and the
-- gateway phone's native SMS radio sends the real text. Replies the
-- gateway phone receives over SMS get inserted back as 'inbound'
-- rows, which surface in the internet-side user's chat like a
-- normal message.
--
-- Deliberately NOT reusing the messages/profiles tables: a phone
-- number isn't a profile (no auth.users row, no username), and
-- mixing SMS routing state into the DM schema would make the RLS
-- for both harder to reason about. This stays a separate system;
-- the Flutter client merges the two lists in the chats UI.

-- 1. Gateway devices ----------------------------------------------------------
-- One row per phone acting as a relay. A device is "claimed" by the
-- profile that set it up (the phone's actual operator) and
-- authenticates as that same profile's normal Supabase session —
-- just running the app in Gateway mode instead of (or alongside)
-- ordinary use.
create table if not exists public.sms_gateway_devices (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.profiles(id) on delete cascade,
  label text not null default 'SMS Gateway',
  sim_phone_number text, -- the SIM's own number, if the OS reports one; informational only
  is_online boolean not null default false,
  last_seen_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.sms_gateway_devices enable row level security;

create policy "Operator can manage their own gateway devices"
  on public.sms_gateway_devices for all
  using (auth.uid() = operator_id)
  with check (auth.uid() = operator_id);

-- 2. SMS threads ----------------------------------------------------------
-- One row per (internet-side user, phone number) pair bridged
-- through a given gateway device.
create table if not exists public.sms_threads (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  gateway_device_id uuid not null references public.sms_gateway_devices(id) on delete cascade,
  phone_number text not null,
  display_name text, -- optional label the owner gives this contact
  created_at timestamptz not null default now(),
  last_message_at timestamptz not null default now(),
  unique (owner_id, gateway_device_id, phone_number)
);

create index if not exists sms_threads_owner_idx on public.sms_threads (owner_id, last_message_at desc);
create index if not exists sms_threads_gateway_idx on public.sms_threads (gateway_device_id);

alter table public.sms_threads enable row level security;

create policy "Owner can view their sms threads"
  on public.sms_threads for select
  using (auth.uid() = owner_id);

create policy "Owner can create sms threads on their gateway"
  on public.sms_threads for insert
  with check (
    auth.uid() = owner_id
    and exists (
      select 1 from public.sms_gateway_devices g
      where g.id = gateway_device_id and g.operator_id = auth.uid()
    )
  );

create policy "Owner can update their own sms threads"
  on public.sms_threads for update
  using (auth.uid() = owner_id);

-- The gateway operator also needs visibility into threads routed
-- through their device (to know which numbers to text), even for
-- threads owned by someone else if a gateway is ever shared on
-- behalf of other users. For the common case of one person
-- operating their own gateway this overlaps with the policy above.
create policy "Gateway operator can view threads on their device"
  on public.sms_threads for select
  using (
    exists (
      select 1 from public.sms_gateway_devices g
      where g.id = gateway_device_id and g.operator_id = auth.uid()
    )
  );

-- 3. SMS messages ----------------------------------------------------------
create table if not exists public.sms_messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.sms_threads(id) on delete cascade,
  direction text not null check (direction in ('outbound', 'inbound')),
  body text not null check (char_length(body) <= 1600), -- room for a few concatenated SMS segments
  status text not null default 'pending'
    check (status in ('pending', 'sending', 'sent', 'delivered', 'failed', 'received')),
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

create index if not exists sms_messages_thread_idx on public.sms_messages (thread_id, created_at);
-- Lets the gateway phone efficiently find its own work queue without
-- scanning every thread.
create index if not exists sms_messages_outbox_idx
  on public.sms_messages (status)
  where status = 'pending' and direction = 'outbound';

alter table public.sms_messages enable row level security;

create policy "Thread owner can view their sms messages"
  on public.sms_messages for select
  using (
    exists (
      select 1 from public.sms_threads t
      where t.id = thread_id and t.owner_id = auth.uid()
    )
  );

create policy "Gateway operator can view messages on their device"
  on public.sms_messages for select
  using (
    exists (
      select 1 from public.sms_threads t
      join public.sms_gateway_devices g on g.id = t.gateway_device_id
      where t.id = thread_id and g.operator_id = auth.uid()
    )
  );

-- Direct-insert paths exist mainly as a safety net; normal traffic
-- goes through send_sms_message / receive_sms_message below so the
-- thread find-or-create step can't race.
create policy "Owner can queue outbound sms"
  on public.sms_messages for insert
  with check (
    direction = 'outbound'
    and status = 'pending'
    and exists (
      select 1 from public.sms_threads t
      where t.id = thread_id and t.owner_id = auth.uid()
    )
  );

create policy "Gateway operator can post inbound sms"
  on public.sms_messages for insert
  with check (
    direction = 'inbound'
    and exists (
      select 1 from public.sms_threads t
      join public.sms_gateway_devices g on g.id = t.gateway_device_id
      where t.id = thread_id and g.operator_id = auth.uid()
    )
  );

create policy "Gateway operator can update delivery status"
  on public.sms_messages for update
  using (
    exists (
      select 1 from public.sms_threads t
      join public.sms_gateway_devices g on g.id = t.gateway_device_id
      where t.id = thread_id and g.operator_id = auth.uid()
    )
  );

-- 4. RPCs ----------------------------------------------------------------

-- Registers (or re-claims + heartbeats) this device as a gateway for
-- the calling user. Called once from Gateway Setup, then periodically
-- while Gateway mode is running.
create or replace function public.register_gateway_device(
  device_id uuid default null,
  device_label text default 'SMS Gateway',
  sim_phone_number text default null
)
returns uuid
language plpgsql
security definer
as $$
declare
  result_id uuid;
begin
  if device_id is not null then
    update public.sms_gateway_devices
      set is_online = true,
          last_seen_at = now(),
          sim_phone_number = coalesce(register_gateway_device.sim_phone_number, sms_gateway_devices.sim_phone_number)
      where id = device_id and operator_id = auth.uid()
      returning id into result_id;
    if result_id is not null then
      return result_id;
    end if;
  end if;

  insert into public.sms_gateway_devices (operator_id, label, sim_phone_number, is_online, last_seen_at)
  values (auth.uid(), device_label, sim_phone_number, true, now())
  returning id into result_id;

  return result_id;
end;
$$;

create or replace function public.set_gateway_offline(device_id uuid)
returns void
language sql
security definer
as $$
  update public.sms_gateway_devices
    set is_online = false
    where id = device_id and operator_id = auth.uid();
$$;

-- Finds (or creates) the thread for a phone number on a given
-- gateway, then queues the outbound message. Doing find-or-create +
-- insert as one RPC avoids a race where two "first messages" to the
-- same number create two threads.
create or replace function public.send_sms_message(
  target_gateway_id uuid,
  target_phone_number text,
  message_body text,
  contact_display_name text default null
)
returns public.sms_messages
language plpgsql
security definer
as $$
declare
  target_thread_id uuid;
  new_message public.sms_messages;
begin
  select id into target_thread_id
    from public.sms_threads
    where owner_id = auth.uid()
      and gateway_device_id = target_gateway_id
      and phone_number = target_phone_number;

  if target_thread_id is null then
    insert into public.sms_threads (owner_id, gateway_device_id, phone_number, display_name)
    values (auth.uid(), target_gateway_id, target_phone_number, contact_display_name)
    returning id into target_thread_id;
  else
    update public.sms_threads set last_message_at = now() where id = target_thread_id;
  end if;

  insert into public.sms_messages (thread_id, direction, body, status)
  values (target_thread_id, 'outbound', message_body, 'pending')
  returning * into new_message;

  return new_message;
end;
$$;

-- Called by the gateway phone when a real SMS arrives. A text from a
-- number with no existing thread is attached to whichever profile
-- currently operates this gateway, so it still surfaces somewhere
-- instead of being silently dropped.
create or replace function public.receive_sms_message(
  from_gateway_id uuid,
  from_phone_number text,
  message_body text
)
returns public.sms_messages
language plpgsql
security definer
as $$
declare
  target_thread_id uuid;
  gateway_operator uuid;
  new_message public.sms_messages;
begin
  select operator_id into gateway_operator
    from public.sms_gateway_devices
    where id = from_gateway_id and operator_id = auth.uid();

  if gateway_operator is null then
    raise exception 'Not authorized for this gateway device';
  end if;

  select id into target_thread_id
    from public.sms_threads
    where gateway_device_id = from_gateway_id
      and phone_number = from_phone_number
    order by created_at asc
    limit 1;

  if target_thread_id is null then
    insert into public.sms_threads (owner_id, gateway_device_id, phone_number)
    values (gateway_operator, from_gateway_id, from_phone_number)
    returning id into target_thread_id;
  else
    update public.sms_threads set last_message_at = now() where id = target_thread_id;
  end if;

  insert into public.sms_messages (thread_id, direction, body, status)
  values (target_thread_id, 'inbound', message_body, 'received')
  returning * into new_message;

  return new_message;
end;
$$;

-- One row per SMS thread the current user owns, newest first — shaped
-- to slot into the same chat list as list_conversations.
create or replace function public.list_sms_conversations()
returns table (
  thread_id uuid,
  gateway_device_id uuid,
  phone_number text,
  display_name text,
  last_message text,
  last_message_at timestamptz,
  last_direction text,
  unread_count bigint
)
language sql
stable
as $$
  with ranked as (
    select
      m.thread_id,
      m.body,
      m.created_at,
      m.direction,
      row_number() over (partition by m.thread_id order by m.created_at desc) as rn
    from public.sms_messages m
    join public.sms_threads t on t.id = m.thread_id
    where t.owner_id = auth.uid()
  )
  select
    t.id as thread_id,
    t.gateway_device_id,
    t.phone_number,
    t.display_name,
    r.body as last_message,
    r.created_at as last_message_at,
    r.direction as last_direction,
    (
      select count(*) from public.sms_messages m2
      where m2.thread_id = t.id and m2.direction = 'inbound' and m2.status = 'received'
    ) as unread_count
  from public.sms_threads t
  left join ranked r on r.thread_id = t.id and r.rn = 1
  where t.owner_id = auth.uid()
  order by coalesce(r.created_at, t.created_at) desc;
$$;

create or replace function public.mark_sms_thread_read(target_thread_id uuid)
returns void
language plpgsql
security definer
as $$
begin
  update public.sms_messages
    set status = 'delivered'
    where thread_id = target_thread_id
      and direction = 'inbound'
      and status = 'received'
      and exists (
        select 1 from public.sms_threads t
        where t.id = target_thread_id and t.owner_id = auth.uid()
      );
end;
$$;

-- Lets the gateway phone claim its next batch of pending outbound
-- messages atomically (FOR UPDATE SKIP LOCKED), so a stale background
-- isolate and a freshly restarted one can't both grab and double-send
-- the same text. Claimed rows move to 'sending'; the gateway calls
-- update_sms_status() once the native SmsManager result comes back.
create or replace function public.claim_pending_sms(
  for_gateway_id uuid,
  batch_size integer default 20
)
returns table (
  message_id uuid,
  thread_id uuid,
  phone_number text,
  body text
)
language plpgsql
security definer
as $$
begin
  if not exists (
    select 1 from public.sms_gateway_devices g
    where g.id = for_gateway_id and g.operator_id = auth.uid()
  ) then
    raise exception 'Not authorized for this gateway device';
  end if;

  return query
  with claimed as (
    select m.id
    from public.sms_messages m
    join public.sms_threads t on t.id = m.thread_id
    where t.gateway_device_id = for_gateway_id
      and m.direction = 'outbound'
      and m.status = 'pending'
    order by m.created_at asc
    limit batch_size
    for update of m skip locked
  ),
  updated as (
    update public.sms_messages m
      set status = 'sending'
      from claimed
      where m.id = claimed.id
      returning m.id, m.thread_id, m.body
  )
  select u.id as message_id, u.thread_id, t.phone_number, u.body
  from updated u
  join public.sms_threads t on t.id = u.thread_id;
end;
$$;

create or replace function public.update_sms_status(
  target_message_id uuid,
  new_status text
)
returns void
language plpgsql
security definer
as $$
begin
  if new_status not in ('sent', 'delivered', 'failed') then
    raise exception 'Invalid status %', new_status;
  end if;
  update public.sms_messages m
    set status = new_status, sent_at = case when new_status = 'sent' then now() else m.sent_at end
    from public.sms_threads t
    join public.sms_gateway_devices g on g.id = t.gateway_device_id
    where m.thread_id = t.id
      and m.id = target_message_id
      and g.operator_id = auth.uid();
end;
$$;

-- 5. Realtime ---------------------------------------------------------------
-- Matches how `messages` is already used for the in-app DM realtime
-- feed: both tables need to be in the publication for .stream()/
-- postgres-changes subscribers to see inserts as they land.
alter publication supabase_realtime add table public.sms_threads;
alter publication supabase_realtime add table public.sms_messages;
