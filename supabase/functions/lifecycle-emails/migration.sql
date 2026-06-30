-- Lifecycle emails — supporting schema for the lifecycle-emails edge function.
-- Apply manually (Supabase SQL editor or apply_migration) BEFORE deploying +
-- scheduling the function. Safe/additive. Assumes public.locations has a
-- trip_id column and public.user_subscriptions has status + updated_at
-- (adjust the target query if your schema differs).

-- 1) De-dupe ledger: one email per (user, stage), ever.
create table if not exists public.lifecycle_emails_sent (
  user_id  uuid        not null,
  stage    text        not null,
  sent_at  timestamptz not null default now(),
  primary key (user_id, stage)
);
alter table public.lifecycle_emails_sent enable row level security;
-- No policies → only the service role (edge function) can read/write it.

-- 2) Single source of truth for "who is due, for which stage" (deduped).
create or replace function public.lifecycle_email_targets()
returns table(user_id uuid, email text, stage text)
language sql
security definer
set search_path = public, auth
as $$
  -- WELCOME: signed up 1–3 days ago, never created a trip.
  select u.id, u.email, 'welcome'::text
  from auth.users u
  where u.email is not null
    and u.created_at between now() - interval '3 days' and now() - interval '1 day'
    and not exists (select 1 from public.trips t where t.user_id = u.id)
    and not exists (select 1 from public.lifecycle_emails_sent s
                    where s.user_id = u.id and s.stage = 'welcome')

  union all
  -- ACTIVATE: has a trip but none reached the 3-place "aha", 2–5 days in.
  select u.id, u.email, 'activate'::text
  from auth.users u
  where u.email is not null
    and u.created_at between now() - interval '5 days' and now() - interval '2 days'
    and exists (select 1 from public.trips t where t.user_id = u.id)
    and not exists (
      select 1
      from public.trips t
      join public.locations l on l.trip_id = t.id
      where t.user_id = u.id
      group by t.id
      having count(l.id) >= 3
    )
    and not exists (select 1 from public.lifecycle_emails_sent s
                    where s.user_id = u.id and s.stage = 'activate')

  union all
  -- WINBACK: a subscription expired in the last 7 days, no active sub now.
  select u.id, u.email, 'winback'::text
  from auth.users u
  join public.user_subscriptions es
    on es.user_id = u.id
   and es.status = 'expired'
   and es.updated_at >= now() - interval '7 days'
  where u.email is not null
    and not exists (select 1 from public.user_subscriptions a
                    where a.user_id = u.id and a.status = 'active')
    and not exists (select 1 from public.lifecycle_emails_sent s
                    where s.user_id = u.id and s.stage = 'winback');
$$;

-- 3) Schedule (enable ONLY after the function is deployed + Resend secrets set).
-- Reuses the Vault service_role key + pg_net pattern from run_subscription_reconcile.
--
-- create or replace function public.run_lifecycle_emails()
-- returns void language plpgsql security definer
-- set search_path = public, extensions, net, vault as $$
-- declare v_key text;
-- begin
--   select decrypted_secret into v_key from vault.decrypted_secrets
--     where name = 'service_role_key' limit 1;
--   if v_key is null then return; end if;
--   perform net.http_post(
--     url     := 'https://dkbibfjszsohtixjxlle.supabase.co/functions/v1/lifecycle-emails',
--     headers := jsonb_build_object('Content-Type','application/json',
--                                   'Authorization','Bearer ' || v_key),
--     body    := '{}'::jsonb,
--     timeout_milliseconds := 60000
--   );
-- end; $$;
--
-- select cron.schedule('lifecycle-emails-daily', '0 9 * * *',
--   $$ select public.run_lifecycle_emails(); $$);
