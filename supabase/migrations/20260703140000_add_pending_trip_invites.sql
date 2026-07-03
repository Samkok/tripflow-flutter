-- Collaboration = referral engine.
--
-- When a user invites a collaborator whose email has no VoyZa account yet,
-- we store the invite here (keyed by email) instead of dead-ending. On the
-- invitee's first sign-in, the `claim-invites` edge function auto-joins them
-- to the trip AND runs the referral reward for both sides.
--
-- trip_collaborators.user_id is NOT NULL, so it can't hold a pre-signup
-- invite — hence this separate pending table.

CREATE TABLE IF NOT EXISTS public.pending_trip_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id uuid NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE,
  email text NOT NULL,                 -- stored lowercased
  permission text NOT NULL DEFAULT 'read' CHECK (permission IN ('read', 'write')),
  invited_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  referral_code text NOT NULL,         -- the inviter's code, for attribution
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '30 days'),
  UNIQUE(trip_id, email)
);

CREATE INDEX IF NOT EXISTS pending_trip_invites_email_idx
  ON public.pending_trip_invites (lower(email));

ALTER TABLE public.pending_trip_invites ENABLE ROW LEVEL SECURITY;

-- The inviter may see/cancel their own pending invites; everything else is
-- service-role only (the claim edge function reads by email).
CREATE POLICY pending_invites_inviter_select ON public.pending_trip_invites
  FOR SELECT USING (auth.uid() = invited_by);
CREATE POLICY pending_invites_inviter_delete ON public.pending_trip_invites
  FOR DELETE USING (auth.uid() = invited_by);

-- Create (or refresh) a pending invite. SECURITY DEFINER so it can stamp the
-- caller's referral code and write despite RLS; it verifies the caller may
-- write the trip (owner or write-collaborator) before doing anything.
CREATE OR REPLACE FUNCTION public.create_pending_trip_invite(
  p_trip_id uuid,
  p_email text,
  p_permission text DEFAULT 'read'
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_email text := lower(trim(p_email));
  v_code text;
  v_can_write boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'email is required';
  END IF;
  IF p_permission NOT IN ('read', 'write') THEN
    RAISE EXCEPTION 'invalid permission';
  END IF;

  -- Caller must own the trip or be a write-collaborator on it.
  SELECT EXISTS (
    SELECT 1 FROM public.trips t
    WHERE t.id = p_trip_id AND t.user_id = v_caller
    UNION
    SELECT 1 FROM public.trip_collaborators c
    WHERE c.trip_id = p_trip_id AND c.user_id = v_caller AND c.permission = 'write'
  ) INTO v_can_write;
  IF NOT v_can_write THEN
    RAISE EXCEPTION 'no write access to this trip';
  END IF;

  -- The caller's stable referral code, created lazily if needed.
  v_code := public.get_or_create_referral_code();

  INSERT INTO public.pending_trip_invites
    (trip_id, email, permission, invited_by, referral_code)
  VALUES (p_trip_id, v_email, p_permission, v_caller, v_code)
  ON CONFLICT (trip_id, email) DO UPDATE
    SET permission = EXCLUDED.permission,
        invited_by = EXCLUDED.invited_by,
        referral_code = EXCLUDED.referral_code,
        expires_at = now() + interval '30 days';

  RETURN v_code;
END;
$$;

REVOKE ALL ON FUNCTION public.create_pending_trip_invite(uuid, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.create_pending_trip_invite(uuid, text, text) TO authenticated;

-- Daily purge of expired pending invites (reuses the pg_cron used by the
-- reconcile/lifecycle jobs).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule(
      'purge-expired-pending-invites',
      '17 3 * * *',
      $cron$ DELETE FROM public.pending_trip_invites WHERE expires_at < now(); $cron$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  -- Non-fatal: the claim function already ignores expired rows.
  NULL;
END $$;
