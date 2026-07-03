-- Referral system — "Give a month, get a month".
--
-- referral_codes: one stable share code per user, lazily created via RPC.
-- referrals:      one row per REFEREE (unique) tracking the state machine
--                 pending → qualified → rewarded. Written ONLY by edge
--                 functions (service role); clients read their own rows.
-- referral_redemption_attempts: rate-limit ledger for redeem-referral.
--
-- Rewards are RevenueCat promotional entitlements granted by the
-- redeem-referral edge function (referee) and the revenuecat-webhook
-- qualification hook (referrer, capped at 12 rewarded rows per trailing
-- 365 days).

-- ── referral_codes ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.referral_codes (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  code text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.referral_codes ENABLE ROW LEVEL SECURITY;

-- Owner may read their own code; all writes happen via the RPC below or
-- the service role.
CREATE POLICY referral_codes_owner_select ON public.referral_codes
  FOR SELECT USING (auth.uid() = user_id);

-- Lazy get-or-create. Charset omits 0/O/1/I/L to keep codes unambiguous
-- when read aloud or typed (31^6 ≈ 887M combinations).
CREATE OR REPLACE FUNCTION public.get_or_create_referral_code()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_code text;
  v_chars constant text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  v_try int := 0;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT code INTO v_code FROM public.referral_codes WHERE user_id = v_user;
  IF v_code IS NOT NULL THEN
    RETURN v_code;
  END IF;

  LOOP
    v_try := v_try + 1;
    v_code := 'VOYZA-' || (
      SELECT string_agg(substr(v_chars, 1 + floor(random() * 31)::int, 1), '')
      FROM generate_series(1, 6)
    );
    BEGIN
      INSERT INTO public.referral_codes (user_id, code)
      VALUES (v_user, v_code)
      ON CONFLICT (user_id) DO NOTHING;
      -- Either we inserted, or a concurrent call did — re-read either way.
      SELECT code INTO v_code FROM public.referral_codes WHERE user_id = v_user;
      RETURN v_code;
    EXCEPTION WHEN unique_violation THEN
      -- Code collision (not user collision) — retry with a fresh code.
      IF v_try >= 5 THEN
        RAISE EXCEPTION 'could not allocate referral code';
      END IF;
    END;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.get_or_create_referral_code() FROM public;
GRANT EXECUTE ON FUNCTION public.get_or_create_referral_code() TO authenticated;

-- ── referrals ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.referrals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  -- UNIQUE: one referral per referee lifetime; doubles as the concurrency
  -- lock for redeem-referral retries.
  referee_user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  code text NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'qualified', 'rewarded')),
  -- Set when the REFEREE's 30-day promotional grant succeeded (idempotency
  -- marker for redeem retries after a transient RevenueCat failure).
  referee_rewarded_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  qualified_at timestamptz,
  rewarded_at timestamptz,
  CHECK (referrer_user_id <> referee_user_id)
);

CREATE INDEX IF NOT EXISTS referrals_referrer_idx
  ON public.referrals(referrer_user_id);
-- Cap query: rewarded rows per referrer in the trailing 365 days.
CREATE INDEX IF NOT EXISTS referrals_referrer_rewarded_idx
  ON public.referrals(referrer_user_id, rewarded_at)
  WHERE status = 'rewarded';

ALTER TABLE public.referrals ENABLE ROW LEVEL SECURITY;

-- Both parties can see the row; neither can write it (service role only).
CREATE POLICY referrals_referrer_select ON public.referrals
  FOR SELECT USING (auth.uid() = referrer_user_id);
CREATE POLICY referrals_referee_select ON public.referrals
  FOR SELECT USING (auth.uid() = referee_user_id);

-- ── referral_redemption_attempts (rate limiting) ───────────────────────
CREATE TABLE IF NOT EXISTS public.referral_redemption_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  attempted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS referral_attempts_user_time_idx
  ON public.referral_redemption_attempts(user_id, attempted_at);

-- Service-role only: RLS on with no policies.
ALTER TABLE public.referral_redemption_attempts ENABLE ROW LEVEL SECURITY;
