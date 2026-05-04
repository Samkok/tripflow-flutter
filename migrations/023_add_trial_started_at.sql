-- Migration 023: Add dedicated trial_started_at column to user_profiles.
--
-- Replaces the "free up to 5 locations" gate (migration 010 / locations_added_count)
-- with a "3-day free trial from this timestamp" gate. The dedicated column
-- (rather than reusing created_at) lets us grant extensions, reset trials
-- for support cases, or backfill imported users without touching account
-- metadata.
--
-- Backfill: existing users adopt their account creation time, so the
-- migration is a HARD CUTOVER — any account older than 3 days is paywalled
-- on their next create attempt after the app update ships.
--
-- The locations_added_count column from migration 010 is intentionally
-- left in place: the increment trigger keeps running for analytics, but
-- the client no longer reads it.

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS trial_started_at TIMESTAMPTZ DEFAULT now();

COMMENT ON COLUMN public.user_profiles.trial_started_at IS
'Timestamp the 3-day free trial started. Defaults to now() on insert; set explicitly during signup if the user already had an anonymous trial in progress.';

-- Backfill existing rows so they don''t silently get a fresh 3 days.
UPDATE public.user_profiles
SET trial_started_at = created_at
WHERE trial_started_at IS NULL;

-- Enforce NOT NULL once backfilled.
ALTER TABLE public.user_profiles
  ALTER COLUMN trial_started_at SET NOT NULL;

-- Optional helper to query "is this user still in trial" from SQL.
-- Mobile gate uses Dart-side computation, but this is handy for support.
CREATE OR REPLACE FUNCTION public.user_is_in_trial(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT trial_started_at + interval '3 days' > now()
  FROM public.user_profiles
  WHERE user_id = p_user_id;
$$;
