-- ================================================================
-- REALM v31 — fix infinite RLS recursion on group_chat_participants
-- Run this in the Supabase SQL editor after v30-migration.sql
-- ================================================================
--
-- Bug: "Participants can view the participant list" (v26) checks
-- membership by querying group_chat_participants from inside its own
-- USING clause. That inner query re-triggers the same policy, which
-- queries the table again, forever — Postgres detects the cycle and
-- raises 42P17 ("infinite recursion detected in policy for relation
-- group_chat_participants") instead of hanging.
--
-- Everything that depends on reading group_chat_participants under
-- RLS breaks the same way, including "Participants can view group
-- messages" (its EXISTS subquery reads group_chat_participants too)
-- — which is why opening a group chat shows nothing at all, not even
-- the seeded first message.
--
-- Fix: check membership through a SECURITY DEFINER function instead
-- of a direct table reference. The function's internal SELECT runs
-- as its owner, bypassing RLS, so it can answer "is this user a
-- participant" without re-entering the policy that's asking.

CREATE OR REPLACE FUNCTION public.is_group_chat_participant(p_chat_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.group_chat_participants
    WHERE chat_id = p_chat_id AND user_id = p_user_id
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_group_chat_participant(uuid, uuid) TO authenticated;

-- Replace the four policies that were doing the same recursion-prone
-- (or, for group_chats/group_messages, RLS-on-RLS) check inline.

DROP POLICY IF EXISTS "Participants can view their group chats" ON public.group_chats;
CREATE POLICY "Participants can view their group chats"
  ON public.group_chats FOR SELECT
  USING (public.is_group_chat_participant(id, auth.uid()));

DROP POLICY IF EXISTS "Participants can view the participant list" ON public.group_chat_participants;
CREATE POLICY "Participants can view the participant list"
  ON public.group_chat_participants FOR SELECT
  USING (public.is_group_chat_participant(chat_id, auth.uid()));

DROP POLICY IF EXISTS "Participants can view group messages" ON public.group_messages;
CREATE POLICY "Participants can view group messages"
  ON public.group_messages FOR SELECT
  USING (public.is_group_chat_participant(chat_id, auth.uid()));

-- The send policy also needs the "currently active" (not left)
-- check, so it gets its own small SECURITY DEFINER helper rather
-- than reusing is_group_chat_participant.
CREATE OR REPLACE FUNCTION public.is_active_group_chat_participant(p_chat_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.group_chat_participants
    WHERE chat_id = p_chat_id AND user_id = p_user_id AND left_at IS NULL
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_active_group_chat_participant(uuid, uuid) TO authenticated;

DROP POLICY IF EXISTS "Active participants can send group messages" ON public.group_messages;
CREATE POLICY "Active participants can send group messages"
  ON public.group_messages FOR INSERT
  WITH CHECK (
    auth.uid() = sender_id
    AND public.is_active_group_chat_participant(chat_id, auth.uid())
  );
