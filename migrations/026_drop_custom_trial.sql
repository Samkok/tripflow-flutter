-- Migration 026: Drop the custom server-side trial system.
--
-- The 3-day trial is now an App Store / Google Play introductory offer,
-- enforced by the platform stores and surfaced via RevenueCat's
-- `entitlement.periodType == TRIAL` signal. The custom tracking added in
-- migrations 023–025 is no longer read by the client and would only
-- accumulate stale rows on every signup.
--
-- This migration is destructive: it drops the trial_devices table and
-- the trial_started_at column. Run only after the client release that
-- removes TrialService, DeviceIdService, and the trial_provider.dart
-- imports has rolled out to all install bases — older clients querying
-- the dropped objects will silently fail (`getTrialStart` already
-- tolerates errors and falls through to fail-open).

-- 1. Drop the RPC helpers introduced in 025 and 023 ---------------------------
DROP FUNCTION IF EXISTS public.start_trial_for_device(text, uuid);
DROP FUNCTION IF EXISTS public.get_trial_for_device(text);
DROP FUNCTION IF EXISTS public.user_is_in_trial(uuid);

-- 2. Drop the per-device tracking table ---------------------------------------
DROP TABLE IF EXISTS public.trial_devices;

-- 3. Drop the per-user trial timestamp column ---------------------------------
ALTER TABLE public.user_profiles
  DROP COLUMN IF EXISTS trial_started_at;
