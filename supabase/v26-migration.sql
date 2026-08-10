-- ================================================================
-- REALM v26 — Notifications, @mention invitations, and group chats
-- Run this in the Supabase SQL editor after v25-migration.sql
-- ================================================================
--
-- The flow this migration backs:
--   1. Alice DMs Bob (an ordinary 1:1 chat) and @mentions Carol.
--   2. Carol gets a notification with an invite: "join a chat with
--      Alice and Bob?" — she hasn't been added to anything yet.
--   3. If Carol accepts, a brand-new 3-person group chat is created,
--      seeded with the message that mentioned her as its first
--      message. If she declines, nothing else happens.
--   4. Group chats have no name field at all — the app always
--      displays them as a comma-separated list of the *current*
--      (non-departed) participants' usernames.
--   5. Anyone can leave a group two ways: a clean "leave" (their
--      existing messages stay put for the others), or "delete my
--      messages & leave" (their own messages are removed for
--      everyone first, then they leave).

-- 1. Notifications --------------------------------------------------------
-- A general-purpose notification inbox. Rows are only ever written by
-- SECURITY DEFINER functions below (no direct insert policy for
-- authenticated users), so the type/data shape stays trustworthy.
CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  type text NOT NULL,
  actor_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  title text NOT NULL,
  body text,
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS notifications_user_idx
  ON public.notifications (user_id, created_at DESC);

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own notifications"
  ON public.notifications FOR SELECT
  USING (auth.uid() = user_id);

-- Marking read is the one direct mutation allowed from the client.
CREATE POLICY "Users can mark their own notifications read"
  ON public.notifications FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;

-- 2. Mention invitations ---------------------------------------------------
CREATE TABLE IF NOT EXISTS public.mention_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  inviter_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  other_participant_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  invited_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  message_content text NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined')),
  group_chat_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  responded_at timestamptz,
  CONSTRAINT mention_invitations_distinct_trio CHECK (
    inviter_id <> invited_id AND other_participant_id <> invited_id
  )
);

CREATE INDEX IF NOT EXISTS mention_invitations_invited_idx
  ON public.mention_invitations (invited_id, status);

ALTER TABLE public.mention_invitations ENABLE ROW LEVEL SECURITY;

-- Anyone in the trio can see the invite; only the invited person acts
-- on it, and only through respond_to_mention_invite() below.
CREATE POLICY "Trio can view a mention invitation"
  ON public.mention_invitations FOR SELECT
  USING (auth.uid() IN (inviter_id, other_participant_id, invited_id));

-- 3. Group chats -------------------------------------------------------------
-- Deliberately nameless — see get_group_participants() /
-- list_group_chats() below, which always derive the display name
-- from whoever's still actually in the chat.
CREATE TABLE IF NOT EXISTS public.group_chats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.group_chat_participants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id uuid NOT NULL REFERENCES public.group_chats(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  joined_at timestamptz NOT NULL DEFAULT now(),
  left_at timestamptz,
  UNIQUE (chat_id, user_id)
);

CREATE INDEX IF NOT EXISTS group_chat_participants_user_idx
  ON public.group_chat_participants (user_id);
CREATE INDEX IF NOT EXISTS group_chat_participants_chat_idx
  ON public.group_chat_participants (chat_id);

CREATE TABLE IF NOT EXISTS public.group_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id uuid NOT NULL REFERENCES public.group_chats(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  content text NOT NULL CHECK (char_length(content) <= 2000),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS group_messages_chat_idx
  ON public.group_messages (chat_id, created_at);

ALTER TABLE public.group_chats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_chat_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_messages ENABLE ROW LEVEL SECURITY;

-- Having ever been a participant is enough to see the chat shell and
-- its full participant list (including people who've since left) —
-- same reasoning WhatsApp-style apps use: leaving doesn't rewrite
-- history for anyone, including yourself, if you go looking for it.
CREATE POLICY "Participants can view their group chats"
  ON public.group_chats FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.group_chat_participants gcp
      WHERE gcp.chat_id = id AND gcp.user_id = auth.uid()
    )
  );

CREATE POLICY "Participants can view the participant list"
  ON public.group_chat_participants FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.group_chat_participants me
      WHERE me.chat_id = group_chat_participants.chat_id AND me.user_id = auth.uid()
    )
  );

CREATE POLICY "Participants can view group messages"
  ON public.group_messages FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.group_chat_participants gcp
      WHERE gcp.chat_id = group_messages.chat_id AND gcp.user_id = auth.uid()
    )
  );

-- Only a currently-active (not left) participant can post.
CREATE POLICY "Active participants can send group messages"
  ON public.group_messages FOR INSERT
  WITH CHECK (
    auth.uid() = sender_id
    AND EXISTS (
      SELECT 1 FROM public.group_chat_participants gcp
      WHERE gcp.chat_id = group_messages.chat_id
        AND gcp.user_id = auth.uid()
        AND gcp.left_at IS NULL
    )
  );

ALTER PUBLICATION supabase_realtime ADD TABLE public.group_messages;

-- 4. RPC: invite_mentioned_user ----------------------------------------------
-- Called right after a message is sent in a 1:1 chat if it @mentioned
-- someone who isn't already the other participant. Silently no-ops
-- (rather than erroring the whole send) if the mentioned username
-- doesn't exist or has tagging turned off — search_mentionable_users
-- should have already kept that from happening client-side, but this
-- is the actual enforcement point.
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
  SELECT id INTO v_invited_id
  FROM public.profiles
  WHERE lower(username) = lower(invited_username)
    AND allow_tagging = true
    AND allow_discovery = true;

  IF v_invited_id IS NULL OR v_invited_id = auth.uid() OR v_invited_id = other_participant_id THEN
    RETURN NULL;
  END IF;

  -- Idempotent: re-mentioning the same person while an invite is
  -- still pending just reuses it instead of spamming a new one.
  SELECT id INTO v_invite_id
  FROM public.mention_invitations
  WHERE inviter_id = auth.uid()
    AND other_participant_id = invite_mentioned_user.other_participant_id
    AND invited_id = v_invited_id
    AND status = 'pending';

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

-- 5. RPC: respond_to_mention_invite ------------------------------------------
-- Accepting creates the group chat (3 participants: inviter, the
-- original other participant, and the person accepting) and seeds it
-- with the original mention message as the first group message,
-- timestamped to when it was actually sent. Declining just closes out
-- the invite.
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
  SELECT * INTO v_invite
  FROM public.mention_invitations
  WHERE id = invite_id AND invited_id = auth.uid() AND status = 'pending'
  FOR UPDATE;

  IF v_invite.id IS NULL THEN
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

-- 6. RPC: leave_group_chat ----------------------------------------------------
CREATE OR REPLACE FUNCTION public.leave_group_chat(
  chat_id uuid,
  delete_messages boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.group_chat_participants
    WHERE group_chat_participants.chat_id = leave_group_chat.chat_id
      AND user_id = auth.uid()
      AND left_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Not an active participant of this chat.';
  END IF;

  IF delete_messages THEN
    DELETE FROM public.group_messages
    WHERE group_messages.chat_id = leave_group_chat.chat_id
      AND sender_id = auth.uid();
  END IF;

  UPDATE public.group_chat_participants
  SET left_at = now()
  WHERE group_chat_participants.chat_id = leave_group_chat.chat_id
    AND user_id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.leave_group_chat(uuid, boolean) TO authenticated;

-- 7. RPC: get_group_participants ---------------------------------------------
-- Every participant a chat has ever had, active or departed — the
-- app itself decides how to render that (e.g. strike through anyone
-- with left_at set).
CREATE OR REPLACE FUNCTION public.get_group_participants(chat_id uuid)
RETURNS TABLE (
  user_id uuid,
  username text,
  avatar_url text,
  joined_at timestamptz,
  left_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p.id, p.username, p.avatar_url, gcp.joined_at, gcp.left_at
  FROM public.group_chat_participants gcp
  JOIN public.profiles p ON p.id = gcp.user_id
  WHERE gcp.chat_id = get_group_participants.chat_id
    AND EXISTS (
      SELECT 1 FROM public.group_chat_participants me
      WHERE me.chat_id = get_group_participants.chat_id AND me.user_id = auth.uid()
    )
  ORDER BY gcp.joined_at ASC;
$$;

GRANT EXECUTE ON FUNCTION public.get_group_participants(uuid) TO authenticated;

-- 8. RPC: list_group_chats -----------------------------------------------------
-- One row per group chat the current user is (or was) in, newest
-- activity first. `participant_names` is the comma-separated display
-- name — every *currently active* participant except the caller,
-- which is exactly what makes the chat nameless-but-legible.
CREATE OR REPLACE FUNCTION public.list_group_chats()
RETURNS TABLE (
  chat_id uuid,
  participant_names text,
  last_message text,
  last_message_at timestamptz,
  last_sender_id uuid,
  i_have_left boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH mine AS (
    SELECT chat_id, left_at
    FROM public.group_chat_participants
    WHERE user_id = auth.uid()
  ),
  names AS (
    SELECT gcp.chat_id, string_agg(p.username, ', ' ORDER BY p.username) AS participant_names
    FROM public.group_chat_participants gcp
    JOIN public.profiles p ON p.id = gcp.user_id
    WHERE gcp.left_at IS NULL AND gcp.user_id <> auth.uid()
    GROUP BY gcp.chat_id
  ),
  last_msg AS (
    SELECT DISTINCT ON (chat_id) chat_id, content, created_at, sender_id
    FROM public.group_messages
    ORDER BY chat_id, created_at DESC
  )
  SELECT
    m.chat_id,
    coalesce(n.participant_names, '') AS participant_names,
    lm.content AS last_message,
    lm.created_at AS last_message_at,
    lm.sender_id AS last_sender_id,
    (m.left_at IS NOT NULL) AS i_have_left
  FROM mine m
  LEFT JOIN names n ON n.chat_id = m.chat_id
  LEFT JOIN last_msg lm ON lm.chat_id = m.chat_id
  WHERE m.left_at IS NULL
  ORDER BY lm.created_at DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION public.list_group_chats() TO authenticated;

-- 9. RPC: list_notifications ---------------------------------------------------
-- For 'mention_invite' rows this also resolves the *current* invite
-- status live (rather than baking it into the notification at insert
-- time), so a card whose invite was already answered elsewhere never
-- shows stale Accept/Decline buttons.
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
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

GRANT EXECUTE ON FUNCTION public.list_notifications() TO authenticated;

-- 10. RPC: unread_notification_count / mark_notification_read -----------------
CREATE OR REPLACE FUNCTION public.unread_notification_count()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*) FROM public.notifications
  WHERE user_id = auth.uid() AND read_at IS NULL;
$$;

GRANT EXECUTE ON FUNCTION public.unread_notification_count() TO authenticated;

CREATE OR REPLACE FUNCTION public.mark_notification_read(notification_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.notifications
  SET read_at = now()
  WHERE id = notification_id AND user_id = auth.uid() AND read_at IS NULL;
$$;

GRANT EXECUTE ON FUNCTION public.mark_notification_read(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.mark_all_notifications_read()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.notifications
  SET read_at = now()
  WHERE user_id = auth.uid() AND read_at IS NULL;
$$;

GRANT EXECUTE ON FUNCTION public.mark_all_notifications_read() TO authenticated;
