-- Trip-date nudges: ledger + daily cron.
--
-- The trip-date-nudges edge function fires owned triggers off trips'
-- start/end dates (pre_trip / day_of:<date> / post_trip), delivering via an
-- INSERT into public.notifications (the existing DB webhook → FCM push path).
-- This migration adds its one-per-(trip,stage) dedupe ledger and schedules the
-- daily run, copying the run_lifecycle_emails vault + pg_net pattern.

create table if not exists public.trip_nudges_sent (
  trip_id uuid not null references public.trips(id) on delete cascade,
  stage text not null,
  sent_at timestamptz not null default now(),
  primary key (trip_id, stage)
);

-- Service-role only (the edge function). RLS on with no policies = clients
-- can't read or write the ledger; mirrors lifecycle_emails_sent.
alter table public.trip_nudges_sent enable row level security;

-- Invoker: mirrors public.run_lifecycle_emails.
create or replace function public.run_trip_date_nudges()
returns void
language plpgsql
security definer
set search_path = public, extensions, net, vault
as $$
declare
  v_url text := 'https://dkbibfjszsohtixjxlle.supabase.co/functions/v1/trip-date-nudges';
  v_key text;
begin
  select decrypted_secret into v_key
  from vault.decrypted_secrets
  where name = 'service_role_key'
  limit 1;

  if v_key is null then
    raise warning 'run_trip_date_nudges: Vault secret "service_role_key" not set; skipping run';
    return;
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
end;
$$;

-- Daily at 08:00 UTC (an hour before lifecycle emails, so a user with both
-- gets them spaced, not stacked). Unschedule any prior copy so re-running is
-- safe.
do $$
begin
  perform cron.unschedule('trip-date-nudges-daily');
exception when others then
  null;
end;
$$;

select cron.schedule(
  'trip-date-nudges-daily',
  '0 8 * * *',
  $$ select public.run_trip_date_nudges(); $$
);
