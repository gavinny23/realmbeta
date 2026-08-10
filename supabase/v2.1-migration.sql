-- ================================================================
-- REALITY MERGE v2.1 — Private drops + video/document support
-- Run this in Supabase SQL editor after v2-migration.sql
-- ================================================================

-- 1. Add visibility and media_type to drops
ALTER TABLE public.drops
  ADD COLUMN IF NOT EXISTS visibility text NOT NULL DEFAULT 'public'
    CHECK (visibility IN ('public', 'private')),
  ADD COLUMN IF NOT EXISTS media_type text
    CHECK (media_type IN ('photo', 'video', 'document') OR media_type IS NULL);

-- 2. Drop access allowlist
-- Each row = one user allowed to unlock a specific private drop.
CREATE TABLE IF NOT EXISTS public.drop_access (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  drop_id uuid NOT NULL REFERENCES public.drops(id) ON DELETE CASCADE,
  granted_to uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  granted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (drop_id, granted_to)
);

CREATE INDEX IF NOT EXISTS drop_access_drop_idx ON public.drop_access (drop_id);
CREATE INDEX IF NOT EXISTS drop_access_user_idx ON public.drop_access (granted_to);

ALTER TABLE public.drop_access ENABLE ROW LEVEL SECURITY;

-- Drop creator can manage access
CREATE POLICY "Creator can manage drop access"
  ON public.drop_access
  USING (
    EXISTS (
      SELECT 1 FROM public.drops d
      WHERE d.id = drop_id AND d.creator_id = auth.uid()
    )
  );

-- Granted user can see their own access rows
CREATE POLICY "Granted user can see their access"
  ON public.drop_access FOR SELECT
  USING (granted_to = auth.uid());

-- 3. Update nearby_drops RPC to filter private drops
-- Returns public drops + private drops where user is on the allowlist
-- + drops the user created themselves
CREATE OR REPLACE FUNCTION public.nearby_drops(
  user_lat double precision,
  user_lng double precision,
  radius_m integer DEFAULT 2000
)
RETURNS TABLE (
  id uuid,
  creator_id uuid,
  creator_username text,
  caption text,
  media_url text,
  media_type text,
  visibility text,
  unlock_radius_m integer,
  distance_m double precision,
  drop_lat double precision,
  drop_lng double precision,
  is_unlocked boolean,
  created_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    d.id,
    d.creator_id,
    p.username AS creator_username,
    CASE WHEN du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.caption ELSE NULL END AS caption,
    CASE WHEN du.id IS NOT NULL OR d.creator_id = auth.uid()
      THEN d.media_url ELSE NULL END AS media_url,
    d.media_type,
    d.visibility,
    d.unlock_radius_m,
    ST_Distance(d.location, ST_SetSRID(ST_MakePoint(user_lng, user_lat), 4326)::geography) AS distance_m,
    ST_Y(d.location::geometry) AS drop_lat,
    ST_X(d.location::geometry) AS drop_lng,
    (du.id IS NOT NULL) AS is_unlocked,
    d.created_at
  FROM public.drops d
  LEFT JOIN public.profiles p ON p.id = d.creator_id
  LEFT JOIN public.drop_unlocks du
    ON du.drop_id = d.id AND du.user_id = auth.uid()
  WHERE
    -- Must be within radius
    ST_DWithin(
      d.location,
      ST_SetSRID(ST_MakePoint(user_lng, user_lat), 4326)::geography,
      radius_m
    )
    AND (
      -- Public drops visible to everyone
      d.visibility = 'public'
      -- Creator always sees their own drops
      OR d.creator_id = auth.uid()
      -- Private drops only visible if on the allowlist
      OR EXISTS (
        SELECT 1 FROM public.drop_access da
        WHERE da.drop_id = d.id AND da.granted_to = auth.uid()
      )
    )
  ORDER BY distance_m ASC;
$$;

-- 4. Update attempt_unlock to also check allowlist for private drops
CREATE OR REPLACE FUNCTION public.attempt_unlock(
  target_drop_id uuid,
  user_lat double precision,
  user_lng double precision
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  drop_record public.drops;
  distance_m double precision;
BEGIN
  SELECT * INTO drop_record FROM public.drops WHERE id = target_drop_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Drop not found';
  END IF;

  -- Check private drop access
  IF drop_record.visibility = 'private' AND drop_record.creator_id != auth.uid() THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.drop_access
      WHERE drop_id = target_drop_id AND granted_to = auth.uid()
    ) THEN
      RETURN false; -- not on allowlist
    END IF;
  END IF;

  -- Check proximity
  distance_m := ST_Distance(
    drop_record.location,
    ST_SetSRID(ST_MakePoint(user_lng, user_lat), 4326)::geography
  );

  IF distance_m > drop_record.unlock_radius_m THEN
    RETURN false; -- too far
  END IF;

  INSERT INTO public.drop_unlocks (user_id, drop_id)
  VALUES (auth.uid(), target_drop_id)
  ON CONFLICT (user_id, drop_id) DO NOTHING;

  RETURN true;
END;
$$;

-- 5. RPC to grant access to a user by username
CREATE OR REPLACE FUNCTION public.grant_drop_access(
  target_drop_id uuid,
  target_username text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  target_user_id uuid;
  drop_creator uuid;
BEGIN
  -- Only the drop creator can grant access
  SELECT creator_id INTO drop_creator
  FROM public.drops WHERE id = target_drop_id;

  IF drop_creator != auth.uid() THEN
    RAISE EXCEPTION 'Only the drop creator can grant access';
  END IF;

  -- Resolve username to user id
  SELECT id INTO target_user_id
  FROM public.profiles WHERE username = target_username;

  IF NOT FOUND THEN
    RETURN false; -- username doesn't exist
  END IF;

  INSERT INTO public.drop_access (drop_id, granted_to)
  VALUES (target_drop_id, target_user_id)
  ON CONFLICT (drop_id, granted_to) DO NOTHING;

  RETURN true;
END;
$$;
