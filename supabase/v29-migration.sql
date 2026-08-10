-- ================================================================
-- REALM v29 — Email availability check for the sign-up flow
-- Run this in the Supabase SQL editor after v28-migration.sql
-- ================================================================
--
-- Username availability is already checkable straight from the
-- client (public.profiles is select-able by everyone — see
-- schema.sql), but auth.users (where email actually lives) isn't
-- exposed to anon/authenticated roles at all, and for good reason —
-- so this is the one narrow, purpose-built way to ask "is this email
-- already registered" without opening up auth.users generally.
--
-- Deliberately checked at the account level (auth.users), not the
-- profiles level: a person could in principle have an auth.users row
-- with no profiles row yet (mid-signup drop-off, or a first-time
-- Google sign-in that hasn't finished CompleteProfileScreen) — email
-- uniqueness has to reflect Supabase Auth's own rule, which is what
-- actually decides whether a later signUp call will succeed.
CREATE OR REPLACE FUNCTION public.email_is_registered(check_email text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM auth.users WHERE lower(email) = lower(check_email)
  );
$$;

-- Grants to anon too, not just authenticated — this has to be
-- callable from SignUpScreen before anyone's signed in.
GRANT EXECUTE ON FUNCTION public.email_is_registered(text) TO anon, authenticated;
