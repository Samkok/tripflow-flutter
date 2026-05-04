-- Migration 025: Server-side device tracking for trial enforcement.
--
-- Closes the per-identity trial loopholes (sign up → trial → sign out → fresh
-- anon trial; create second account; clear app data on iOS) by recording
-- trial usage against a stable per-device UUID generated on the client and
-- stored in the iOS Keychain / Android KeyStore via flutter_secure_storage.
--
-- The (device_id, trial_started_at) pair is the system of record for whether
-- a device has ever started a trial. user_profiles.trial_started_at and the
-- anonymous SharedPrefs key remain as identity-level mirrors so the existing
-- read paths keep working when offline; the device row wins on conflict.

CREATE TABLE IF NOT EXISTS public.trial_devices (
  device_id text PRIMARY KEY,
  trial_started_at timestamptz NOT NULL DEFAULT now(),
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS trial_devices_user_id_idx
  ON public.trial_devices(user_id);

ALTER TABLE public.trial_devices ENABLE ROW LEVEL SECURITY;

-- The table is only ever written/read through the SECURITY DEFINER RPCs
-- below, so no RLS policies are needed for direct table access. Anon and
-- authenticated roles can call the functions but cannot SELECT/INSERT
-- against the table itself.

-- Atomic claim: returns the existing trial_started_at if the device already
-- has a row, otherwise inserts a new one and returns the fresh timestamp.
-- The ON CONFLICT DO UPDATE with self-reference is the canonical trick to
-- make RETURNING work uniformly on both insert and conflict paths.
CREATE OR REPLACE FUNCTION public.start_trial_for_device(
  p_device_id text,
  p_user_id uuid DEFAULT NULL
) RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_started_at timestamptz;
BEGIN
  IF p_device_id IS NULL OR length(p_device_id) = 0 THEN
    RAISE EXCEPTION 'device_id is required';
  END IF;

  INSERT INTO public.trial_devices (device_id, user_id, trial_started_at)
  VALUES (p_device_id, p_user_id, now())
  ON CONFLICT (device_id) DO UPDATE
    -- Self-assignment so RETURNING gets the existing row's timestamp.
    -- Optionally backfill user_id when the device was first claimed
    -- anonymously and the user has since signed up.
    SET user_id = COALESCE(public.trial_devices.user_id, EXCLUDED.user_id)
  RETURNING trial_started_at INTO v_started_at;

  RETURN v_started_at;
END;
$$;

REVOKE ALL ON FUNCTION public.start_trial_for_device(text, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.start_trial_for_device(text, uuid) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_trial_for_device(
  p_device_id text
) RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT trial_started_at FROM public.trial_devices WHERE device_id = p_device_id;
$$;

REVOKE ALL ON FUNCTION public.get_trial_for_device(text) FROM public;
GRANT EXECUTE ON FUNCTION public.get_trial_for_device(text) TO anon, authenticated;
