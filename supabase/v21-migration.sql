-- ================================================================
-- REALITY MERGE v21 — Profile rank (followers + engagement), for
-- the local "/my-rank" Dev Hub cheat code
-- Run this in the Supabase SQL editor after v20-migration.sql
-- ================================================================

-- Unlike the other cheat codes (which are purely local device state),
-- ranking the caller against everyone else genuinely needs a
-- server-side comparison — there's no way to know where you stand
-- among every other profile's follower/engagement counts without
-- querying them. This function only ever returns the caller's own
-- rank/percentile numbers, never anyone else's identity or counts,
-- so it doesn't leak anything beyond what "Followers are viewable by
-- everyone" (v8) already exposes in aggregate.
--
-- "Engagement" here is every like + comment received across all of
-- the caller's drops (public.drop_interactions, already
-- everyone-readable per its own RLS policy from the interactions
-- migration).
CREATE OR REPLACE FUNCTION public.get_profile_rank()
RETURNS TABLE (
  follower_count bigint,
  follower_rank bigint,
  engagement_count bigint,
  engagement_rank bigint,
  total_profiles bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH follower_counts AS (
    SELECT
      p.id AS user_id,
      count(f.id) AS follower_count
    FROM public.profiles p
    LEFT JOIN public.follows f ON f.following_id = p.id
    GROUP BY p.id
  ),
  engagement_counts AS (
    SELECT
      p.id AS user_id,
      count(i.id) AS engagement_count
    FROM public.profiles p
    LEFT JOIN public.drops d ON d.creator_id = p.id
    LEFT JOIN public.drop_interactions i ON i.drop_id = d.id
    GROUP BY p.id
  ),
  ranked AS (
    SELECT
      fc.user_id,
      fc.follower_count,
      rank() OVER (ORDER BY fc.follower_count DESC) AS follower_rank,
      ec.engagement_count,
      rank() OVER (ORDER BY ec.engagement_count DESC) AS engagement_rank
    FROM follower_counts fc
    JOIN engagement_counts ec ON ec.user_id = fc.user_id
  )
  SELECT
    r.follower_count,
    r.follower_rank,
    r.engagement_count,
    r.engagement_rank,
    (SELECT count(*) FROM public.profiles) AS total_profiles
  FROM ranked r
  WHERE r.user_id = auth.uid();
$$;

GRANT EXECUTE ON FUNCTION public.get_profile_rank() TO authenticated;
