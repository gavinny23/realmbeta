-- ================================================================
-- REALM v30 — fix ambiguous column reference in invite_mentioned_user
-- Run this in the Supabase SQL editor after v29-migration.sql
-- ================================================================
--
-- Bug: the function parameter `other_participant_id` shares its name
-- with the `mention_invitations.other_participant_id` column. The
-- lookup query qualified the right-hand side of the comparison
-- (`invite_mentioned_user.other_participant_id`) but left the
-- left-hand side bare, so PL/pgSQL's default
-- `variable_conflict = error` refuses to guess whether it means the
-- column or the parameter — raised as Postgres error 42702 every
-- time a mention invite is sent (e.g. inviting "gav24"). Fixed by
-- aliasing the table and qualifying both sides explicitly.

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
  SELECT mi.id INTO v_invite_id
  FROM public.mention_invitations mi
  WHERE mi.inviter_id = auth.uid()
    AND mi.other_participant_id = invite_mentioned_user.other_participant_id
    AND mi.invited_id = v_invited_id
    AND mi.status = 'pending'
    AND mi.expires_at > now();

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
