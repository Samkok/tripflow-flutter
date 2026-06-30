-- The reconcile function makes one sequential RC API call per active row, so it
-- routinely runs longer than pg_net's 5s default. Raise the read timeout so the
-- cron records a clean 200 instead of a (harmless) client-side timeout.
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
    url                  := v_url,
    headers              := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body                 := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
end;
$$;
