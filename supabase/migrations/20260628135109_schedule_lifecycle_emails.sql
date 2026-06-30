-- Daily cron that invokes the lifecycle-emails edge function.
-- Reuses the Vault service_role key + pg_net pattern from run_subscription_reconcile.
create or replace function public.run_lifecycle_emails()
returns void
language plpgsql
security definer
set search_path = public, extensions, net, vault
as $$
declare
  v_url text := 'https://dkbibfjszsohtixjxlle.supabase.co/functions/v1/lifecycle-emails';
  v_key text;
begin
  select decrypted_secret into v_key
  from vault.decrypted_secrets
  where name = 'service_role_key'
  limit 1;

  if v_key is null then
    raise warning 'run_lifecycle_emails: Vault secret "service_role_key" not set; skipping run';
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

-- Run daily at 09:00 UTC. Unschedule any prior copy first so re-running is safe.
do $$
begin
  perform cron.unschedule('lifecycle-emails-daily');
exception when others then
  null;
end;
$$;

select cron.schedule(
  'lifecycle-emails-daily',
  '0 9 * * *',
  $$ select public.run_lifecycle_emails(); $$
);
