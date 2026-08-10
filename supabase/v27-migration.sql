-- ================================================================
-- REALM v27 — Mention invitations expire after 10 minutes
-- Run this in the Supabase SQL editor after v26-migration.sql
-- ================================================================
--
-- A pending mention invite now has a hard 10-minute window. Nothing
-- runs on a schedule here (no pg_cron) — instead, every read/write
-- path that touches mention_invitations calls expire_stale_mention_invites()
-- first, so a stale 'pending' row is flipped to 'expired' lazily the
-- next time anyone looks, whether that's the invited person opening
-- the app, the notifications screen loading, or someone trying to
-- respond to it late.

-- 1. Schema -----------------------------------------------------------------
ALTER TABLE public.mention_invitations
  ADD COLUMN IF NOT EXISTS expires_at timestamptz NOT NULL DEFAULT (now() + interval '10 minutes');

ALTER TABLE public.mention_invitations
  DROP CONSTRAINT IF EXISTS mention_invitations_status_check;

ALTER TABLE public.mention_invitations
  ADD CONSTRAINT mention_invitations_status_check
  CHECK (status IN ('pending', 'accepted', 'declined', 'expired'));

-- 2. Cleanup helper -----------------------------------------------------------
-- Flips any invite that's still marked 'pending' past its expires_at
-- into 'expired', and closes out its notification the same way
-- decline already does, so the notifications screen stops showing
-- Accept/Decline on it. Cheap no-op when there's nothing to expire.
CREATE OR REPLACE FUNCTION public.expire_stale_mention_invites()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.mention_invitations
  SET status = 'expired', responded_at = now()
  WHERE status = 'pending' AND expires_at < now();

  UPDATE public.notifications n
  SET read_at = now()
  FROM public.mention_invitations mi
  WHERE n.type = 'mention_invite'
    AND (n.data->>'invite_id')::uuid = mi.id
    AND mi.status = 'expired'
    AND n.read_at IS NULL;
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_stale_mention_invites() TO authenticated;

-- 3. RPC: get_active_mention_invite --------------------------------------------
-- The single most recent still-pending, not-yet-expired invite
-- addressed to the caller, if any — backs the popup dialog that's
-- meant to greet someone with an unanswered invite whenever they
-- open the app, cold start or otherwise, regardless of whether
-- they've ever opened the notifications screen.
CREATE OR REPLACE FUNCTION public.get_active_mention_invite()
RETURNS TABLE (
  invite_id uuid,
  inviter_username text,
  inviter_avatar_url text,
  other_username text,
  message_content text,
  created_at timestamptz,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.expire_stale_mention_invites();

  RETURN QUERY
  SELECT
    mi.id,
    ip.username,
    ip.avatar_url,
    op.username,
    mi.message_content,
    mi.created_at,
    mi.expires_at
  FROM public.mention_invitations mi
  JOIN public.profiles ip ON ip.id = mi.inviter_id
  JOIN public.profiles op ON op.id = mi.other_participant_id
  WHERE mi.invited_id = auth.uid() AND mi.status = 'pending'
  ORDER BY mi.created_at DESC
  LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_mention_invite() TO authenticated;

-- 4. invite_mentioned_user — only reuse a still-live pending invite -----------
CREATE OR REPLACE FUNCTION public.invite_mentioned_user(
  other_participant_id uuid,
  invited_username text,
  message_content text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_invited_id uuid;
  v_invite_id uuid;
  v_inviter_username text;
  v_other_username text;
BEGIN
  PERFORM public.expire_stale_mention_invites();

  SELECT id INTO v_invited_id
  FROM public.profiles
  WHERE lower(username) = lower(invited_username)
    AND allow_tagging = true
    AND allow_discovery = true;

  IF v_invited_id IS NULL OR v_invited_id = auth.uid() OR v_invited_id = other_participant_id THEN
    RETURN NULL;
  END IF;

  -- Idempotent: re-mentioning the same person while an invite is
  -- still pending AND still within its 10-minute window just reuses
  -- it instead of spamming a new one. An invite that already expired
  -- falls through and gets a fresh one (with a fresh 10 minutes)
  -- below, same as if it had never existed.
  SELECT id INTO v_invite_id
  FROM public.mention_invitations
  WHERE inviter_id = auth.uid()
    AND other_participant_id = invite_mentioned_user.other_participant_id
    AND invited_id = v_invited_id
    AND status = 'pending'
    AND expires_at > now();

  IF v_invite_id IS NOT NULL THEN
    RETURN v_invite_id;
  END IF;

  INSERT INTO public.mention_invitations (inviter_id, other_participant_id, invited_id, message_content)
  VALUES (auth.uid(), other_participant_id, v_invited_id, message_content)
  RETURNING id INTO v_invite_id;

  SELECT username INTO v_inviter_username FROM public.profiles WHERE id = auth.uid();
  SELECT username INTO v_other_username FROM public.profiles WHERE id = other_participant_id;

  INSERT INTO public.notifications (user_id, type, actor_id, title, body, data)
  VALUES (
    v_invited_id,
    'mention_invite',
    auth.uid(),
    '@' || coalesce(v_inviter_username, 'someone') || ' mentioned you',
    message_content,
    jsonb_build_object(
      'invite_id', v_invite_id,
      'inviter_username', v_inviter_username,
      'other_username', v_other_username
    )
  );

  RETURN v_invite_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.invite_mentioned_user(uuid, text, text) TO authenticated;

-- 5. respond_to_mention_invite — reject a response that arrived too late -----
CREATE OR REPLACE FUNCTION public.respond_to_mention_invite(
  invite_id uuid,
  accept boolean
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_invite public.mention_invitations%ROWTYPE;
  v_chat_id uuid;
BEGIN
  PERFORM public.expire_stale_mention_invites();

  SELECT * INTO v_invite
  FROM public.mention_invitations
  WHERE id = invite_id AND invited_id = auth.uid() AND status = 'pending'
  FOR UPDATE;

  IF v_invite.id IS NULL THEN
    -- Covers both "never existed / not yours" and "just got expired
    -- by the PERFORM above" — either way there's nothing left to act
    -- on, so the error to a client that had a stale dialog open is
    -- the same either way.
    RAISE EXCEPTION 'Invite not found or already answered.';
  END IF;

  IF accept THEN
    INSERT INTO public.group_chats DEFAULT VALUES RETURNING id INTO v_chat_id;

    INSERT INTO public.group_chat_participants (chat_id, user_id)
    VALUES
      (v_chat_id, v_invite.inviter_id),
      (v_chat_id, v_invite.other_participant_id),
      (v_chat_id, v_invite.invited_id);

    INSERT INTO public.group_messages (chat_id, sender_id, content, created_at)
    VALUES (v_chat_id, v_invite.inviter_id, v_invite.message_content, v_invite.created_at);

    UPDATE public.mention_invitations
    SET status = 'accepted', responded_at = now(), group_chat_id = v_chat_id
    WHERE id = invite_id;

    INSERT INTO public.notifications (user_id, type, actor_id, title, body, data)
    VALUES (
      v_invite.inviter_id,
      'mention_invite_accepted',
      auth.uid(),
      (SELECT username FROM public.profiles WHERE id = auth.uid()) || ' joined the chat',
      NULL,
      jsonb_build_object('group_chat_id', v_chat_id)
    );
  ELSE
    UPDATE public.mention_invitations
    SET status = 'declined', responded_at = now()
    WHERE id = invite_id;
  END IF;

  -- The original invite notification no longer needs action.
  UPDATE public.notifications
  SET read_at = now()
  WHERE user_id = auth.uid()
    AND type = 'mention_invite'
    AND (data->>'invite_id')::uuid = invite_id;

  RETURN v_chat_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.respond_to_mention_invite(uuid, boolean) TO authenticated;

-- 6. list_notifications — also expire stale invites before reading -----------
-- Same query as v26, just fronted by the cleanup call (which needs
-- plpgsql, hence dropping STABLE) so a card whose invite quietly aged
-- out mid-session shows "Invite expired" instead of stale buttons the
-- next time this loads, even if get_active_mention_invite() hasn't
-- run yet this session.
CREATE OR REPLACE FUNCTION public.list_notifications()
RETURNS TABLE (
  id uuid,
  type text,
  actor_id uuid,
  actor_username text,
  actor_avatar_url text,
  title text,
  body text,
  data jsonb,
  invite_status text,
  read_at timestamptz,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.expire_stale_mention_invites();

  RETURN QUERY
  SELECT
    n.id, n.type, n.actor_id,
    p.username AS actor_username,
    p.avatar_url AS actor_avatar_url,
    n.title, n.body, n.data,
    CASE WHEN n.type = 'mention_invite' THEN mi.status ELSE NULL END AS invite_status,
    n.read_at, n.created_at
  FROM public.notifications n
  LEFT JOIN public.profiles p ON p.id = n.actor_id
  LEFT JOIN public.mention_invitations mi ON mi.id = (n.data->>'invite_id')::uuid
  WHERE n.user_id = auth.uid()
  ORDER BY n.created_at DESC
  LIMIT 50;
END;
$$;

GRANT EXECUTE ON FUNCTION public.list_notifications() TO authenticated;
