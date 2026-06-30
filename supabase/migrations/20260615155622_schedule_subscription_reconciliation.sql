-- Safety-net cron that invokes the reconcile-subscriptions edge function.
-- Reuses a Vault service_role key + pg_net to call the function every 30 min,
-- expiring any 'active' row RevenueCat no longer entitles.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

create or replace function public.run_subscription_reconcile()
returns void
language plpgsql
security definer
set search_path = public, extensions, net, vault
as $$
declare
  v_url text := 'https://dkbibfjszsohtixjxlle.supabase.co/functions/v1/reconcile-subscriptions';
  v_key text;
begin
  select decrypted_secret into v_key
  from vault.decrypted_secrets
  where name = 'service_role_key'
  limit 1;

  if v_key is null then
    raise warning 'run_subscription_reconcile: Vault secret "service_role_key" not set; skipping run';
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
  perform cron.unschedule('reconcile-subscriptions-30m');
exception when others then
  null;
end;
$$;

select cron.schedule(
  'reconcile-subscriptions-30m',
  '*/30 * * * *',
  $$ select public.run_subscription_reconcile(); $$
);
