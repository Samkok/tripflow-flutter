-- email_exists(text): does ANY live auth user hold this address?
--
-- Two consumers:
--   • forgot-password (anon): the app shows an honest "no VoyZa account
--     uses this email" with a sign-up path instead of a silent
--     send-to-nowhere. Deliberate product call (owner, 2026-08-15):
--     recovery clarity beats anti-enumeration for this product — the
--     function exposes a boolean only, never ids or profile data.
--   • send-email-otp / verify-email-otp (service role): the change-email
--     taken-check at the AUTH level. get_user_id_by_email is
--     verified-users-only BY DESIGN (squatter defense) and the
--     user_profiles scan misses profile-less accounts, so neither is a
--     complete uniqueness oracle on its own. gotrue's unique email
--     constraint remains the final backstop at swap time.
create or replace function public.email_exists(user_email text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from auth.users u
    where lower(u.email) = lower(trim(user_email))
      and u.deleted_at is null
  );
$$;

revoke all on function public.email_exists(text) from public;
grant execute on function public.email_exists(text)
  to anon, authenticated, service_role;
