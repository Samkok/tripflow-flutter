-- Tighten what the public API keys can do. Found in the 2026-10-06 truth
-- audit of the privacy policy against the LIVE database (grants read with
-- has_function_privilege, policies from pg_policies). Nothing here changes
-- what the app does: every call it makes runs as a signed-in user.
--
-- 1. SECURITY DEFINER functions that anyone holding the anon key could call:
--      lifecycle_email_targets()        -> email of every user in a lifecycle window
--      get_public_user_profile(uuid)    -> any user's name and email
--      upsert_subscription_status(...)  -> write subscription rows for any user (Pro for free)
--      create_user_profile(...)         -> create a profile for any user id
--      get_user_id_by_email(text)       -> map an email to a user id
--      run_*()                          -> fire the cron jobs (emails, pushes) at will
-- 2. The trips INSERT policy had WITH CHECK (true): any key could create a
--    trip owned by any user (and the date nudges would push its name to them).
-- 3. user_profiles UPDATE had no column limits: a user could set their own
--    email_verified_at, referral_bonus_places or trip_copies_used.
--
-- Apply in the SQL editor. After applying, re-run the checks at the bottom.

begin;

-- 1. Function grants -------------------------------------------------------
-- Service role and the owner keep EXECUTE (Supabase grants them separately);
-- cron jobs run as their owner, so revoking from authenticated is safe.
revoke execute on function public.lifecycle_email_targets() from public, anon, authenticated;
revoke execute on function public.upsert_subscription_status(
  uuid, text, text, text, text, text, timestamptz, text, timestamptz, boolean, timestamptz, timestamptz, text
) from public, anon, authenticated;
revoke execute on function public.run_lifecycle_emails() from public, anon, authenticated;
revoke execute on function public.run_subscription_reconcile() from public, anon, authenticated;
revoke execute on function public.run_referral_reconcile() from public, anon, authenticated;
revoke execute on function public.run_trip_date_nudges() from public, anon, authenticated;

-- Called by the app as a signed-in user only.
revoke execute on function public.create_user_profile(
  uuid, text, text, text, text, text, text, date, text, text, text, text, jsonb
) from public, anon;
revoke execute on function public.get_user_id_by_email(text) from public, anon;
revoke execute on function public.create_pending_trip_invite(uuid, text, text) from public, anon;
revoke execute on function public.get_public_user_profile(uuid) from public, anon;

-- get_public_user_profile: only someone who shares a trip with the person
-- (owner or member on either side) may read their name and email. The app
-- uses it for the trip-owner pill on shared trips, which this still allows.
create or replace function public.get_public_user_profile(p_user_id uuid)
returns table (
  id uuid, user_id uuid, first_name text, last_name text, email text,
  created_at timestamptz, updated_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select up.id, up.user_id, up.first_name, up.last_name, up.email,
         up.created_at, up.updated_at
  from public.user_profiles up
  where up.user_id = p_user_id
    and auth.uid() is not null
    and (
      p_user_id = auth.uid()
      or exists (
        select 1
        from public.trips t
        where (t.user_id = auth.uid()
               or exists (select 1 from public.trip_collaborators c
                          where c.trip_id = t.id and c.user_id = auth.uid()))
          and (t.user_id = p_user_id
               or exists (select 1 from public.trip_collaborators c
                          where c.trip_id = t.id and c.user_id = p_user_id))
      )
    )
  limit 1;
$$;
revoke execute on function public.get_public_user_profile(uuid) from public, anon;
grant execute on function public.get_public_user_profile(uuid) to authenticated;

-- 2. trips: only your own ---------------------------------------------------
drop policy if exists "Users can insert their own trips" on public.trips;
create policy "Users can insert their own trips"
  on public.trips
  for insert
  to authenticated
  with check (auth.uid() = user_id);

-- 3. user_profiles: the columns a person may edit themselves ----------------
-- Server-owned columns (email, email_verified_at, referral_bonus_places,
-- trip_copies_used, locations_added_count, ids, created_at) stay with the
-- service role and the triggers. The Profile screen writes first_name and
-- last_name; the paywall writes trial_started_at.
revoke update on public.user_profiles from anon, authenticated;
grant update (
  first_name, last_name, phone_number, profile_picture_url, bio,
  date_of_birth, gender, address, city, country, preferences,
  trial_started_at, updated_at
) on public.user_profiles to authenticated;

commit;

-- Checks (all should come back false / the restricted policy):
--   select has_function_privilege('anon', 'public.lifecycle_email_targets()', 'EXECUTE');
--   select has_function_privilege('anon', 'public.get_public_user_profile(uuid)', 'EXECUTE');
--   select has_function_privilege('authenticated', 'public.upsert_subscription_status(uuid,text,text,text,text,text,timestamptz,text,timestamptz,boolean,timestamptz,timestamptz,text)', 'EXECUTE');
--   select policyname, roles, with_check from pg_policies where tablename = 'trips' and cmd = 'INSERT';
--   select column_name from information_schema.column_privileges
--     where table_name = 'user_profiles' and grantee = 'authenticated' and privilege_type = 'UPDATE' order by 1;
