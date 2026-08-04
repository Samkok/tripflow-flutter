-- Referral banking + scheduled reconciler.
--
-- 1. New 'banked' status: a referrer on ACTIVE PAID coverage earns a month
--    that would otherwise burn underneath their subscription — the webhook
--    now parks it as 'banked' (banked_at) and pays it out when their plan
--    lapses (EXPIRATION/REFUND hook + the daily reconciler below).
-- 2. Backlog index: the reconciler sweeps qualified/banked rows daily.
-- 3. Cron: mirrors run_subscription_reconcile (Vault service_role key +
--    pg_net → edge function), daily at 03:17 UTC.

-- ── 1. Status + banked_at ─────────────────────────────────────────────────
ALTER TABLE public.referrals
  DROP CONSTRAINT IF EXISTS referrals_status_check;
ALTER TABLE public.referrals
  ADD CONSTRAINT referrals_status_check
  CHECK (status IN ('pending', 'qualified', 'banked', 'rewarded'));

ALTER TABLE public.referrals
  ADD COLUMN IF NOT EXISTS banked_at timestamptz;

COMMENT ON COLUMN public.referrals.banked_at IS
  'Set when the referrer''s reward was earned while they were on active paid '
  'coverage; the month pays out when that coverage lapses.';

-- ── 2. Backlog index for the daily sweep ──────────────────────────────────
CREATE INDEX IF NOT EXISTS referrals_payout_backlog_idx
  ON public.referrals (created_at)
  WHERE status IN ('qualified', 'banked') AND rewarded_at IS NULL;

-- ── 3. Daily reconciler cron ──────────────────────────────────────────────
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

create or replace function public.run_referral_reconcile()
returns void
language plpgsql
security definer
set search_path = public, extensions, net, vault
as $$
declare
  v_url text := 'https://dkbibfjszsohtixjxlle.supabase.co/functions/v1/referral-reconciler';
  v_key text;
begin
  select decrypted_secret into v_key
  from vault.decrypted_secrets
  where name = 'service_role_key'
  limit 1;

  if v_key is null then
    raise warning 'run_referral_reconcile: Vault secret "service_role_key" not set; skipping run';
    return;
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body    := '{}'::jsonb
  );
end;
$$;

do $$
begin
  perform cron.unschedule('referral-reconciler-daily');
exception when others then
  null;
end;
$$;

select cron.schedule(
  'referral-reconciler-daily',
  '17 3 * * *',
  $$ select public.run_referral_reconcile(); $$
);
