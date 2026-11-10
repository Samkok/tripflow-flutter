-- OPTIONAL. NOT APPLIED. Not a migration: it lives outside supabase/migrations
-- on purpose. Read "Old builds" in docs/pro-to-add-places-2026-11-10.md first.
--
-- What it does: refuses a NEW place written by a signed-in user who is not
-- Pro, when the request comes from a build older than the Pro-to-add build.
-- Builds from that one on send the header x-voyza-pro-gate and are never
-- touched: they ask for Pro in the app.
--
-- What an old build does when refused (SQLSTATE 42501): builds 1.9.0 to
-- 1.11.53 delete the place from the device, with no message. Older builds
-- keep it on the device and never sync it.
--
-- What it cannot do: a guest's places never reach the server, so guests on
-- old builds keep their 10 free places whatever runs here.
--
-- The risk: an old build cannot say whether a row is a new place or a place
-- saved earlier that is only now reaching the server (a guest who signs up).
-- The rule lets the second kind through when the user signed in within the
-- last 30 minutes, or when the row is clearly old. The app stamps created_at
-- in LOCAL time without an offset, so "clearly old" has to be 15 hours. A
-- guest whose places are younger than that, and whose first sync finishes
-- more than 30 minutes after sign-in, loses those places from the device.
--
-- Run only once the Pro-to-add build is live in both stores.
-- To remove: the three statements at the bottom.

create or replace function public.voyza_old_build_add_allowed()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select
    -- Pro right now: the same test the trip-copy limit uses.
    exists (
      select 1 from public.user_subscriptions s
       where s.user_id = auth.uid()
         and s.status = 'active'
         and (s.expires_at is null or s.expires_at > now())
    )
    -- Just signed in: the app is pushing places saved before the account
    -- existed. A token refresh does not move last_sign_in_at.
    or exists (
      select 1 from auth.users u
       where u.id = auth.uid()
         and u.last_sign_in_at > now() - interval '30 minutes'
    );
$$;

revoke all on function public.voyza_old_build_add_allowed() from public, anon;
grant execute on function public.voyza_old_build_add_allowed() to authenticated;

create or replace function public.locations_pro_gate_old_builds()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_headers json;
begin
  -- Only a direct write by a signed-in app user is judged. Server functions
  -- (trip copy, rollover, hand-over), the service role and the SQL editor
  -- run as another role.
  if current_user <> 'authenticated' or auth.uid() is null then
    return new;
  end if;

  -- Builds that ask for Pro in the app say so.
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    v_headers := null;
  end;
  if coalesce(v_headers ->> 'x-voyza-pro-gate', '') <> '' then
    return new;
  end if;

  -- The app upserts: a row that already exists is an edit, not an add.
  if exists (select 1 from public.locations l where l.id = new.id) then
    return new;
  end if;

  -- Clearly saved earlier (see the note on local time above).
  if coalesce(new.created_at, now()) < now() - interval '15 hours' then
    return new;
  end if;

  -- The sample trip stays free.
  if new.trip_id is not null and exists (
       select 1 from public.trips t
        where t.id = new.trip_id and t.name ilike '%sample trip%') then
    return new;
  end if;

  if public.voyza_old_build_add_allowed() then
    return new;
  end if;

  raise exception using
    errcode = '42501',
    message = 'pro_required_to_add_places',
    hint = 'Adding places is part of VoyZa Pro. Update VoyZa to continue.';
end;
$$;

drop trigger if exists locations_pro_gate_old_builds on public.locations;
create trigger locations_pro_gate_old_builds
  before insert on public.locations
  for each row execute function public.locations_pro_gate_old_builds();

-- To remove:
--   drop trigger if exists locations_pro_gate_old_builds on public.locations;
--   drop function if exists public.locations_pro_gate_old_builds();
--   drop function if exists public.voyza_old_build_add_allowed();
