-- ================================================================
-- REALITY MERGE v4 — Direct messages (Chats tab)
-- Run this in the Supabase SQL editor after v3-migration.sql
-- ================================================================

-- 1. Messages table -----------------------------------------------------
-- Simple 1:1 direct messages between two profiles. A "conversation" is
-- derived on the fly from the distinct pairs of (sender, recipient)
-- rather than modeled as its own table — keeps this migration small
-- and avoids a second source of truth for who's talking to whom.
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  content text not null check (char_length(content) <= 2000),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  constraint messages_no_self_dm check (sender_id <> recipient_id)
);

create index if not exists messages_sender_idx on public.messages (sender_id, created_at desc);
create index if not exists messages_recipient_idx on public.messages (recipient_id, created_at desc);
-- Speeds up "all messages between me and user X" lookups regardless of
-- who sent which message.
create index if not exists messages_pair_idx
  on public.messages (least(sender_id, recipient_id), greatest(sender_id, recipient_id), created_at);

alter table public.messages enable row level security;

-- Only the two participants can see a message.
create policy "Participants can view their messages"
  on public.messages for select
  using (auth.uid() = sender_id or auth.uid() = recipient_id);

-- You can only send as yourself.
create policy "Users can send messages as themselves"
  on public.messages for insert
  with check (auth.uid() = sender_id);

-- Only the recipient can mark a message read (updates read_at only).
create policy "Recipient can mark messages read"
  on public.messages for update
  using (auth.uid() = recipient_id)
  with check (auth.uid() = recipient_id);

-- 2. Realtime -------------------------------------------------------------
-- Lets the Chats tab subscribe to new rows instead of polling.
alter publication supabase_realtime add table public.messages;

-- 3. RPC: conversation list -------------------------------------------------
-- One row per person the current user has exchanged messages with,
-- with the most recent message and an unread count, newest first.
create or replace function public.list_conversations()
returns table (
  other_user_id uuid,
  other_username text,
  last_message text,
  last_message_at timestamptz,
  last_sender_id uuid,
  unread_count bigint
)
language sql
stable
as $$
  with mine as (
    select
      case when sender_id = auth.uid() then recipient_id else sender_id end as other_user_id,
      sender_id,
      content,
      created_at,
      read_at
    from public.messages
    where sender_id = auth.uid() or recipient_id = auth.uid()
  ),
  ranked as (
    select
      other_user_id,
      sender_id,
      content,
      created_at,
      row_number() over (partition by other_user_id order by created_at desc) as rn
    from mine
  )
  select
    r.other_user_id,
    p.username as other_username,
    r.content as last_message,
    r.created_at as last_message_at,
    r.sender_id as last_sender_id,
    (
      select count(*) from mine m
      where m.other_user_id = r.other_user_id
        and m.sender_id = r.other_user_id
        and m.read_at is null
    ) as unread_count
  from ranked r
  join public.profiles p on p.id = r.other_user_id
  where r.rn = 1
  order by r.created_at desc;
$$;

-- 4. RPC: mark a conversation read -----------------------------------------
create or replace function public.mark_conversation_read(other_user_id uuid)
returns void
language sql
security definer
as $$
  update public.messages
  set read_at = now()
  where recipient_id = auth.uid()
    and sender_id = other_user_id
    and read_at is null;
$$;
