-- ================================================================
-- REALITY MERGE v5 — Profile picture upload
-- Run this in the Supabase SQL editor after v4-migration.sql
-- ================================================================

-- 1. Avatar column on profiles ---------------------------------------------
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS avatar_url text;

-- 2. Storage bucket for avatars ---------------------------------------------
-- Public bucket (avatars are meant to be visible to everyone, same as
-- drop-media). Each user uploads under a folder named after their own
-- uid, so policies can check the first path segment against auth.uid().
INSERT INTO storage.buckets (id, name, public)
VALUES ('avatars', 'avatars', true)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "Avatar images are publicly viewable"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'avatars');

CREATE POLICY "Users can upload their own avatar"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

CREATE POLICY "Users can update their own avatar"
  ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

CREATE POLICY "Users can delete their own avatar"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- 3. Update profile_stats view to carry avatar_url --------------------------
-- avatar_url is appended at the END of the column list (not inserted after
-- username) because CREATE OR REPLACE VIEW can only add trailing columns —
-- it errors if a replacement changes the position of an existing column,
-- since Postgres reads that as an implicit rename.
CREATE OR REPLACE VIEW public.profile_stats AS
SELECT
  p.id AS user_id,
  p.username,
  count(DISTINCT d.id) AS drops_created,
  count(DISTINCT du.drop_id) AS drops_unlocked,
  p.avatar_url
FROM public.profiles p
LEFT JOIN public.drops d ON d.creator_id = p.id
LEFT JOIN public.drop_unlocks du ON du.user_id = p.id
GROUP BY p.id, p.username, p.avatar_url;

-- 4. Update list_conversations RPC to carry the other user's avatar ---------
CREATE OR REPLACE FUNCTION public.list_conversations()
RETURNS TABLE (
  other_user_id uuid,
  other_username text,
  other_avatar_url text,
  last_message text,
  last_message_at timestamptz,
  last_sender_id uuid,
  unread_count bigint
)
LANGUAGE sql
STABLE
AS $$
  WITH mine AS (
    SELECT
      CASE WHEN sender_id = auth.uid() THEN recipient_id ELSE sender_id END AS other_user_id,
      sender_id,
      content,
      created_at,
      read_at
    FROM public.messages
    WHERE sender_id = auth.uid() OR recipient_id = auth.uid()
  ),
  ranked AS (
    SELECT
      other_user_id,
      sender_id,
      content,
      created_at,
      row_number() OVER (PARTITION BY other_user_id ORDER BY created_at DESC) AS rn
    FROM mine
  )
  SELECT
    r.other_user_id,
    p.username AS other_username,
    p.avatar_url AS other_avatar_url,
    r.content AS last_message,
    r.created_at AS last_message_at,
    r.sender_id AS last_sender_id,
    (
      SELECT count(*) FROM mine m
      WHERE m.other_user_id = r.other_user_id
        AND m.sender_id = r.other_user_id
        AND m.read_at IS NULL
    ) AS unread_count
  FROM ranked r
  JOIN public.profiles p ON p.id = r.other_user_id
  WHERE r.rn = 1
  ORDER BY r.created_at DESC;
$$;
