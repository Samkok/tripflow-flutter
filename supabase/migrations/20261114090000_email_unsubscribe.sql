-- Email unsubscribe: every commercial email (lifecycle emails, trip
-- invitations) carries an unsubscribe link, and an address that used it is
-- never emailed again. Additive; safe to run more than once.
--
-- Apply this BEFORE deploying the new lifecycle-emails, send-invite-email
-- and email-unsubscribe functions: they write to these tables, and an email
-- whose token cannot be stored is not sent.

-- 1) Addresses that asked not to be emailed. Keyed by address, not account,
--    so it also covers invited people who have no account, and it outlives
--    account deletion (the opt-out must keep being honoured).
create table if not exists public.email_suppressions (
  email      text        primary key check (email = lower(btrim(email))),
  source     text        not null default 'page',  -- page | one_click | manual
  created_at timestamptz not null default now()
);
alter table public.email_suppressions enable row level security;
revoke all on public.email_suppressions from anon, authenticated;
comment on table public.email_suppressions is
  'Addresses that unsubscribed from VoyZa marketing email (lifecycle, invitations). Service role only.';

-- 2) One random token per email sent. The link carries only the token.
--    Kept 13 months: links must keep working well past CAN-SPAM's 30 days.
create table if not exists public.email_unsubscribe_tokens (
  token      text        primary key,
  email      text        not null check (email = lower(btrim(email))),
  kind       text        not null check (kind in ('lifecycle', 'invite')),
  created_at timestamptz not null default now()
);
create index if not exists email_unsubscribe_tokens_created_at_idx
  on public.email_unsubscribe_tokens (created_at);
alter table public.email_unsubscribe_tokens enable row level security;
revoke all on public.email_unsubscribe_tokens from anon, authenticated;
comment on table public.email_unsubscribe_tokens is
  'Per-email unsubscribe tokens (token -> address). Purged after 13 months. Service role only.';

-- 3) Lifecycle targets, now skipping unsubscribed addresses in every stage.
--    Otherwise identical to the live definition of 2026-11-14.
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
    and not exists (select 1 from public.email_suppressions x
                    where x.email = lower(btrim(u.email)))

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
    and not exists (select 1 from public.email_suppressions x
                    where x.email = lower(btrim(u.email)))

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
                    where s.user_id = u.id and s.stage = 'winback')
    and not exists (select 1 from public.email_suppressions x
                    where x.email = lower(btrim(u.email)));
$$;

-- 4) Purge tokens older than 13 months, daily.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'purge-email-unsubscribe-tokens') then
    perform cron.unschedule('purge-email-unsubscribe-tokens');
  end if;
end $$;
select cron.schedule(
  'purge-email-unsubscribe-tokens',
  '41 3 * * *',
  $$ delete from public.email_unsubscribe_tokens where created_at < now() - interval '13 months' $$
);
