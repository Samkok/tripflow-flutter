-- Instant referral reward: +2 permanent free place slots per successful code
-- redemption, capped at +10 (5 redemptions). Delivers value to the referrer
-- the moment their code is used, while the free month stays at the referee's
-- paid conversion (fraud-funded reward unchanged).

alter table public.user_profiles
  add column if not exists referral_bonus_places integer not null default 0
    check (referral_bonus_places >= 0 and referral_bonus_places <= 10);

-- Atomic, capped increment. Called ONLY by the redeem-referral edge function
-- (service role) inside its exactly-once guard — never by clients, hence the
-- revoke below.
create or replace function public.increment_referral_bonus_places(target_user uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.user_profiles
     set referral_bonus_places = least(referral_bonus_places + 2, 10)
   where user_id = target_user;
$$;

revoke execute on function public.increment_referral_bonus_places(uuid)
  from public, anon, authenticated;
