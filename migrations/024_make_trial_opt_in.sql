-- Migration 024: Convert the free trial from auto-start to opt-in.
--
-- 023 introduced trial_started_at with DEFAULT now() and NOT NULL — the
-- trial began the moment the user signed up. The product flow is changing:
-- the trial only starts when the user explicitly taps "Start free trial"
-- on the paywall after hitting a gated action (create location/trip).
--
-- This migration:
--   1. Drops the DEFAULT and NOT NULL so new rows default to "trial unused".
--   2. Resets trial_started_at to NULL for everyone except active Pro users,
--      giving the existing user base a fresh chance to opt in under the new
--      flow. Pro users' values are irrelevant (gate short-circuits on isPro)
--      but we leave them alone to avoid touching paying customers' rows.

ALTER TABLE public.user_profiles
  ALTER COLUMN trial_started_at DROP DEFAULT;

ALTER TABLE public.user_profiles
  ALTER COLUMN trial_started_at DROP NOT NULL;

UPDATE public.user_profiles
SET trial_started_at = NULL
WHERE user_id NOT IN (
  SELECT user_id FROM public.user_subscriptions
  WHERE status IN ('active', 'grace_period', 'billing_retry')
);

COMMENT ON COLUMN public.user_profiles.trial_started_at IS
'Timestamp the 3-day free trial started. NULL means the user has not opted into the trial yet. Set when the user taps "Start free trial" on the paywall, or copied from the anonymous-trial SharedPreferences key at signup.';

-- Refresh the helper to handle NULL (treat unset trial as not-in-trial).
CREATE OR REPLACE FUNCTION public.user_is_in_trial(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT trial_started_at IS NOT NULL
     AND trial_started_at + interval '3 days' > now()
  FROM public.user_profiles
  WHERE user_id = p_user_id;
$$;
